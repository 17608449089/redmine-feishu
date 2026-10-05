# frozen_string_literal: true

# Redmine - project management software
# Copyright (C) 2006-  Jean-Philippe Lang

class FeishuUserMapping < ApplicationRecord
  belongs_to :user

  validates :user_id, :presence => true, :uniqueness => true
  validates :open_id, :presence => true
end
