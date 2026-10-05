# frozen_string_literal: true

# Redmine - project management software
# Copyright (C) 2006-  Jean-Philippe Lang

module Redmine
  module Feishu
    class TaskSync
      MAX_TEXT = 3000

      def self.enabled_for?(issue)
        return false unless Setting.feishu_task_sync_enabled?
        return false if issue.nil? || issue.project.nil?
        return false if issue.is_private?

        issue.project.module_enabled?(:feishu_task_sync)
      end

      def self.should_enqueue?(issue)
        return false unless Setting.feishu_task_sync_enabled?
        return false unless issue.project&.module_enabled?(:feishu_task_sync)
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
        if mapping
          update_task(issue, mapping)
        else
          create_task(issue)
        end
      end

      def sync_destroy(issue_id, task_guid = nil)
        guid = task_guid.presence || FeishuTaskMapping.find_by(:issue_id => issue_id)&.task_guid
        @client.delete_task(guid) if guid.present?
        FeishuTaskMapping.where(:issue_id => issue_id).delete_all
      end

      private

      def create_task(issue)
        payload = create_payload(issue)
        result = @client.create_task(payload)
        guid = result['guid']
        raise Error, 'create task returned no guid' if guid.blank?

        FeishuTaskMapping.create!(
          :issue => issue,
          :task_guid => guid,
          :assignee_open_id => stored_open_ids(member_open_ids_for(issue)),
          :task_completed => issue.closed?
        )
      end

      def update_task(issue, mapping)
        task, fields = patch_payload(issue, mapping)
        @client.patch_task(mapping.task_guid, task, fields) if fields.any?
        attrs = {}
        attrs[:task_completed] = issue.closed? if fields.include?('completed_at')
        attrs[:assignee_open_id] = sync_assignee(issue, mapping)
        mapping.update(attrs) if attrs.any?
      end

      def delete_mapping(mapping)
        @client.delete_task(mapping.task_guid) if mapping.task_guid.present?
        mapping.destroy
      rescue Error => e
        Rails.logger.error {"Feishu task delete failed for issue #{mapping.issue_id}: #{e.message}"}
        mapping.destroy
      end

      def create_payload(issue)
        payload = {
          :summary => summary_for(issue),
          :description => description_for(issue),
          :client_token => "redmine-issue-#{issue.id}",
          :origin => origin_for(issue)
        }
        start_due = start_and_due(issue)
        payload.merge!(start_due)
        payload[:completed_at] = completed_at_for(issue)
        members = members_for(issue)
        payload[:members] = members if members.any?
        payload
      end

      def patch_payload(issue, mapping)
        task = {
          :summary => summary_for(issue),
          :description => description_for(issue)
        }
        fields = %w(summary description)
        start_due = start_and_due(issue)
        if start_due.key?(:start)
          task[:start] = start_due[:start]
        else
          task[:start] = {:timestamp => '0'}
        end
        fields << 'start'
        if start_due.key?(:due)
          task[:due] = start_due[:due]
        else
          task[:due] = {:timestamp => '0'}
        end
        fields << 'due'
        # Feishu rejects setting a new non-zero completed_at on an already completed task.
        if issue.closed? != mapping.task_completed?
          task[:completed_at] = completed_at_for(issue)
          fields << 'completed_at'
        end
        [task, fields]
      end

      def sync_assignee(issue, mapping)
        desired = member_open_ids_for(issue)
        previous = parse_open_ids(mapping.assignee_open_id)
        removed = previous - desired
        added = desired - previous
        @client.remove_members(mapping.task_guid, removed.map {|id| member_hash(id)}) if removed.any?
        @client.add_members(mapping.task_guid, added.map {|id| member_hash(id)}) if added.any?
        stored_open_ids(desired)
      end

      def members_for(issue)
        member_open_ids_for(issue).map {|id| member_hash(id)}
      end

      def member_open_ids_for(issue)
        ids = []
        assignee = resolve_open_id(issue.assigned_to)
        ids << assignee if assignee.present?
        ids.concat(default_open_ids)
        ids.uniq
      end

      def member_hash(open_id)
        {:id => open_id, :type => 'user', :role => 'assignee'}
      end

      def default_open_ids
        parse_open_ids(Setting.feishu_default_open_id)
      end

      def parse_open_ids(value)
        value.to_s.split(/[\s,;]+/).map(&:strip).reject(&:blank?).uniq
      end

      def stored_open_ids(ids)
        ids.present? ? ids.join(',') : nil
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
        lines = ["#{::I18n.t(:field_status)}: #{issue.status&.name}"]
        body = issue.description.to_s.strip
        lines << '' << body if body.present?
        truncate_text(lines.join("\n"))
      end

      def truncate_text(text)
        text.to_s.truncate(MAX_TEXT, :omission => '')
      end

      def origin_for(issue)
        origin = {
          :platform_i18n_name => {
            :zh_cn => 'Redmine',
            :en_us => 'Redmine'
          }
        }
        url = issue_url(issue)
        if url.present?
          origin[:href] = {:url => url, :title => summary_for(issue)}
        end
        origin
      end

      def issue_url(issue)
        Rails.application.routes.url_helpers.issue_url(issue, Mailer.default_url_options)
      rescue ArgumentError, StandardError
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
