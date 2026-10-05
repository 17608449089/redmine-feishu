# frozen_string_literal: true

# Redmine - project management software
# Copyright (C) 2006-  Jean-Philippe Lang

module Issue::FeishuSyncable
  extend ActiveSupport::Concern

  included do
    # Capture task_guid before dependent: :delete removes the mapping row.
    before_destroy :store_feishu_task_guid_for_sync, :prepend => true
    has_one :feishu_task_mapping, :dependent => :delete
    after_create_commit :enqueue_feishu_task_sync_create
    after_update_commit :enqueue_feishu_task_sync_update
    after_destroy_commit :enqueue_feishu_task_sync_destroy
  end

  private

  def enqueue_feishu_task_sync_create
    unless Redmine::Feishu::TaskSync.should_enqueue?(self)
      log_feishu_sync_skip('create')
      return
    end

    FeishuTaskSyncJob.perform_later('create', id)
  end

  def enqueue_feishu_task_sync_update
    unless Redmine::Feishu::TaskSync.should_enqueue?(self)
      log_feishu_sync_skip('update')
      return
    end

    FeishuTaskSyncJob.perform_later('update', id)
  end

  def store_feishu_task_guid_for_sync
    @feishu_task_guid_for_sync = feishu_task_mapping&.task_guid
  end

  def enqueue_feishu_task_sync_destroy
    guid = @feishu_task_guid_for_sync
    return if guid.blank?

    FeishuTaskSyncJob.perform_later('destroy', id, guid)
  end

  def log_feishu_sync_skip(action)
    Rails.logger.info do
      "Feishu sync skipped action=#{action} issue=#{id} " \
        "global=#{Setting.feishu_task_sync_enabled?} " \
        "module=#{project&.module_enabled?(:feishu_task_sync)} " \
        "private=#{is_private?}"
    end
  end
end
