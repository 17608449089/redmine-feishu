class AddFeishuProjectTasks < ActiveRecord::Migration[8.1]
  def change
    add_column :feishu_task_mappings, :parent_task_guid, :string, :limit => 100

    create_table :feishu_project_mappings do |t|
      t.integer :project_id, :null => false
      t.string :task_guid, :null => false, :limit => 100
      t.string :parent_task_guid, :limit => 100
      t.string :member_open_ids, :limit => 1000
      t.boolean :task_completed, :null => false, :default => false
      t.timestamps :null => false
    end
    add_index :feishu_project_mappings, :project_id, :unique => true
  end
end
