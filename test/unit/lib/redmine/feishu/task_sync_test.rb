# frozen_string_literal: true

# Redmine - project management software
# Copyright (C) 2006-  Jean-Philippe Lang

require_relative '../../../../test_helper'

class Redmine::Feishu::TaskSyncTest < ActiveSupport::TestCase
  fixtures :projects, :users, :email_addresses, :roles, :members, :member_roles,
           :trackers, :projects_trackers, :enabled_modules, :issue_statuses,
           :issues, :enumerations, :custom_fields, :custom_values, :custom_fields_trackers

  class FakeClient
    attr_reader :created, :patched, :deleted, :added_members, :removed_members, :looked_up_emails

    def initialize(guid: 'task-guid-1', open_ids: {})
      @guid = guid
      @open_ids = open_ids
      @created = []
      @patched = []
      @deleted = []
      @added_members = []
      @removed_members = []
      @looked_up_emails = []
    end

    def create_task(payload)
      @created << payload
      {'guid' => @guid}
    end

    def patch_task(guid, task, fields)
      @patched << {:guid => guid, :task => task, :fields => fields}
      {'guid' => guid}
    end

    def delete_task(guid)
      @deleted << guid
      {}
    end

    def add_members(guid, members)
      @added_members << {:guid => guid, :members => members}
    end

    def remove_members(guid, members)
      @removed_members << {:guid => guid, :members => members}
    end

    def open_id_for_email(email)
      @looked_up_emails << email
      @open_ids[email]
    end
  end

  def setup
    User.current = nil
    @project = Project.find(1)
    @client = FakeClient.new(:open_ids => {'jsmith@somenet.foo' => 'ou_jsmith'})
    @sync = Redmine::Feishu::TaskSync.new(:client => @client)
    FeishuTaskSyncJob.stubs(:perform_later)
  end

  def enable_sync!(project = @project)
    project.reload
    project.enabled_module_names = project.enabled_module_names | ['feishu_task_sync']
    project.reload
    Setting.feishu_task_sync_enabled = '1'
  end

  def test_enabled_for_requires_setting_and_module
    issue = Issue.find(1)
    assert_not Redmine::Feishu::TaskSync.enabled_for?(issue)

    Setting.feishu_task_sync_enabled = '1'
    assert_not Redmine::Feishu::TaskSync.enabled_for?(issue)

    enable_sync!
    issue.reload
    assert Redmine::Feishu::TaskSync.enabled_for?(issue)
  end

  def test_enabled_for_skips_private_issues
    enable_sync!
    issue = Issue.find(1)
    issue.is_private = true
    assert_not Redmine::Feishu::TaskSync.enabled_for?(issue)
  end

  def test_sync_skipped_when_disabled
    issue = Issue.generate!
    @sync.sync(issue.id)
    assert_empty @client.created
    assert_equal 0, FeishuTaskMapping.count
  end

  def test_sync_creates_task_and_mapping
    enable_sync!
    issue = Issue.generate!(:subject => 'Fix login', :description => 'Details',
                            :start_date => Date.new(2024, 1, 2), :due_date => Date.new(2024, 1, 5),
                            :assigned_to_id => 2)

    @sync.sync(issue.id)

    assert_equal 1, @client.created.size
    payload = @client.created.first
    assert_equal "##{issue.id} [#{issue.status.name}] Fix login", payload[:summary]
    assert_includes payload[:description], "Status: #{issue.status.name}"
    assert_includes payload[:description], "Author: #{issue.author.name}"
    assert_includes payload[:description], 'Details'
    assert_equal '0', payload[:completed_at]
    assert_equal 'redmine-issue-' + issue.id.to_s, payload[:client_token]
    assert_equal (Time.utc(2024, 1, 2).to_i * 1000).to_s, payload[:start][:timestamp]
    assert_equal (Time.utc(2024, 1, 5).to_i * 1000).to_s, payload[:due][:timestamp]
    assert_equal true, payload[:start][:is_all_day]
    assert_equal 'ou_jsmith', payload[:members].first[:id]
    assert_equal 'assignee', payload[:members].first[:role]
    assert_equal 'Redmine', payload[:origin][:platform_i18n_name][:en_us]
    assert_includes payload[:origin][:href][:url], "/issues/#{issue.id}"

    mapping = FeishuTaskMapping.find_by(:issue_id => issue.id)
    assert_not_nil mapping
    assert_equal 'task-guid-1', mapping.task_guid
    assert_equal 'ou_jsmith', mapping.assignee_open_id
    assert_equal 'ou_jsmith', FeishuUserMapping.find_by(:user_id => 2).open_id
  end

  def test_sync_create_adds_author_as_member
    enable_sync!
    @client = FakeClient.new(:open_ids => {
      'jsmith@somenet.foo' => 'ou_jsmith',
      'dlopper@somenet.foo' => 'ou_dlopper'
    })
    @sync = Redmine::Feishu::TaskSync.new(:client => @client)
    issue = Issue.generate!(:author_id => 3, :assigned_to_id => 2)

    @sync.sync(issue.id)

    assert_equal ['ou_dlopper', 'ou_jsmith'], @client.created.first[:members].map {|m| m[:id]}
  end

  def test_sync_origin_uses_configured_base_url
    enable_sync!
    Setting.feishu_issue_base_url = 'http://118.178.179.139:12323'
    issue = Issue.generate!

    @sync.sync(issue.id)

    assert_equal "http://118.178.179.139:12323/issues/#{issue.id}",
                 @client.created.first[:origin][:href][:url]
  end

  def test_sync_create_omits_members_when_email_not_mapped
    enable_sync!
    @client = FakeClient.new(:open_ids => {})
    @sync = Redmine::Feishu::TaskSync.new(:client => @client)
    issue = Issue.generate!(:assigned_to_id => 2)

    @sync.sync(issue.id)

    assert_nil @client.created.first[:members]
    assert_nil FeishuTaskMapping.find_by(:issue_id => issue.id).assignee_open_id
  end

  def test_sync_create_uses_default_open_id_when_email_not_mapped
    enable_sync!
    Setting.feishu_default_open_id = 'ou_default'
    @client = FakeClient.new(:open_ids => {})
    @sync = Redmine::Feishu::TaskSync.new(:client => @client)
    issue = Issue.generate!(:assigned_to_id => 2)

    @sync.sync(issue.id)

    assert_equal 'ou_default', @client.created.first[:members].first[:id]
    assert_equal 'ou_default', FeishuTaskMapping.find_by(:issue_id => issue.id).assignee_open_id
  end

  def test_sync_create_uses_multiple_default_open_ids
    enable_sync!
    Setting.feishu_default_open_id = "ou_a, ou_b\nou_c"
    @client = FakeClient.new(:open_ids => {})
    @sync = Redmine::Feishu::TaskSync.new(:client => @client)
    issue = Issue.generate!(:assigned_to_id => 2)

    @sync.sync(issue.id)

    assert_equal ['ou_a', 'ou_b', 'ou_c'], @client.created.first[:members].map {|m| m[:id]}
    assert_equal 'ou_a,ou_b,ou_c', FeishuTaskMapping.find_by(:issue_id => issue.id).assignee_open_id
  end

  def test_sync_create_adds_defaults_along_with_mapped_assignee
    enable_sync!
    Setting.feishu_default_open_id = 'ou_a, ou_b'
    issue = Issue.generate!(:assigned_to_id => 2)

    @sync.sync(issue.id)

    assert_equal ['ou_jsmith', 'ou_a', 'ou_b'], @client.created.first[:members].map {|m| m[:id]}
    assert_equal 'ou_jsmith,ou_a,ou_b', FeishuTaskMapping.find_by(:issue_id => issue.id).assignee_open_id
  end

  def test_sync_updates_existing_task_and_completed_at
    enable_sync!
    issue = Issue.generate!(:subject => 'Open')
    FeishuTaskMapping.create!(:issue => issue, :task_guid => 'guid-existing', :task_completed => false)

    issue.status = IssueStatus.find(5)
    issue.save!
    @sync.sync(issue.id)

    assert_empty @client.created
    assert_equal 1, @client.patched.size
    patch = @client.patched.first
    assert_equal 'guid-existing', patch[:guid]
    assert_includes patch[:fields], 'completed_at'
    assert_includes patch[:fields], 'summary'
    assert_match(/\A\d+\z/, patch[:task][:completed_at])
    assert_not_equal '0', patch[:task][:completed_at]
    assert_equal "##{issue.id} [#{issue.status.name}] Open", patch[:task][:summary]
    assert_includes patch[:task][:description], "Status: #{issue.status.name}"
    assert FeishuTaskMapping.find_by(:issue_id => issue.id).task_completed?
  end

  def test_sync_skips_completed_at_when_already_synced
    enable_sync!
    issue = Issue.generate!(:status_id => 5, :subject => 'Closed')
    FeishuTaskMapping.create!(:issue => issue, :task_guid => 'guid-done', :task_completed => true)
    issue.subject = 'Closed renamed'
    issue.save!

    @sync.sync(issue.id)

    patch = @client.patched.first
    assert_not_includes patch[:fields], 'completed_at'
    assert_equal "##{issue.id} [#{issue.status.name}] Closed renamed", patch[:task][:summary]
  end

  def test_sync_reopens_completed_task
    enable_sync!
    issue = Issue.generate!(:status_id => 5)
    FeishuTaskMapping.create!(:issue => issue, :task_guid => 'guid-closed', :task_completed => true)
    issue.status = IssueStatus.find(1)
    issue.save!

    @sync.sync(issue.id)

    assert_equal '0', @client.patched.first[:task][:completed_at]
    assert_not FeishuTaskMapping.find_by(:issue_id => issue.id).task_completed?
  end

  def test_sync_patches_summary_and_description_on_status_change
    enable_sync!
    issue = Issue.generate!(:subject => 'Work', :description => 'Body')
    FeishuTaskMapping.create!(:issue => issue, :task_guid => 'guid-status', :task_completed => false)
    issue.status = IssueStatus.find(2)
    issue.save!

    @sync.sync(issue.id)

    patch = @client.patched.first
    assert_includes patch[:fields], 'summary'
    assert_includes patch[:fields], 'description'
    assert_not_includes patch[:fields], 'completed_at'
    assert_equal "##{issue.id} [Assigned] Work", patch[:task][:summary]
    assert_includes patch[:task][:description], 'Status: Assigned'
    assert_includes patch[:task][:description], 'Body'
  end

  def test_sync_updates_assignee_via_member_apis
    enable_sync!
    issue = Issue.generate!(:assigned_to_id => 2)
    FeishuTaskMapping.create!(:issue => issue, :task_guid => 'guid-m', :assignee_open_id => 'ou_old')
    @client = FakeClient.new(:open_ids => {'jsmith@somenet.foo' => 'ou_jsmith'})
    @sync = Redmine::Feishu::TaskSync.new(:client => @client)

    @sync.sync(issue.id)

    assert_equal 'ou_old', @client.removed_members.first[:members].first[:id]
    assert_equal 'ou_jsmith', @client.added_members.first[:members].first[:id]
    assert_equal 'ou_jsmith', issue.feishu_task_mapping.reload.assignee_open_id
  end

  def test_sync_updates_multiple_default_members
    enable_sync!
    Setting.feishu_default_open_id = 'ou_b, ou_c'
    issue = Issue.generate!(:assigned_to_id => 2)
    FeishuTaskMapping.create!(:issue => issue, :task_guid => 'guid-multi',
                              :assignee_open_id => 'ou_jsmith,ou_a')
    @client = FakeClient.new(:open_ids => {'jsmith@somenet.foo' => 'ou_jsmith'})
    @sync = Redmine::Feishu::TaskSync.new(:client => @client)

    @sync.sync(issue.id)

    assert_equal ['ou_a'], @client.removed_members.first[:members].map {|m| m[:id]}
    assert_equal ['ou_b', 'ou_c'], @client.added_members.first[:members].map {|m| m[:id]}
    assert_equal 'ou_jsmith,ou_b,ou_c', issue.feishu_task_mapping.reload.assignee_open_id
  end

  def test_sync_destroy_deletes_remote_task_and_mapping
    issue = Issue.generate!
    FeishuTaskMapping.create!(:issue => issue, :task_guid => 'guid-del')

    @sync.sync_destroy(issue.id, 'guid-del')

    assert_equal ['guid-del'], @client.deleted
    assert_nil FeishuTaskMapping.find_by(:issue_id => issue.id)
  end

  def test_sync_deletes_remote_task_when_issue_becomes_private
    enable_sync!
    issue = Issue.generate!
    FeishuTaskMapping.create!(:issue => issue, :task_guid => 'guid-private')
    issue.is_private = true
    issue.save!

    @sync.sync(issue.id)

    assert_equal ['guid-private'], @client.deleted
    assert_nil FeishuTaskMapping.find_by(:issue_id => issue.id)
  end

  def test_should_enqueue_when_enabled
    issue = Issue.find(1)
    assert_not Redmine::Feishu::TaskSync.should_enqueue?(issue)
    enable_sync!
    issue.reload
    assert Redmine::Feishu::TaskSync.should_enqueue?(issue)
  end
end
