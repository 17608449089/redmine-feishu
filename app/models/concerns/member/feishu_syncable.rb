# frozen_string_literal: true

# Redmine - project management software
# Copyright (C) 2006-  Jean-Philippe Lang

module Member::FeishuSyncable
  extend ActiveSupport::Concern

  included do
    after_commit :enqueue_feishu_project_member_sync, :on => [:create, :destroy]
  end

  private

  # Group memberships are expanded into user memberships, so only users matter.
  def enqueue_feishu_project_member_sync
    return unless principal.is_a?(User)
    return unless Redmine::Feishu::TaskSync.project_enabled?(Project.find_by(:id => project_id))

    FeishuTaskSyncJob.perform_later('project_update', project_id)
  end
end
