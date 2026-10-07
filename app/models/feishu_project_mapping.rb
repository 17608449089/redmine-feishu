# frozen_string_literal: true

# Redmine - project management software
# Copyright (C) 2006-  Jean-Philippe Lang

class FeishuProjectMapping < ApplicationRecord
  belongs_to :project

  validates :project_id, :uniqueness => true
  validates :task_guid, :presence => true
end
