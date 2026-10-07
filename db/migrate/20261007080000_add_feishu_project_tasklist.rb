class AddFeishuProjectTasklist < ActiveRecord::Migration[8.1]
  def change
    add_column :feishu_project_mappings, :tasklist_guid, :string, :limit => 100
    add_column :feishu_project_mappings, :tasklist_member_open_ids, :string, :limit => 1000
  end
end
