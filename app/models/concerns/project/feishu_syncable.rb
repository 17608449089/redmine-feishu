# frozen_string_literal: true

# Redmine - project management software
# Copyright (C) 2006-  Jean-Philippe Lang

module Project::FeishuSyncable
  extend ActiveSupport::Concern

  included do
    # Capture section_guid before dependent: :delete removes the mapping row.
    before_destroy :store_feishu_section_guid_for_sync, :prepend => true
    has_one :feishu_project_mapping, :dependent => :delete
    after_save_commit :enqueue_feishu_project_sync
    after_destroy_commit :enqueue_feishu_project_destroy
  end

  # close/reopen/unarchive use update_all, which skips callbacks.
  def enqueue_feishu_project_sync_for_tree
    enqueue_feishu_project_updates(self_and_ancestors.ids | self_and_descendants.ids)
  end

  private

  def enqueue_feishu_project_sync
    enqueue_feishu_project_updates([id])
  end

  def enqueue_feishu_project_updates(ids)
    return unless Setting.feishu_task_sync_enabled?

    mapped = FeishuProjectMapping.where(:project_id => ids).pluck(:project_id)
    Project.where(:id => ids).order(:lft).each do |project|
      next unless mapped.include?(project.id) || Redmine::Feishu::TaskSync.project_enabled?(project)

      FeishuTaskSyncJob.perform_later('project_update', project.id)
    end
  end

  def store_feishu_section_guid_for_sync
    @feishu_section_guid_for_sync = feishu_project_mapping&.section_guid
  end

  def enqueue_feishu_project_destroy
    guid = @feishu_section_guid_for_sync
    return if guid.blank?

    FeishuTaskSyncJob.perform_later('project_destroy', id, guid)
  end
end
