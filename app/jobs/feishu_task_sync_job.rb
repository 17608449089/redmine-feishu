# frozen_string_literal: true

# Redmine - project management software
# Copyright (C) 2006-  Jean-Philippe Lang

class FeishuTaskSyncJob < ApplicationJob
  def perform(action, issue_id, task_guid = nil)
    Rails.logger.info {"Feishu task sync start action=#{action} issue=#{issue_id}"}
    sync = Redmine::Feishu::TaskSync.new
    case action.to_s
    when 'create', 'update'
      sync.sync(issue_id)
    when 'destroy'
      sync.sync_destroy(issue_id, task_guid)
    else
      Rails.logger.error {"FeishuTaskSyncJob: unknown action #{action.inspect}"}
    end
  rescue Redmine::Feishu::Error => e
    Rails.logger.error {"Feishu task sync #{action} issue=#{issue_id} failed: #{e.message}"}
  rescue StandardError => e
    Rails.logger.error {"Feishu task sync #{action} issue=#{issue_id} error: #{e.class}: #{e.message}"}
  end
end
