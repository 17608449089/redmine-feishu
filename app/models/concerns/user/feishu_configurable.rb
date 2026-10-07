# frozen_string_literal: true

# Redmine - project management software
# Copyright (C) 2006-  Jean-Philippe Lang

module User::FeishuConfigurable
  extend ActiveSupport::Concern

  included do
    has_one :feishu_user_mapping, :dependent => :delete
    safe_attributes 'feishu_open_id', :if => lambda {|user, current_user| current_user.admin?}
    after_save :save_feishu_open_id
  end

  def feishu_open_id
    @feishu_open_id.nil? ? feishu_user_mapping&.open_id : @feishu_open_id
  end

  def feishu_open_id=(value)
    @feishu_open_id = value.to_s.strip
  end

  private

  def save_feishu_open_id
    return if @feishu_open_id.nil?

    value = @feishu_open_id
    @feishu_open_id = nil
    if value.blank?
      FeishuUserMapping.where(:user_id => id).delete_all
    else
      FeishuUserMapping.find_or_initialize_by(:user_id => id).update!(:open_id => value)
    end
    association(:feishu_user_mapping).reset
  end
end
