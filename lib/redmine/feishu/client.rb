# frozen_string_literal: true

# Redmine - project management software
# Copyright (C) 2006-  Jean-Philippe Lang

require 'json'
require 'net/http'
require 'uri'

module Redmine
  module Feishu
    class Client
      TOKEN_SKEW = 60
      HTTP_TIMEOUT = 15
      HTTP_OPEN_TIMEOUT = 10
      MAX_ATTEMPTS = 3
      RETRIABLE_ERRORS = [
        Net::OpenTimeout, Net::ReadTimeout, SocketError, EOFError,
        Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::EHOSTUNREACH, Errno::ETIMEDOUT
      ].freeze

      class << self
        def reset_token!
          @token = nil
          @token_expires_at = Time.at(0)
        end

        def token_mutex
          @token_mutex ||= Mutex.new
        end

        attr_accessor :token, :token_expires_at
      end

      def initialize
        self.class.token_expires_at ||= Time.at(0)
      end

      def create_task(payload)
        data = request(:post, '/open-apis/task/v2/tasks', payload: payload, query: {user_id_type: 'open_id'})
        data['task'] || data
      end

      def create_subtask(parent_guid, payload)
        data = request(
          :post,
          "/open-apis/task/v2/tasks/#{parent_guid}/subtasks",
          payload: payload,
          query: {user_id_type: 'open_id'}
        )
        data['subtask'] || data
      end

      def patch_task(task_guid, task, update_fields)
        data = request(
          :patch,
          "/open-apis/task/v2/tasks/#{task_guid}",
          payload: {task: task, update_fields: update_fields},
          query: {user_id_type: 'open_id'}
        )
        data['task'] || data
      end

      def delete_task(task_guid)
        request(:delete, "/open-apis/task/v2/tasks/#{task_guid}")
      end

      def add_members(task_guid, members)
        request(
          :post,
          "/open-apis/task/v2/tasks/#{task_guid}/add_members",
          payload: {members: members},
          query: {user_id_type: 'open_id'}
        )
      end

      def remove_members(task_guid, members)
        request(
          :post,
          "/open-apis/task/v2/tasks/#{task_guid}/remove_members",
          payload: {members: members},
          query: {user_id_type: 'open_id'}
        )
      end

      # Idempotent: already-in-list returns success. section_guid places the task
      # into a custom section of that tasklist.
      def add_tasklist(task_guid, tasklist_guid, section_guid: nil)
        payload = {tasklist_guid: tasklist_guid}
        payload[:section_guid] = section_guid if section_guid.present?
        request(
          :post,
          "/open-apis/task/v2/tasks/#{task_guid}/add_tasklist",
          payload: payload
        )
      end

      def create_section(payload)
        data = request(
          :post,
          '/open-apis/task/v2/sections',
          payload: payload,
          query: {user_id_type: 'open_id'}
        )
        data['section'] || data
      end

      def get_section(section_guid)
        data = request(
          :get,
          "/open-apis/task/v2/sections/#{section_guid}",
          query: {user_id_type: 'open_id'}
        )
        data['section'] || data
      end

      def patch_section(section_guid, section, update_fields)
        data = request(
          :patch,
          "/open-apis/task/v2/sections/#{section_guid}",
          payload: {section: section, update_fields: update_fields},
          query: {user_id_type: 'open_id'}
        )
        data['section'] || data
      end

      def delete_section(section_guid)
        request(:delete, "/open-apis/task/v2/sections/#{section_guid}")
      end

      def create_tasklist(payload)
        data = request(
          :post,
          '/open-apis/task/v2/tasklists',
          payload: payload,
          query: {user_id_type: 'open_id'}
        )
        data['tasklist'] || data
      end

      def get_tasklist(tasklist_guid)
        data = request(
          :get,
          "/open-apis/task/v2/tasklists/#{tasklist_guid}",
          query: {user_id_type: 'open_id'}
        )
        data['tasklist'] || data
      end

      def patch_tasklist(tasklist_guid, tasklist, update_fields)
        data = request(
          :patch,
          "/open-apis/task/v2/tasklists/#{tasklist_guid}",
          payload: {tasklist: tasklist, update_fields: update_fields},
          query: {user_id_type: 'open_id'}
        )
        data['tasklist'] || data
      end

      def delete_tasklist(tasklist_guid)
        request(:delete, "/open-apis/task/v2/tasklists/#{tasklist_guid}")
      end

      def add_tasklist_members(tasklist_guid, members)
        request(
          :post,
          "/open-apis/task/v2/tasklists/#{tasklist_guid}/add_members",
          payload: {members: members},
          query: {user_id_type: 'open_id'}
        )
      end

      def remove_tasklist_members(tasklist_guid, members)
        request(
          :post,
          "/open-apis/task/v2/tasklists/#{tasklist_guid}/remove_members",
          payload: {members: members},
          query: {user_id_type: 'open_id'}
        )
      end

      def open_id_for_email(email)
        return if email.blank?

        data = request(
          :post,
          '/open-apis/contact/v3/users/batch_get_id',
          payload: {emails: [email]},
          query: {user_id_type: 'open_id'}
        )
        list = data['user_list'] || []
        entry = list.find {|u| u['email'].to_s.casecmp?(email.to_s) && u['user_id'].present?}
        entry ||= list.find {|u| u['user_id'].present?}
        entry && entry['user_id']
      end

      def tenant_access_token
        self.class.token_mutex.synchronize do
          if self.class.token.present? && Time.now < self.class.token_expires_at
            return self.class.token
          end

          body = request(
            :post,
            '/open-apis/auth/v3/tenant_access_token/internal',
            payload: {app_id: app_id, app_secret: app_secret},
            authenticate: false
          )
          token = body['tenant_access_token'].to_s
          raise Error, 'empty tenant_access_token' if token.blank?

          expire = body['expire'].to_i
          expire = 7200 if expire <= 0
          self.class.token = token
          self.class.token_expires_at = Time.now + expire - TOKEN_SKEW
          token
        end
      end

      private

      def app_id
        value = config_value('app_id', Setting.feishu_app_id)
        raise Error, 'Feishu app_id is blank' if value.blank?

        value
      end

      def app_secret
        value = config_value('app_secret', Setting.feishu_app_secret)
        raise Error, 'Feishu app_secret is blank' if value.blank?

        value
      end

      def api_base
        config_value('api_base', Setting.feishu_api_base).presence || 'https://open.feishu.cn'
      end

      def config_value(key, fallback)
        conf = Redmine::Configuration['feishu']
        if conf.is_a?(Hash)
          conf[key].presence || conf[key.to_sym].presence || fallback
        else
          fallback
        end
      end

      def request(method, path, payload: nil, query: {}, authenticate: true)
        uri = uri_for(path, query)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = (uri.scheme == 'https')
        http.open_timeout = HTTP_OPEN_TIMEOUT
        http.read_timeout = HTTP_TIMEOUT

        klass = request_class(method)
        req = klass.new(uri.request_uri)
        req['Content-Type'] = 'application/json; charset=utf-8'
        req['Authorization'] = "Bearer #{tenant_access_token}" if authenticate
        req.body = JSON.generate(payload) if payload

        response = with_retries(method, path) {http.request(req)}
        parse_response(response)
      rescue Error
        raise
      rescue StandardError => e
        raise Error, "#{method.upcase} #{path} failed: #{e.class}: #{e.message}"
      end

      # Task creation uses client_token, and patch/member calls are idempotent,
      # so transient network failures are safe to retry.
      def with_retries(method, path)
        attempt = 0
        begin
          attempt += 1
          yield
        rescue *RETRIABLE_ERRORS => e
          raise if attempt >= MAX_ATTEMPTS

          Rails.logger.warn do
            "Feishu #{method.upcase} #{path} attempt #{attempt} failed: #{e.class}, retrying"
          end
          sleep(retry_delay(attempt))
          retry
        end
      end

      def retry_delay(attempt)
        attempt
      end

      def request_class(method)
        case method
        when :get then Net::HTTP::Get
        when :post then Net::HTTP::Post
        when :patch then Net::HTTP::Patch
        when :delete then Net::HTTP::Delete
        else
          raise ArgumentError, "unsupported HTTP method #{method}"
        end
      end

      def uri_for(path, query)
        base = api_base.to_s.chomp('/')
        path = "/#{path}" unless path.start_with?('/')
        uri = URI.parse("#{base}#{path}")
        uri.query = URI.encode_www_form(query) if query.present?
        uri
      end

      def parse_response(response)
        body = response.body.to_s
        json = body.present? ? JSON.parse(body) : {}
        unless json.is_a?(Hash)
          raise Error, "unexpected Feishu response (HTTP #{response.code})"
        end

        code = json['code']
        if code && code != 0
          raise Error.new("Feishu API error #{code}: #{json['msg']}", code: code)
        end
        unless response.is_a?(Net::HTTPSuccess)
          raise Error, "Feishu HTTP #{response.code}: #{json['msg'] || body.truncate(200)}"
        end

        json['data'] || json
      rescue JSON::ParserError
        raise Error, "Feishu HTTP #{response.code}: invalid JSON"
      end
    end
  end
end
