# frozen_string_literal: true

# Redmine - project management software
# Copyright (C) 2006-  Jean-Philippe Lang

module Redmine
  module Feishu
    class Error < StandardError
      NOT_FOUND = 1470404

      attr_reader :code

      def initialize(message = nil, code: nil)
        super(message)
        @code = code
      end

      def not_found?
        code.to_i == NOT_FOUND
      end
    end
  end
end
