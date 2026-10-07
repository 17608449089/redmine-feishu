# frozen_string_literal: true

# Redmine - project management software
# Copyright (C) 2006-  Jean-Philippe Lang

class FeishuTaskSyncJob < ApplicationJob
  def perform(action, record_id, task_guid = nil, tasklist_guid = nil)
    Rails.logger.info {"Feishu task sync start action=#{action} id=#{record_id}"}
    sync = Redmine::Feishu::TaskSync.new
    case action.to_s
    when 'create', 'update'
      sync.sync(record_id)
    when 'destroy'
      sync.sync_destroy(record_id, task_guid)
    when 'project_update'
      sync.sync_project(record_id)
    when 'project_destroy'
      sync.sync_project_destroy(record_id, task_guid, tasklist_guid)
    else
      Rails.logger.error {"FeishuTaskSyncJob: unknown action #{action.inspect}"}
    end
  rescue Redmine::Feishu::Error => e
    Rails.logger.error {"Feishu task sync #{action} id=#{record_id} failed: #{e.message}"}
  rescue StandardError => e
    Rails.logger.error {"Feishu task sync #{action} id=#{record_id} error: #{e.class}: #{e.message}"}
  end
end
