class CreateFeishuSyncTables < ActiveRecord::Migration[8.1]
  def change
    create_table :feishu_task_mappings do |t|
      t.integer :issue_id, :null => false
      t.string :task_guid, :null => false, :limit => 100
      t.string :assignee_open_id, :limit => 1000
      t.boolean :task_completed, :null => false, :default => false
      t.timestamps :null => false
    end
    add_index :feishu_task_mappings, :issue_id, :unique => true
    add_index :feishu_task_mappings, :task_guid

    create_table :feishu_user_mappings do |t|
      t.integer :user_id, :null => false
      t.string :open_id, :null => false, :limit => 100
      t.timestamps :null => false
    end
    add_index :feishu_user_mappings, :user_id, :unique => true
    add_index :feishu_user_mappings, :open_id
  end
end
