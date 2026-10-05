# frozen_string_literal: true

# Redmine - project management software
# Copyright (C) 2006-  Jean-Philippe Lang

class FeishuTaskMapping < ApplicationRecord
  belongs_to :issue

  validates :issue_id, :presence => true, :uniqueness => true
  validates :task_guid, :presence => true
end
