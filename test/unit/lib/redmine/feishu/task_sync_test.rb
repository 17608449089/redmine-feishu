# frozen_string_literal: true

# Redmine - project management software
# Copyright (C) 2006-  Jean-Philippe Lang

require_relative '../../../../test_helper'

class Redmine::Feishu::TaskSyncTest < ActiveSupport::TestCase
  fixtures :projects, :users, :email_addresses, :roles, :members, :member_roles,
           :trackers, :projects_trackers, :enabled_modules, :issue_statuses,
           :issues, :enumerations, :custom_fields, :custom_values, :custom_fields_trackers

  class FakeClient
    attr_reader :created, :subtasks, :patched, :deleted, :added_members, :removed_members,
                :added_tasklists, :created_tasklists, :patched_tasklists, :deleted_tasklists,
                :added_tasklist_members, :removed_tasklist_members, :looked_up_emails

    def initialize(open_ids: {}, missing: [], fail_patch: false, fail_tasklist: false)
      @open_ids = open_ids
      @missing = missing
      @fail_patch = fail_patch
      @fail_tasklist = fail_tasklist
      @seq = 0
      @created = []
      @subtasks = []
      @patched = []
      @deleted = []
      @added_members = []
      @removed_members = []
      @added_tasklists = []
      @created_tasklists = []
      @patched_tasklists = []
      @deleted_tasklists = []
      @added_tasklist_members = []
      @removed_tasklist_members = []
      @tasklists = {}
      @looked_up_emails = []
    end

    def create_task(payload)
      @created << payload
      {'guid' => "project-guid-#{@created.size}"}
    end

    def create_subtask(parent_guid, payload)
      @subtasks << payload.merge(:parent => parent_guid)
      {'guid' => "task-guid-#{@subtasks.size}"}
    end

    def patch_task(guid, task, fields)
      raise Redmine::Feishu::Error, 'Net::OpenTimeout' if @fail_patch

      @patched << {:guid => guid, :task => task, :fields => fields}
      {'guid' => guid}
    end

    def delete_task(guid)
      if @missing.include?(guid)
        raise Redmine::Feishu::Error.new('not found', code: Redmine::Feishu::Error::NOT_FOUND)
      end

      @deleted << guid
      {}
    end

    def add_members(guid, members)
      @added_members << {:guid => guid, :members => members}
    end

    def remove_members(guid, members)
      @removed_members << {:guid => guid, :members => members}
    end

    def add_tasklist(guid, tasklist_guid)
      @added_tasklists << {:guid => guid, :tasklist_guid => tasklist_guid}
    end

    def create_tasklist(payload)
      if @fail_tasklist
        raise Redmine::Feishu::Error, 'Access denied. task:tasklist:write required'
      end

      @created_tasklists << payload
      guid = "list-guid-#{@created_tasklists.size}"
      @tasklists[guid] = payload
      {'guid' => guid}
    end

    def get_tasklist(guid)
      if @fail_tasklist
        raise Redmine::Feishu::Error, 'Access denied. task:tasklist:write required'
      end
      raise Redmine::Feishu::Error.new('not found', code: Redmine::Feishu::Error::NOT_FOUND) if @missing.include?(guid)

      @tasklists[guid] || {'guid' => guid}
    end

    def patch_tasklist(guid, tasklist, fields)
      @patched_tasklists << {:guid => guid, :tasklist => tasklist, :fields => fields}
      {'guid' => guid}
    end

    def delete_tasklist(guid)
      if @missing.include?(guid)
        raise Redmine::Feishu::Error.new('not found', code: Redmine::Feishu::Error::NOT_FOUND)
      end

      @deleted_tasklists << guid
      {}
    end

    def add_tasklist_members(guid, members)
      @added_tasklist_members << {:guid => guid, :members => members}
    end

    def remove_tasklist_members(guid, members)
      @removed_tasklist_members << {:guid => guid, :members => members}
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

  def map_project!(project = @project, guid = 'guid-project', **attrs)
    FeishuProjectMapping.create!(attrs.merge(:project => project, :task_guid => guid))
  end

  def map_issue!(issue, guid, parent: 'guid-project', **attrs)
    map_project! unless FeishuProjectMapping.exists?(:project_id => issue.project_id)
    FeishuTaskMapping.create!(attrs.merge(:issue => issue, :task_guid => guid, :parent_task_guid => parent))
  end

  def roles(payload_members)
    payload_members.map {|m| "#{m[:role]}:#{m[:id]}"}
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
    assert_empty @client.subtasks
    assert_equal 0, FeishuTaskMapping.count
  end

  def test_sync_creates_project_task_then_issue_subtask
    enable_sync!
    Setting.feishu_default_open_id = 'ou_cc'
    issue = Issue.generate!(:subject => 'Fix login', :description => 'Details',
                            :start_date => Date.new(2024, 1, 2), :due_date => Date.new(2024, 1, 5),
                            :assigned_to_id => 2)

    @sync.sync(issue.id)

    assert_equal 1, @client.created.size
    project_payload = @client.created.first
    assert_equal "[Project] #{@project.name}", project_payload[:summary]
    assert_equal "redmine-project-#{@project.id}", project_payload[:client_token]
    assert_equal ['assignee:ou_jsmith', 'follower:ou_cc'], roles(project_payload[:members])
    assert_includes project_payload[:origin][:href][:url], "/projects/#{@project.identifier}"
    project_mapping = FeishuProjectMapping.find_by(:project_id => @project.id)
    assert_equal 'project-guid-1', project_mapping.task_guid

    payload = @client.subtasks.first
    assert_equal 'project-guid-1', payload[:parent]
    assert_equal "##{issue.id} [#{issue.status.name}] Fix login", payload[:summary]
    assert_includes payload[:description], "Author: #{issue.author.name}"
    assert_includes payload[:description], 'Details'
    assert_equal '0', payload[:completed_at]
    assert_equal (Time.utc(2024, 1, 2).to_i * 1000).to_s, payload[:start][:timestamp]
    assert_equal (Time.utc(2024, 1, 5).to_i * 1000).to_s, payload[:due][:timestamp]
    assert_includes payload[:origin][:href][:url], "/issues/#{issue.id}"

    mapping = FeishuTaskMapping.find_by(:issue_id => issue.id)
    assert_equal 'task-guid-1', mapping.task_guid
    assert_equal 'project-guid-1', mapping.parent_task_guid
  end

  def test_sync_reuses_existing_project_task
    enable_sync!
    map_project!
    issue = Issue.generate!

    @sync.sync(issue.id)

    assert_empty @client.created
    assert_equal 'guid-project', @client.subtasks.first[:parent]
  end

  def test_assignee_is_feishu_assignee_and_global_ids_are_followers
    enable_sync!
    Setting.feishu_default_open_id = 'ou_a, ou_b'
    FeishuUserMapping.create!(:user_id => 3, :open_id => 'ou_dlopper')
    issue = Issue.generate!(:author_id => 2, :assigned_to_id => 3)

    @sync.sync(issue.id)

    assert_equal ['assignee:ou_dlopper', 'follower:ou_jsmith', 'follower:ou_a', 'follower:ou_b'],
                 roles(@client.subtasks.first[:members])
    assert_equal 'assignee:ou_dlopper,follower:ou_jsmith,follower:ou_a,follower:ou_b',
                 FeishuTaskMapping.find_by(:issue_id => issue.id).assignee_open_id
  end

  def test_configured_user_open_id_skips_email_lookup
    enable_sync!
    Setting.feishu_tasklist_guid = 'shared-list'
    @client.instance_variable_get(:@tasklists)['shared-list'] = {:name => 'Redmine'}
    map_project!
    FeishuUserMapping.create!(:user_id => 2, :open_id => 'ou_manual')
    issue = Issue.generate!(:author_id => 2, :assigned_to_id => 2)

    @sync.sync(issue.id)

    assert_empty @client.looked_up_emails
    assert_equal ['assignee:ou_manual'], roles(@client.subtasks.first[:members])
  end

  def test_global_ids_are_followers_without_assignee
    enable_sync!
    Setting.feishu_default_open_id = "ou_a, ou_b\nou_c"
    @client = FakeClient.new
    @sync = Redmine::Feishu::TaskSync.new(:client => @client)
    issue = Issue.generate!(:assigned_to_id => 2)

    @sync.sync(issue.id)

    assert_equal ['follower:ou_a', 'follower:ou_b', 'follower:ou_c'], roles(@client.subtasks.first[:members])
  end

  def test_sync_origin_uses_configured_base_url
    enable_sync!
    Setting.feishu_issue_base_url = 'http://118.178.179.139:12323'
    issue = Issue.generate!

    @sync.sync(issue.id)

    assert_equal "http://118.178.179.139:12323/issues/#{issue.id}",
                 @client.subtasks.first[:origin][:href][:url]
    assert_equal "http://118.178.179.139:12323/projects/#{@project.identifier}",
                 @client.created.first[:origin][:href][:url]
  end

  def test_origin_title_does_not_contain_renamable_content
    enable_sync!
    issue = Issue.generate!(:subject => 'Old subject')

    @sync.sync(issue.id)

    assert_equal "Issue ##{issue.id}", @client.subtasks.first[:origin][:href][:title]
    assert_equal "Project #{@project.identifier}", @client.created.first[:origin][:href][:title]
  end

  def test_create_uses_one_shared_tasklist_for_project_and_issue
    enable_sync!
    issue = Issue.generate!

    @sync.sync(issue.id)

    assert_equal 1, @client.created_tasklists.size
    assert_equal 'Redmine', @client.created_tasklists.first[:name]
    assert_equal 'list-guid-1', Setting.feishu_tasklist_guid
    assert_equal [{:tasklist_guid => 'list-guid-1'}], @client.created.first[:tasklists]
    assert_equal [{:tasklist_guid => 'list-guid-1'}], @client.subtasks.first[:tasklists]
    assert_includes @client.added_tasklists, {:guid => 'project-guid-1', :tasklist_guid => 'list-guid-1'}
    assert_includes @client.added_tasklists, {:guid => 'task-guid-1', :tasklist_guid => 'list-guid-1'}
  end

  def test_create_reuses_configured_shared_tasklist
    enable_sync!
    Setting.feishu_tasklist_guid = 'shared-list'
    @client.instance_variable_get(:@tasklists)['shared-list'] = {:name => 'Redmine'}
    issue = Issue.generate!

    @sync.sync(issue.id)

    assert_empty @client.created_tasklists
    assert_equal [{:tasklist_guid => 'shared-list'}], @client.created.first[:tasklists]
    assert_equal [{:tasklist_guid => 'shared-list'}], @client.subtasks.first[:tasklists]
  end

  def test_update_adds_existing_task_to_shared_tasklist
    enable_sync!
    Setting.feishu_tasklist_guid = 'shared-list'
    @client.instance_variable_get(:@tasklists)['shared-list'] = {:name => 'Redmine'}
    issue = Issue.generate!
    map_issue!(issue, 'guid-existing')

    @sync.sync(issue.id)

    assert_includes @client.added_tasklists, {:guid => 'guid-existing', :tasklist_guid => 'shared-list'}
  end

  def test_tasklist_permission_failure_does_not_block_issue_create
    enable_sync!
    @client = FakeClient.new(:open_ids => {'jsmith@somenet.foo' => 'ou_jsmith'}, :fail_tasklist => true)
    @sync = Redmine::Feishu::TaskSync.new(:client => @client)
    issue = Issue.generate!(:subject => 'Still synced')

    assert_nothing_raised {@sync.sync(issue.id)}

    assert_equal 1, @client.subtasks.size
    assert_nil @client.subtasks.first[:tasklists]
    assert_equal 'task-guid-1', FeishuTaskMapping.find_by(:issue_id => issue.id).task_guid
    assert_empty Setting.feishu_tasklist_guid.to_s
  end

  def test_tasklist_permission_failure_does_not_block_issue_update
    enable_sync!
    @client = FakeClient.new(:fail_tasklist => true)
    @sync = Redmine::Feishu::TaskSync.new(:client => @client)
    issue = Issue.generate!(:subject => 'Before')
    map_issue!(issue, 'guid-u')
    issue.update!(:subject => 'After')

    assert_nothing_raised {@sync.sync(issue.id)}

    assert_includes @client.patched.first[:task][:summary], 'After'
    assert_empty @client.added_tasklists
  end

  def test_child_issue_is_subtask_of_parent_issue_task
    enable_sync!
    parent = Issue.generate!
    child = Issue.generate!(:parent_issue_id => parent.id)

    @sync.sync(child.id)

    assert_equal ['project-guid-1', 'task-guid-1'], @client.subtasks.pluck(:parent)
    assert_equal 'task-guid-1', FeishuTaskMapping.find_by(:issue_id => parent.id).task_guid
    assert_equal 'task-guid-1', FeishuTaskMapping.find_by(:issue_id => child.id).parent_task_guid
  end

  def test_private_parent_falls_back_to_project_task
    enable_sync!
    parent = Issue.generate!(:is_private => true)
    child = Issue.generate!(:parent_issue_id => parent.id)

    @sync.sync(child.id)

    assert_equal ['project-guid-1'], @client.subtasks.pluck(:parent)
  end

  def test_parent_change_recreates_task_and_descendants
    enable_sync!
    issue = Issue.generate!
    child = Issue.generate!(:parent_issue_id => issue.id)
    map_issue!(issue, 'guid-old', :parent => 'guid-elsewhere')
    map_issue!(child, 'guid-old-child', :parent => 'guid-old')

    @sync.sync(issue.id)

    assert_equal ['guid-old', 'guid-old-child'].sort, @client.deleted.sort
    assert_equal ['guid-project', 'task-guid-1'], @client.subtasks.pluck(:parent)
    assert_equal 'task-guid-1', FeishuTaskMapping.find_by(:issue_id => issue.id).task_guid
    assert_equal 'task-guid-2', FeishuTaskMapping.find_by(:issue_id => child.id).task_guid
    assert_equal 'task-guid-1', FeishuTaskMapping.find_by(:issue_id => child.id).parent_task_guid
  end

  def test_legacy_top_level_task_is_moved_under_project
    enable_sync!
    issue = Issue.generate!
    map_issue!(issue, 'guid-legacy', :parent => nil)

    @sync.sync(issue.id)

    assert_equal ['guid-legacy'], @client.deleted
    assert_equal ['guid-project'], @client.subtasks.pluck(:parent)
  end

  def test_sync_updates_existing_task_and_completed_at
    enable_sync!
    issue = Issue.generate!(:subject => 'Open')
    map_issue!(issue, 'guid-existing', :task_completed => false)

    issue.status = IssueStatus.find(5)
    issue.save!
    @sync.sync(issue.id)

    assert_empty @client.subtasks
    patch = @client.patched.first
    assert_equal 'guid-existing', patch[:guid]
    assert_includes patch[:fields], 'completed_at'
    assert_not_includes patch[:fields], 'origin'
    assert_not_equal '0', patch[:task][:completed_at]
    assert_equal "##{issue.id} [#{issue.status.name}] Open", patch[:task][:summary]
    assert FeishuTaskMapping.find_by(:issue_id => issue.id).task_completed?
  end

  def test_sync_skips_completed_at_when_already_synced
    enable_sync!
    issue = Issue.generate!(:status_id => 5, :subject => 'Closed')
    map_issue!(issue, 'guid-done', :task_completed => true)
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
    map_issue!(issue, 'guid-closed', :task_completed => true)
    issue.status = IssueStatus.find(1)
    issue.save!

    @sync.sync(issue.id)

    assert_equal '0', @client.patched.first[:task][:completed_at]
    assert_not FeishuTaskMapping.find_by(:issue_id => issue.id).task_completed?
  end

  def test_description_includes_recent_notes
    enable_sync!
    issue = Issue.generate!(:description => 'Body text')
    map_issue!(issue, 'guid-notes')
    issue.init_journal(User.find(2), 'Latest note from update')
    issue.save!

    @sync.sync(issue.id)

    description = @client.patched.first[:task][:description]
    assert_includes description, 'Body text'
    assert_includes description, 'Comments:'
    assert_includes description, 'Latest note from update'
  end

  def test_sync_patches_dates_and_title
    enable_sync!
    issue = Issue.generate!(:subject => 'Plan', :start_date => Date.new(2026, 10, 1), :due_date => Date.new(2026, 10, 5))
    map_issue!(issue, 'guid-dates')
    issue.subject = 'Plan renamed'
    issue.due_date = Date.new(2026, 10, 8)
    issue.save!

    @sync.sync(issue.id)

    patch = @client.patched.first
    assert_equal "##{issue.id} [#{issue.status.name}] Plan renamed", patch[:task][:summary]
    assert_equal({:timestamp => (Time.utc(2026, 10, 8).to_i * 1000).to_s, :is_all_day => true}, patch[:task][:due])
    assert_equal %w(summary description start due), patch[:fields]
  end

  def test_sync_changes_member_roles
    enable_sync!
    Setting.feishu_default_open_id = 'ou_jsmith'
    issue = Issue.generate!(:author_id => 1, :assigned_to_id => 2)
    map_issue!(issue, 'guid-m', :assignee_open_id => 'follower:ou_jsmith,assignee:ou_old')

    @sync.sync(issue.id)

    assert_equal ['follower:ou_jsmith', 'assignee:ou_old'], roles(@client.removed_members.first[:members])
    assert_equal ['assignee:ou_jsmith'], roles(@client.added_members.first[:members])
    assert_equal 'assignee:ou_jsmith', issue.feishu_task_mapping.reload.assignee_open_id
  end

  def test_assignee_change_syncs_members_when_patch_fails
    enable_sync!
    @client = FakeClient.new(:fail_patch => true)
    @sync = Redmine::Feishu::TaskSync.new(:client => @client)
    FeishuUserMapping.create!(:user_id => 3, :open_id => 'ou_dlopper')
    issue = Issue.generate!(:author_id => 3, :assigned_to_id => 3)
    map_issue!(issue, 'guid-a', :assignee_open_id => 'follower:ou_dlopper')

    assert_raises(Redmine::Feishu::Error) {@sync.sync(issue.id)}

    assert_equal ['follower:ou_dlopper'], roles(@client.removed_members.first[:members])
    assert_equal ['assignee:ou_dlopper'], roles(@client.added_members.first[:members])
    assert_equal 'assignee:ou_dlopper', issue.feishu_task_mapping.reload.assignee_open_id
  end

  def test_legacy_member_entries_are_treated_as_assignees
    enable_sync!
    issue = Issue.generate!(:author_id => 1, :assigned_to_id => 2)
    map_issue!(issue, 'guid-legacy-members', :assignee_open_id => 'ou_jsmith')

    @sync.sync(issue.id)

    assert_empty @client.removed_members
    assert_empty @client.added_members
  end

  def test_sync_destroy_deletes_remote_task_and_mapping
    issue = Issue.generate!
    FeishuTaskMapping.create!(:issue => issue, :task_guid => 'guid-del')

    @sync.sync_destroy(issue.id, 'guid-del')

    assert_equal ['guid-del'], @client.deleted
    assert_nil FeishuTaskMapping.find_by(:issue_id => issue.id)
  end

  def test_sync_destroy_ignores_already_deleted_task
    @client = FakeClient.new(:missing => ['guid-gone'])
    @sync = Redmine::Feishu::TaskSync.new(:client => @client)
    issue = Issue.generate!
    FeishuTaskMapping.create!(:issue => issue, :task_guid => 'guid-gone')

    assert_nothing_raised {@sync.sync_destroy(issue.id, 'guid-gone')}
    assert_nil FeishuTaskMapping.find_by(:issue_id => issue.id)
  end

  def test_sync_deletes_remote_task_when_issue_becomes_private
    enable_sync!
    issue = Issue.generate!
    map_issue!(issue, 'guid-private')
    issue.is_private = true
    issue.save!

    @sync.sync(issue.id)

    assert_equal ['guid-private'], @client.deleted
    assert_nil FeishuTaskMapping.find_by(:issue_id => issue.id)
  end

  def test_sync_project_creates_task_when_missing
    enable_sync!
    subproject = Project.find(3)
    enable_sync!(subproject)

    @sync.sync_project(subproject.id)

    assert_equal ["[Project] #{@project.name}"], @client.created.pluck(:summary)
    assert_equal ['project-guid-1'], @client.subtasks.pluck(:parent)
    assert_equal 'task-guid-1', FeishuProjectMapping.find_by(:project_id => 3).task_guid
    assert_empty @client.patched
  end

  def test_sync_project_patches_name_and_completion
    enable_sync!
    map_project!(@project, 'guid-project', :task_completed => false)
    @project.update_column(:name, 'Renamed')
    @project.update_column(:status, Project::STATUS_CLOSED)

    @sync.sync_project(@project.id)

    patch = @client.patched.first
    assert_equal 'guid-project', patch[:guid]
    assert_equal '[Project] Renamed', patch[:task][:summary]
    assert_includes patch[:fields], 'completed_at'
    assert_not_equal '0', patch[:task][:completed_at]
    assert FeishuProjectMapping.find_by(:project_id => @project.id).task_completed?
  end

  def test_sync_project_members_are_assignees
    enable_sync!
    Setting.feishu_default_open_id = 'ou_cc, ou_jsmith'
    Setting.feishu_tasklist_guid = 'shared-list'
    @client.instance_variable_get(:@tasklists)['shared-list'] = {:name => 'Redmine'}
    FeishuUserMapping.create!(:user_id => 3, :open_id => 'ou_dlopper')
    map_project!(@project, 'guid-project', :member_open_ids => 'assignee:ou_gone,follower:ou_cc')

    @sync.sync_project(@project.id)

    assert_equal ['assignee:ou_gone'], roles(@client.removed_members.first[:members])
    assert_equal ['assignee:ou_jsmith', 'assignee:ou_dlopper'],
                 roles(@client.added_members.first[:members])
    assert_equal 'assignee:ou_jsmith,assignee:ou_dlopper,follower:ou_cc',
                 FeishuProjectMapping.find_by(:project_id => @project.id).member_open_ids
    assert_includes @client.added_tasklists, {:guid => 'guid-project', :tasklist_guid => 'shared-list'}
  end

  def test_sync_project_destroy_deletes_task_but_keeps_shared_tasklist
    Setting.feishu_tasklist_guid = 'shared-list'
    map_project!(@project, 'guid-del')

    @sync.sync_project_destroy(@project.id, 'guid-del')

    assert_equal ['guid-del'], @client.deleted
    assert_empty @client.deleted_tasklists
    assert_nil FeishuProjectMapping.find_by(:project_id => @project.id)
  end

  def test_sync_project_reopen_clears_completion
    enable_sync!
    map_project!(@project, 'guid-project', :task_completed => true)

    @sync.sync_project(@project.id)

    assert_equal '0', @client.patched.first[:task][:completed_at]
  end

  def test_subproject_task_is_subtask_of_parent_project_task
    enable_sync!
    subproject = Project.find(3)
    enable_sync!(subproject)
    issue = Issue.generate!(:project => subproject)

    @sync.sync(issue.id)

    assert_equal 1, @client.created.size
    assert_equal ['project-guid-1', 'task-guid-1'], @client.subtasks.pluck(:parent)
    assert_equal '[Project] eCookbook Subproject 1', @client.subtasks.first[:summary]
    mapping = FeishuProjectMapping.find_by(:project_id => 3)
    assert_equal 'task-guid-1', mapping.task_guid
    assert_equal 'project-guid-1', mapping.parent_task_guid
    assert_equal 'task-guid-1', FeishuTaskMapping.find_by(:issue_id => issue.id).parent_task_guid
  end

  def test_subproject_skips_disabled_ancestor
    enable_sync!
    project6 = Project.find(6)
    enable_sync!(project6)
    issue = Issue.generate!(:project => project6)

    @sync.sync(issue.id)

    assert_not FeishuProjectMapping.exists?(:project_id => 5)
    assert_equal 'project-guid-1', FeishuProjectMapping.find_by(:project_id => 6).parent_task_guid
  end

  def test_subproject_is_top_level_when_parent_not_synced
    subproject = Project.find(3)
    enable_sync!(subproject)
    issue = Issue.generate!(:project => subproject)

    @sync.sync(issue.id)

    assert_equal ['[Project] eCookbook Subproject 1'], @client.created.pluck(:summary)
    assert_nil FeishuProjectMapping.find_by(:project_id => 3).parent_task_guid
  end

  def test_sync_project_moves_subtree_when_parent_changes
    enable_sync!
    subproject = Project.find(3)
    enable_sync!(subproject)
    map_project!(@project, 'guid-p1')
    map_project!(subproject, 'guid-p3')
    issue = Issue.generate!(:project => subproject)
    map_issue!(issue, 'guid-i', :parent => 'guid-p3')

    @sync.sync_project(subproject.id)

    assert_equal ['guid-i', 'guid-p3'], @client.deleted.sort
    assert_equal ['guid-p1', 'task-guid-1'], @client.subtasks.pluck(:parent)
    assert_equal 'guid-p1', FeishuProjectMapping.find_by(:project_id => 3).parent_task_guid
    assert_equal 'task-guid-1', FeishuTaskMapping.find_by(:issue_id => issue.id).parent_task_guid
    assert_empty @client.patched
  end

  def test_sync_project_destroy_deletes_remote_task
    map_project!(@project, 'guid-project')

    @sync.sync_project_destroy(@project.id, 'guid-project')

    assert_equal ['guid-project'], @client.deleted
    assert_nil FeishuProjectMapping.find_by(:project_id => @project.id)
  end

  def test_should_enqueue_when_enabled
    issue = Issue.find(1)
    assert_not Redmine::Feishu::TaskSync.should_enqueue?(issue)
    enable_sync!
    issue.reload
    assert Redmine::Feishu::TaskSync.should_enqueue?(issue)
  end
end
