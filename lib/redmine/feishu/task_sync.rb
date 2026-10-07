# frozen_string_literal: true

# Redmine - project management software
# Copyright (C) 2006-  Jean-Philippe Lang

module Redmine
  module Feishu
    # Shared Feishu tasklist "Redmine": each Redmine project is a custom section;
    # issues are tasks in that section; child issues are Feishu subtasks.
    # Sections cannot nest, so subprojects are sibling sections.
    class TaskSync
      MAX_TEXT = 3000

      def self.project_enabled?(project)
        Setting.feishu_task_sync_enabled? && project.present? &&
          project.module_enabled?(:feishu_task_sync)
      end

      def self.enabled_for?(issue)
        return false if issue.nil? || issue.is_private?

        project_enabled?(issue.project)
      end

      def self.should_enqueue?(issue)
        return false unless project_enabled?(issue.project)
        return true unless issue.is_private?

        FeishuTaskMapping.exists?(:issue_id => issue.id)
      end

      def initialize(client: Client.new)
        @client = client
      end

      def sync(issue_id)
        issue = Issue.find_by_id(issue_id)
        unless issue
          Rails.logger.info {"Feishu sync skipped issue=#{issue_id} reason=not_found"}
          return
        end

        mapping = FeishuTaskMapping.find_by(:issue_id => issue.id)
        unless self.class.enabled_for?(issue)
          Rails.logger.info {"Feishu sync skipped issue=#{issue_id} reason=not_enabled"}
          delete_mapping(mapping) if issue.is_private? && mapping
          return
        end

        Rails.logger.info {"Feishu sync running issue=#{issue_id} mapped=#{mapping.present?}"}
        parent_guid = parent_task_guid_for(issue)
        if mapping.nil?
          create_task(issue, parent_guid)
        elsif mapping.parent_task_guid != parent_guid
          move_task(issue, mapping, parent_guid)
        else
          update_task(issue, mapping)
        end
      end

      def sync_destroy(issue_id, task_guid = nil)
        guid = task_guid.presence || FeishuTaskMapping.find_by(:issue_id => issue_id)&.task_guid
        delete_remote_task(guid)
        FeishuTaskMapping.where(:issue_id => issue_id).delete_all
      end

      def sync_project(project_id)
        project = Project.find_by_id(project_id)
        unless project && self.class.project_enabled?(project)
          Rails.logger.info {"Feishu sync skipped project=#{project_id} reason=not_enabled"}
          return
        end

        Rails.logger.info {"Feishu sync running project=#{project_id}"}
        mapping = FeishuProjectMapping.find_by(:project_id => project_id)
        return ensure_project_section(project) unless mapping

        name = section_name(project)
        begin
          @client.patch_section(mapping.section_guid, {:name => name}, %w(name))
        rescue Error => e
          if e.not_found?
            mapping.destroy
            return ensure_project_section(project)
          end
          raise
        end
      end

      def sync_project_destroy(project_id, section_guid = nil, _unused = nil)
        mapping = FeishuProjectMapping.find_by(:project_id => project_id)
        guid = section_guid.presence || mapping&.section_guid
        delete_remote_section(guid)
        FeishuProjectMapping.where(:project_id => project_id).delete_all
      end

      private

      # Parent is only a synced parent issue. Root issues sit in the project section.
      def parent_task_guid_for(issue)
        parent = issue.parent
        return unless parent && self.class.enabled_for?(parent)

        sync(parent.id) unless FeishuTaskMapping.exists?(:issue_id => parent.id)
        FeishuTaskMapping.where(:issue_id => parent.id).pick(:task_guid)
      end

      # Returns section_guid, or nil when the shared list / section API is unavailable.
      def ensure_project_section(project)
        mapping = FeishuProjectMapping.find_by(:project_id => project.id)
        if mapping&.section_guid.present?
          begin
            @client.get_section(mapping.section_guid)
            return mapping.section_guid
          rescue Error => e
            raise unless e.not_found?

            # Old rows may still hold a former project-task guid; drop and recreate.
            delete_remote_task(mapping.section_guid)
            mapping.destroy
          end
        end

        tasklist_guid = ensure_shared_tasklist
        return if tasklist_guid.blank?

        guid = @client.create_section(
          :name => section_name(project),
          :resource_type => 'tasklist',
          :resource_id => tasklist_guid
        )['guid']
        raise Error, 'create section returned no guid' if guid.blank?

        FeishuProjectMapping.create!(:project => project, :section_guid => guid)
        Rails.logger.info {"Feishu sync created section project=#{project.id} guid=#{guid}"}
        guid
      rescue ActiveRecord::RecordNotUnique
        FeishuProjectMapping.where(:project_id => project.id).pick(:section_guid)
      rescue Error => e
        Rails.logger.error do
          "Feishu project section unavailable project=#{project.id}: #{e.message}"
        end
        nil
      end

      # One Feishu tasklist holds every Redmine project section / issue task.
      # Returns nil when the app lacks tasklist permission so task sync can continue.
      def ensure_shared_tasklist
        guid = configured_tasklist_guid
        if guid.present?
          begin
            @client.get_tasklist(guid)
            return guid
          rescue Error => e
            raise unless e.not_found?

            Rails.logger.warn {'Feishu shared tasklist missing, recreating'}
          end
        end

        entries = shared_tasklist_member_entries
        payload = {:name => 'Redmine'}
        payload[:members] = tasklist_members_payload(entries) if entries.any?
        guid = @client.create_tasklist(payload)['guid']
        raise Error, 'create tasklist returned no guid' if guid.blank?

        Setting.feishu_tasklist_guid = guid
        Rails.logger.info {"Feishu sync created shared tasklist guid=#{guid}"}
        guid
      rescue Error => e
        Rails.logger.error do
          "Feishu shared tasklist unavailable (tasks still sync without a list): #{e.message}"
        end
        nil
      end

      def create_task(issue, parent_guid)
        tasklist_guid = ensure_shared_tasklist
        section_guid = ensure_project_section(issue.project)
        entries = member_entries_for(issue)
        payload = create_payload(issue, entries, tasklist_guid, section_guid)
        # client_token is idempotent for 5 minutes, so a recreated task needs a new one.
        payload[:client_token] = "redmine-issue-#{issue.id}-#{parent_guid}"
        result = if parent_guid.present?
                   @client.create_subtask(parent_guid, payload)
                 else
                   @client.create_task(payload)
                 end
        guid = result['guid']
        raise Error, 'create task returned no guid' if guid.blank?

        FeishuTaskMapping.create!(
          :issue => issue,
          :task_guid => guid,
          :parent_task_guid => parent_guid,
          :assignee_open_id => stored_open_ids(entries),
          :task_completed => issue.closed?
        )
        ensure_in_shared_tasklist(guid, tasklist_guid, section_guid)
      end

      # Feishu cannot re-parent a task, so delete it and its synced descendants
      # and recreate them under the new parent.
      def move_task(issue, mapping, parent_guid)
        stale = FeishuTaskMapping.where(:issue_id => issue.descendants.select(:id)).to_a
        ([mapping] + stale).each do |m|
          delete_remote_task(m.task_guid)
          m.destroy
        end
        create_task(issue, parent_guid)
        Issue.where(:id => stale.map(&:issue_id)).order(:lft).each {|child| sync(child.id)}
      end

      # Fields, members, and tasklist are synced independently so one failure
      # does not block the others.
      def update_task(issue, mapping)
        task, fields = patch_payload(issue, mapping)
        errors = []
        begin
          if fields.any?
            @client.patch_task(mapping.task_guid, task, fields)
            mapping.task_completed = issue.closed? if fields.include?('completed_at')
            Rails.logger.info do
              "Feishu sync patched issue=#{issue.id} guid=#{mapping.task_guid} " \
                "fields=#{fields.join(',')} summary=#{task[:summary].inspect}"
            end
          end
        rescue Error => e
          errors << e
          Rails.logger.error {"Feishu sync patch failed issue=#{issue.id}: #{e.message}"}
        end
        begin
          mapping.assignee_open_id =
            sync_members(mapping.task_guid, member_entries_for(issue), mapping.assignee_open_id)
        rescue Error => e
          errors << e
          Rails.logger.error {"Feishu sync members failed issue=#{issue.id}: #{e.message}"}
        end
        # Tasklist failures must not fail the job after a successful field patch.
        ensure_in_shared_tasklist(
          mapping.task_guid, :resolve, ensure_project_section(issue.project)
        )
        mapping.save
        raise errors.first if errors.any?
      end

      def delete_mapping(mapping)
        delete_remote_task(mapping.task_guid)
        mapping.destroy
      rescue Error => e
        Rails.logger.error {"Feishu task delete failed for issue #{mapping.issue_id}: #{e.message}"}
        mapping.destroy
      end

      def delete_remote_task(guid)
        @client.delete_task(guid) if guid.present?
      rescue Error => e
        raise unless e.not_found?
      end

      def delete_remote_section(guid)
        @client.delete_section(guid) if guid.present?
      rescue Error => e
        raise unless e.not_found?
      end

      def create_payload(issue, entries, tasklist_guid = nil, section_guid = nil)
        payload = {
          :summary => summary_for(issue),
          :description => description_for(issue),
          :origin => origin_for(issue)
        }
        payload.merge!(start_and_due(issue))
        payload[:completed_at] = completed_at_for(issue)
        payload[:members] = members_payload(entries) if entries.any?
        apply_shared_tasklist!(payload, tasklist_guid, section_guid)
        payload
      end

      def configured_tasklist_guid
        Setting.feishu_tasklist_guid.to_s.strip.presence
      end

      def apply_shared_tasklist!(payload, tasklist_guid = nil, section_guid = nil)
        guid = tasklist_guid.presence || configured_tasklist_guid
        return if guid.blank?

        entry = {:tasklist_guid => guid}
        entry[:section_guid] = section_guid if section_guid.present?
        payload[:tasklists] = [entry]
      end

      # Pass an explicit tasklist_guid (including nil after a failed ensure) to
      # avoid retrying create; omit the argument to resolve the shared list.
      def ensure_in_shared_tasklist(task_guid, tasklist_guid = :resolve, section_guid = nil)
        return if task_guid.blank?

        list = (tasklist_guid == :resolve) ? ensure_shared_tasklist : tasklist_guid
        return if list.blank?

        @client.add_tasklist(task_guid, list, :section_guid => section_guid)
        Rails.logger.info do
          "Feishu sync tasklist guid=#{task_guid} list=#{list} section=#{section_guid.inspect}"
        end
      rescue Error => e
        Rails.logger.error {"Feishu sync tasklist failed guid=#{task_guid}: #{e.message}"}
        nil
      end

      def shared_tasklist_member_entries
        default_open_ids.map {|id| "editor:#{id}"}
      end

      def tasklist_members_payload(entries)
        entries.map do |entry|
          role, open_id = entry.split(':', 2)
          role = 'editor' unless %w(editor viewer).include?(role)
          {:id => open_id, :type => 'user', :role => role}
        end
      end

      def patch_payload(issue, mapping)
        task = {
          :summary => summary_for(issue),
          :description => description_for(issue)
        }
        # Origin is create-only. Empty start/due must be cleared by omitting the
        # value (not timestamp 0), otherwise Feishu rejects the whole patch.
        fields = %w(summary description)
        start_due = start_and_due(issue)
        if start_due.key?(:start)
          task[:start] = start_due[:start]
        end
        fields << 'start'
        if start_due.key?(:due)
          task[:due] = start_due[:due]
        end
        fields << 'due'
        # Feishu rejects setting a new non-zero completed_at on an already completed task.
        if issue.closed? != mapping.task_completed?
          task[:completed_at] = completed_at_for(issue)
          fields << 'completed_at'
        end
        [task, fields]
      end

      # Members are stored as "role:open_id" entries.
      def sync_members(task_guid, desired, stored)
        previous = parse_member_entries(stored)
        removed = previous - desired
        added = desired - previous
        @client.remove_members(task_guid, members_payload(removed)) if removed.any?
        @client.add_members(task_guid, members_payload(added)) if added.any?
        stored_open_ids(desired)
      end

      # The assignee's open_id is the Feishu assignee; the author and the global
      # open_id list are followers (CC).
      def member_entries_for(issue)
        assignee = resolve_open_id(issue.assigned_to)
        followers = ([resolve_open_id(issue.author)] + default_open_ids).compact.uniq - [assignee]
        entries = []
        entries << "assignee:#{assignee}" if assignee.present?
        entries + followers.map {|id| "follower:#{id}"}
      end

      def members_payload(entries)
        entries.map do |entry|
          role, open_id = entry.split(':', 2)
          {:id => open_id, :type => 'user', :role => role}
        end
      end

      def parse_member_entries(value)
        parse_open_ids(value).map {|entry| entry.include?(':') ? entry : "assignee:#{entry}"}
      end

      def default_open_ids
        parse_open_ids(Setting.feishu_default_open_id)
      end

      def parse_open_ids(value)
        value.to_s.split(/[\s,;]+/).map(&:strip).reject(&:blank?).uniq
      end

      def stored_open_ids(ids)
        ids.presence&.join(',')
      end

      def resolve_open_id(principal)
        return unless principal.is_a?(User)

        cached = FeishuUserMapping.find_by(:user_id => principal.id)
        return cached.open_id if cached&.open_id.present?

        if principal.mail.present?
          open_id = @client.open_id_for_email(principal.mail)
          if open_id.present?
            mapping = FeishuUserMapping.find_or_initialize_by(:user_id => principal.id)
            mapping.open_id = open_id
            mapping.save
            return open_id
          end
        end

        nil
      rescue Error => e
        Rails.logger.error {"Feishu user lookup failed for user #{principal.id}: #{e.message}"}
        nil
      end

      def summary_for(issue)
        truncate_text("##{issue.id} [#{issue.status&.name}] #{issue.subject}")
      end

      def description_for(issue)
        lines = [
          "#{::I18n.t(:field_status)}: #{issue.status&.name}",
          "#{::I18n.t(:field_author)}: #{issue.author&.name}"
        ]
        body = issue.description.to_s.strip
        lines << '' << body if body.present?
        notes = recent_notes_for(issue)
        lines << '' << notes if notes.present?
        truncate_text(lines.join("\n"))
      end

      # Notes are the most common Redmine "update"; include the latest few so
      # a notes-only save still changes the Feishu description.
      def recent_notes_for(issue)
        journals = issue.journals.preload(:user).where.not(:notes => [nil, '']).reorder(:id => :desc).limit(5).to_a
        return if journals.empty?

        blocks = journals.reverse.map do |journal|
          stamp = journal.created_on&.in_time_zone&.strftime('%Y-%m-%d %H:%M')
          author = journal.user&.name
          header = [stamp, author].compact.join(' ')
          "#{header}:\n#{journal.notes.to_s.strip}"
        end
        ("#{::I18n.t(:label_comment_plural)}:\n" + blocks.join("\n\n"))
      end

      def section_name(project)
        truncate_text(project.name.to_s)
      end

      def truncate_text(text)
        text.to_s.truncate(MAX_TEXT, :omission => '')
      end

      def origin_for(record)
        origin = {
          :platform_i18n_name => {
            :zh_cn => 'Redmine',
            :en_us => 'Redmine'
          }
        }
        url = record_url(record)
        origin[:href] = {:url => url, :title => origin_title(record)} if url.present?
        origin
      end

      # Origin is create-only, so its title must not contain renamable content.
      def origin_title(record)
        "#{::I18n.t(:label_issue)} ##{record.id}"
      end

      def record_url(record)
        base = Setting.feishu_issue_base_url.to_s.strip.presence
        if base.present?
          return "#{base.chomp('/')}/#{record.class.model_name.route_key}/#{record.to_param}"
        end

        Rails.application.routes.url_helpers.polymorphic_url(record, Mailer.default_url_options)
      rescue StandardError
        nil
      end

      def start_and_due(issue)
        result = {}
        start_ts = date_timestamp(issue.start_date)
        due_ts = date_timestamp(issue.due_date)
        if start_ts && due_ts && start_ts.to_i > due_ts.to_i
          start_ts = nil
        end
        result[:start] = {:timestamp => start_ts.to_s, :is_all_day => true} if start_ts
        result[:due] = {:timestamp => due_ts.to_s, :is_all_day => true} if due_ts
        result
      end

      def date_timestamp(date)
        return if date.blank?

        Time.utc(date.year, date.month, date.day).to_i * 1000
      end

      def completed_at_for(issue)
        if issue.closed?
          time = issue.closed_on || Time.current
          (time.to_f * 1000).to_i.to_s
        else
          '0'
        end
      end
    end
  end
end
