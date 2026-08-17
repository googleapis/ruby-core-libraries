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

##
# Tests for ResumableUpload Driver retry behavior during session start and queries.
#
# rubocop:disable Metrics/MethodLength
class DriverRetryTest < Minitest::Test
  include Gapic::Rest::ResumableUpload

  FakeResponse = Struct.new :status, :headers, :body, keyword_init: true

  # Fake client stub recording calls and yielding scripted responses.
  class FakeClientStub
    attr_reader :requests

    def initialize responses
      @responses = responses
      @requests = []
    end

    def make_post_request uri:, body:, params:, options:, method_name: nil
      @requests << { uri: uri, body: body, params: params, options: options, method_name: method_name }
      raise "Unexpected request: no scripted response left" if @responses.empty?

      @responses.shift
    end
  end

  def test_start_retries_when_response_lacks_status_header_even_on_200
    responses = [
      FakeResponse.new(status: 200, headers: {}, body: ""),
      FakeResponse.new(
        status:  200,
        headers: {
          "X-Goog-Upload-URL"    => "https://example.com/session/1",
          "X-Goog-Upload-Status" => "active"
        },
        body:    ""
      ),
      FakeResponse.new(status: 200, headers: { "X-Goog-Upload-Status" => "final" }, body: '{"done":true}')
    ]
    stub = FakeClientStub.new responses
    config = StartUploadConfig.new(
      initial_url:        "https://example.com/upload",
      stream:             StringIO.new("0123"),
      upload_size:        4,
      chunk_size:         10,
      start_retry_policy: { initial_delay: 0.001, max_delay: 0.002, timeout: 1.0 }
    )

    driver = Driver.new client_stub: stub, config: config
    result = driver.run

    assert_equal '{"done":true}', result
    assert_equal 3, stub.requests.size
    assert_start_request stub.requests[0]
    assert_start_request stub.requests[1]
    assert_chunk_request stub.requests[2], offset: "0", length: "4", body: "0123", finalize: true
  end

  def test_start_exhausts_retries_when_200_responses_continually_lack_status_header
    responses = Array.new(10) { FakeResponse.new status: 200, headers: {}, body: "" }
    stub = FakeClientStub.new responses
    config = StartUploadConfig.new(
      initial_url:        "https://example.com/upload",
      stream:             StringIO.new("0123"),
      upload_size:        4,
      chunk_size:         10,
      start_retry_policy: { initial_delay: 0.001, max_delay: 0.002, timeout: 0.01 }
    )

    driver = Driver.new client_stub: stub, config: config
    err = assert_raises RequestFailedError do
      driver.run
    end

    assert_match(/Missing X-Goog-Upload-Status/, err.message)
    assert_equal 200, err.status_code
    assert_instance_of BadResponseError, err.cause
    assert stub.requests.size > 1
  end

  def test_start_exhausts_retries_when_non_200_responses_continually_lack_status_header
    responses = Array.new(10) { FakeResponse.new status: 503, headers: {}, body: "Service Unavailable" }
    stub = FakeClientStub.new responses
    config = StartUploadConfig.new(
      initial_url:        "https://example.com/upload",
      stream:             StringIO.new("0123"),
      upload_size:        4,
      chunk_size:         10,
      start_retry_policy: { initial_delay: 0.001, max_delay: 0.002, timeout: 0.01 }
    )

    driver = Driver.new client_stub: stub, config: config
    err = assert_raises BadResponseError do
      driver.run
    end

    assert_equal 503, err.status_code
    assert_includes err.message, "503"
    refute_match(/Missing X-Goog-Upload-Status/, err.message)
    assert stub.requests.size > 1
  end

  def test_query_does_not_retry_on_missing_status_header_in_driver
    responses = [
      FakeResponse.new(
        status:  200,
        headers: {
          "X-Goog-Upload-URL"    => "https://example.com/session/1",
          "X-Goog-Upload-Status" => "active"
        },
        body:    ""
      ),
      FakeResponse.new(status: 503, headers: {}, body: "Service Unavailable"),
      FakeResponse.new(status: 200, headers: {}, body: ""),
      FakeResponse.new(
        status:  200,
        headers: {
          "X-Goog-Upload-Status"        => "active",
          "X-Goog-Upload-Size-Received" => "0"
        },
        body:    ""
      ),
      FakeResponse.new(status: 200, headers: { "X-Goog-Upload-Status" => "final" }, body: '{"done":true}')
    ]
    stub = FakeClientStub.new responses
    config = StartUploadConfig.new(
      initial_url: "https://example.com/upload",
      stream:      StringIO.new("0123"),
      upload_size: 4,
      chunk_size:  10
    )

    driver = Driver.new client_stub: stub, config: config
    result = driver.run

    assert_equal '{"done":true}', result
    assert_equal 5, stub.requests.size
    assert_start_request stub.requests[0]
    assert_chunk_request stub.requests[1], offset: "0", length: "4", body: "0123", finalize: true
    assert_query_request stub.requests[2]
    assert_query_request stub.requests[3]
    assert_chunk_request stub.requests[4], offset: "0", length: "4", body: "0123", finalize: true
  end

  private

  def assert_start_request req
    assert_equal "https://example.com/upload", req[:uri]
    assert_equal "start", req[:options][:metadata]["X-Goog-Upload-Command"]
  end

  def assert_query_request req
    assert_equal "https://example.com/session/1", req[:uri]
    assert_equal "query", req[:options][:metadata]["X-Goog-Upload-Command"]
  end

  def assert_chunk_request req, offset:, length:, body:, finalize:
    expected_cmd = finalize ? "upload, finalize" : "upload"
    metadata = req[:options][:metadata]
    assert_equal "https://example.com/session/1", req[:uri]
    assert_equal expected_cmd, metadata["X-Goog-Upload-Command"]
    assert_equal offset, metadata["X-Goog-Upload-Offset"]
    assert_equal length, metadata["Content-Length"]
    assert_equal body, req[:body]
  end
end
# rubocop:enable Metrics/MethodLength
