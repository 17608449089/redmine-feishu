class WidenFeishuAssigneeOpenId < ActiveRecord::Migration[8.1]
  def up
    return unless table_exists?(:feishu_task_mappings)

    change_column :feishu_task_mappings, :assignee_open_id, :string, :limit => 1000
  end

  def down
    return unless table_exists?(:feishu_task_mappings)

    change_column :feishu_task_mappings, :assignee_open_id, :string, :limit => 100
  end
end
