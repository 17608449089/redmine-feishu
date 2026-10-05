# frozen_string_literal: true

# Redmine - project management software
# Copyright (C) 2006-  Jean-Philippe Lang

require_relative '../../test_helper'

class FeishuTaskSyncJobTest < ActiveJob::TestCase
  fixtures :projects, :users, :email_addresses, :roles, :members, :member_roles,
           :trackers, :projects_trackers, :enabled_modules, :issue_statuses,
           :issues, :enumerations, :custom_fields, :custom_values, :custom_fields_trackers

  def setup
    @original_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
  end

  def teardown
    ActiveJob::Base.queue_adapter = @original_adapter
  end

  def enable_sync!
    project = Project.find(1)
    project.enabled_module_names = project.enabled_module_names | ['feishu_task_sync']
    Setting.feishu_task_sync_enabled = '1'
  end

  def test_create_action_calls_sync
    Redmine::Feishu::TaskSync.any_instance.expects(:sync).with(12)
    FeishuTaskSyncJob.perform_now('create', 12)
  end

  def test_update_action_calls_sync
    Redmine::Feishu::TaskSync.any_instance.expects(:sync).with(12)
    FeishuTaskSyncJob.perform_now('update', 12)
  end

  def test_destroy_action_calls_sync_destroy
    Redmine::Feishu::TaskSync.any_instance.expects(:sync_destroy).with(12, 'guid-x')
    FeishuTaskSyncJob.perform_now('destroy', 12, 'guid-x')
  end

  def test_swallows_feishu_errors
    Redmine::Feishu::TaskSync.any_instance.stubs(:sync).raises(Redmine::Feishu::Error, 'boom')
    assert_nothing_raised do
      FeishuTaskSyncJob.perform_now('update', 1)
    end
  end

  def test_issue_create_enqueues_job_when_enabled
    enable_sync!
    issue = Issue.find(1)
    assert_enqueued_with(:job => FeishuTaskSyncJob, :args => ['create', issue.id]) do
      issue.send(:enqueue_feishu_task_sync_create)
    end
  end

  def test_issue_create_does_not_enqueue_when_disabled
    issue = Issue.find(1)
    assert_no_enqueued_jobs :only => FeishuTaskSyncJob do
      issue.send(:enqueue_feishu_task_sync_create)
    end
  end

  def test_issue_title_update_enqueues_job_when_enabled
    enable_sync!
    issue = Issue.generate!(:subject => 'Old title')
    assert_enqueued_with(:job => FeishuTaskSyncJob, :args => ['update', issue.id]) do
      issue.update!(:subject => 'New title')
    end
  end

  def test_issue_date_and_title_update_enqueues_job_when_enabled
    enable_sync!
    issue = Issue.generate!(:subject => 'Old', :start_date => Date.today, :due_date => Date.today + 1)
    assert_enqueued_with(:job => FeishuTaskSyncJob, :args => ['update', issue.id]) do
      issue.update!(:subject => 'New', :due_date => Date.today + 3)
    end
  end

  def test_issue_destroy_enqueues_job_with_task_guid
    enable_sync!
    Redmine::Feishu::TaskSync.any_instance.stubs(:sync_destroy)
    issue = Issue.generate!
    FeishuTaskMapping.create!(:issue => issue, :task_guid => 'guid-destroy')

    assert_enqueued_with(:job => FeishuTaskSyncJob, :args => ['destroy', issue.id, 'guid-destroy']) do
      issue.destroy
    end
  end
end
