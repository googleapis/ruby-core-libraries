# frozen_string_literal: true

# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require "test_helper"
require "gapic/rest/resumable_upload"
require "stringio"
require "faraday"

##
# Tests for Driver network error mapping to protocol events.
#
class DriverErrorMappingTest < Minitest::Test
  include Gapic::Rest::ResumableUpload

  ##
  # Integration fake client stub that raises configured errors on make_post_request.
  #
  class FailingClientStub
    attr_accessor :error_to_raise

    def make_post_request uri:, body: nil, params: {}, options: {}, method_name: nil
      raise @error_to_raise if @error_to_raise

      raise "No error configured"
    end
  end

  def setup
    @client_stub = FailingClientStub.new
    @config = StartUploadConfig.new(
      initial_url: "https://example.com/upload",
      stream:      StringIO.new("0123456789"),
      upload_size: 10,
      chunk_size:  4
    )
    @driver = Driver.new client_stub: @client_stub, config: @config
  end

  # ============================================================================
  # SUT: rescue_request_error
  # ============================================================================

  def test_rescue_request_error_rest_deadline_exceeded
    err = Gapic::Rest::DeadlineExceededError.new "RPC deadline exceeded", 504
    event = @driver.send :rescue_request_error, err

    assert_instance_of Event::RequestFailed, event
    assert_equal :timeout, event.kind
    assert_equal "RPC deadline exceeded", event.message
    assert_same err, event.source_error

    # End-to-end via make_post_request
    @client_stub.error_to_raise = err
    integration_event = @driver.send :make_post_request, "https://example.com", headers: {}, body: "",
                                                                                retry_policy: nil
    assert_instance_of Event::RequestFailed, integration_event
    assert_equal :timeout, integration_event.kind
    assert_same err, integration_event.source_error
  end

  def test_rescue_request_error_rest_error_with_status_code
    err = Gapic::Rest::Error.new "Service Unavailable", 503, headers: { "Retry-After" => "15" }
    event = @driver.send :rescue_request_error, err

    assert_instance_of Event::HttpResponse, event
    assert_equal 503, event.status
    assert_equal({ "Retry-After" => "15" }, event.headers)
    assert_equal "Service Unavailable", event.body

    # End-to-end via make_post_request
    @client_stub.error_to_raise = err
    integration_event = @driver.send :make_post_request, "https://example.com", headers: {}, body: "",
                                                                                retry_policy: nil
    assert_instance_of Event::HttpResponse, integration_event
    assert_equal 503, integration_event.status
    assert_equal({ "Retry-After" => "15" }, integration_event.headers)
    assert_equal "Service Unavailable", integration_event.body
  end

  def test_rescue_request_error_rest_error_without_status_code
    err = Gapic::Rest::Error.new "Client network error", nil
    event = @driver.send :rescue_request_error, err

    assert_instance_of Event::RequestFailed, event
    assert_equal :connection_failed, event.kind
    assert_equal "Client network error", event.message
    assert_same err, event.source_error

    # End-to-end via make_post_request
    @client_stub.error_to_raise = err
    integration_event = @driver.send :make_post_request, "https://example.com", headers: {}, body: "",
                                                                                retry_policy: nil
    assert_instance_of Event::RequestFailed, integration_event
    assert_equal :connection_failed, integration_event.kind
    assert_same err, integration_event.source_error
  end

  def test_rescue_request_error_standard_error
    err = RuntimeError.new "Unexpected low-level runtime error"
    event = @driver.send :rescue_request_error, err

    assert_instance_of Event::RequestFailed, event
    assert_equal :connection_failed, event.kind
    assert_equal "Unexpected low-level runtime error", event.message
    assert_same err, event.source_error

    # End-to-end via make_post_request
    @client_stub.error_to_raise = err
    integration_event = @driver.send :make_post_request, "https://example.com", headers: {}, body: "",
                                                                                retry_policy: nil
    assert_instance_of Event::RequestFailed, integration_event
    assert_equal :connection_failed, integration_event.kind
    assert_same err, integration_event.source_error
  end

  # ============================================================================
  # SUT: rescue_faraday_error
  # ============================================================================

  def test_rescue_faraday_error_with_response
    response_env = {
      status:  400,
      headers: { "x-goog-upload-status" => "final" },
      body:    '{"error":{"message":"Bad Request"}}'
    }
    err = Faraday::ClientError.new "the server responded with status 400", response_env
    event = @driver.send :rescue_faraday_error, err

    assert_instance_of Event::HttpResponse, event
    assert_equal 400, event.status
    assert_equal({ "x-goog-upload-status" => "final" }, event.headers)
    assert_equal '{"error":{"message":"Bad Request"}}', event.body

    # End-to-end via make_post_request
    @client_stub.error_to_raise = err
    integration_event = @driver.send :make_post_request, "https://example.com", headers: {}, body: "",
                                                                                retry_policy: nil
    assert_instance_of Event::HttpResponse, integration_event
    assert_equal 400, integration_event.status
    assert_equal '{"error":{"message":"Bad Request"}}', integration_event.body
  end

  def test_rescue_faraday_error_timeout
    err = Faraday::TimeoutError.new "Net::ReadTimeout with https://example.com"
    event = @driver.send :rescue_faraday_error, err

    assert_instance_of Event::RequestFailed, event
    assert_equal :timeout, event.kind
    assert_equal "Net::ReadTimeout with https://example.com", event.message
    assert_same err, event.source_error

    # End-to-end via make_post_request
    @client_stub.error_to_raise = err
    integration_event = @driver.send :make_post_request, "https://example.com", headers: {}, body: "",
                                                                                retry_policy: nil
    assert_instance_of Event::RequestFailed, integration_event
    assert_equal :timeout, integration_event.kind
    assert_same err, integration_event.source_error
  end

  def test_rescue_faraday_error_connection_failed
    err = Faraday::ConnectionFailed.new "Connection refused - connect(2)"
    event = @driver.send :rescue_faraday_error, err

    assert_instance_of Event::RequestFailed, event
    assert_equal :connection_failed, event.kind
    assert_equal "Connection refused - connect(2)", event.message
    assert_same err, event.source_error

    # End-to-end via make_post_request
    @client_stub.error_to_raise = err
    integration_event = @driver.send :make_post_request, "https://example.com", headers: {}, body: "",
                                                                                retry_policy: nil
    assert_instance_of Event::RequestFailed, integration_event
    assert_equal :connection_failed, integration_event.kind
    assert_same err, integration_event.source_error
  end

  def test_rescue_faraday_error_generic_without_response
    err = Faraday::Error.new "Generic transport error without response env"
    event = @driver.send :rescue_faraday_error, err

    assert_instance_of Event::RequestFailed, event
    assert_equal :retries_exhausted, event.kind
    assert_equal "Generic transport error without response env", event.message
    assert_same err, event.source_error

    # End-to-end via make_post_request
    @client_stub.error_to_raise = err
    integration_event = @driver.send :make_post_request, "https://example.com", headers: {}, body: "",
                                                                                retry_policy: nil
    assert_instance_of Event::RequestFailed, integration_event
    assert_equal :retries_exhausted, integration_event.kind
    assert_same err, integration_event.source_error
  end
end
