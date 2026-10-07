# frozen_string_literal: true

# Redmine - project management software
# Copyright (C) 2006-  Jean-Philippe Lang

require_relative '../../../../test_helper'

class Redmine::Feishu::ClientTest < ActiveSupport::TestCase
  def setup
    @client = Redmine::Feishu::Client.new
    @client.stubs(:tenant_access_token).returns('token')
    @client.stubs(:retry_delay).returns(0)
  end

  def success_response
    response = Net::HTTPOK.new('1.1', '200', 'OK')
    response.stubs(:body).returns('{"code":0,"data":{}}')
    response
  end

  def test_retries_transient_network_errors
    Net::HTTP.any_instance.stubs(:request).raises(Net::OpenTimeout).then.returns(success_response)

    assert_nothing_raised {@client.add_members('guid', [])}
  end

  def test_gives_up_after_max_attempts
    Net::HTTP.any_instance.expects(:request).times(Redmine::Feishu::Client::MAX_ATTEMPTS).raises(Net::OpenTimeout)

    error = assert_raises(Redmine::Feishu::Error) {@client.add_members('guid', [])}
    assert_includes error.message, 'Net::OpenTimeout'
  end

  def test_does_not_retry_api_errors
    response = Net::HTTPOK.new('1.1', '200', 'OK')
    response.stubs(:body).returns('{"code":1470400,"msg":"bad request"}')
    Net::HTTP.any_instance.expects(:request).once.returns(response)

    assert_raises(Redmine::Feishu::Error) {@client.add_members('guid', [])}
  end
end
