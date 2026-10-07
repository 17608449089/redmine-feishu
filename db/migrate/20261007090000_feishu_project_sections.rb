class FeishuProjectSections < ActiveRecord::Migration[8.1]
  def change
    rename_column :feishu_project_mappings, :task_guid, :section_guid
    remove_column :feishu_project_mappings, :parent_task_guid, :string, :limit => 100
    remove_column :feishu_project_mappings, :member_open_ids, :string, :limit => 1000
    remove_column :feishu_project_mappings, :task_completed, :boolean, :null => false, :default => false
    remove_column :feishu_project_mappings, :tasklist_guid, :string, :limit => 100
    remove_column :feishu_project_mappings, :tasklist_member_open_ids, :string, :limit => 1000
  end
end
