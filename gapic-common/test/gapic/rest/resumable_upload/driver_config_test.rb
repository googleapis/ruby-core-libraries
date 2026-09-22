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
# Tests for ResumableUpload Driver configuration and deadline resolution.
#
class DriverConfigTest < Minitest::Test
  include Gapic::Rest::ResumableUpload

  # Fake client stub recording calls and yielding scripted responses.
  class FakeClientStub
    attr_reader :requests

    def initialize responses = [], on_request: nil
      @responses = responses
      @requests = []
      @on_request = on_request
    end

    def make_post_request uri:, body:, params:, options:, method_name: nil
      @requests << { uri: uri, body: body, params: params, options: options, method_name: method_name }
      @on_request&.call
      raise "Unexpected request: no scripted response left" if @responses.empty?

      resp = @responses.shift
      raise resp if resp.is_a? Exception

      resp.respond_to?(:call) ? resp.call : resp
    end
  end

  FakeResponse = Data.define :status, :headers, :body

  def test_resolve_timeout
    stub = FakeClientStub.new
    resolve_for = lambda do |**opts|
      config = StartUploadConfig.new initial_url: "https://example.com/upload", stream: StringIO.new("0123"), **opts
      Driver.new(client_stub: stub, config: config).send :resolve_timeout
    end

    # Explicit positive timeout takes precedence over upload_size
    assert_equal 42, resolve_for.call(upload_size: 10 * 1_048_576, timeout: 42)

    # Zero and negative timeouts are treated as unset (nil)
    assert_equal Driver::BASE_TIMEOUT, resolve_for.call(timeout: 0)
    assert_equal Driver::BASE_TIMEOUT, resolve_for.call(timeout: -10)

    # Proportional to upload_size above BASE_TIMEOUT, floored at BASE_TIMEOUT for small or nil upload_size
    assert_in_delta 7_200.0, resolve_for.call(upload_size: 7_200 * Driver::MIN_ASSUMED_THROUGHPUT), 0.001
    assert_equal Driver::BASE_TIMEOUT, resolve_for.call(upload_size: 1_048_576)
    assert_equal Driver::BASE_TIMEOUT, resolve_for.call
  end

  def test_run_raises_deadline_exceeded_when_timeout_expires
    stub = FakeClientStub.new
    config = StartUploadConfig.new(
      initial_url: "https://example.com/upload",
      stream:      StringIO.new("0123"),
      upload_size: 4,
      chunk_size:  10,
      timeout:     5
    )
    driver = Driver.new client_stub: stub, config: config

    # Stub monotonic clock so that initial check sets deadline at t=105, and subsequent checks read t=110
    clock_ticks = [100.0, 110.0, 110.0]
    Process.stub :clock_gettime, ->(_clock_id) { clock_ticks.shift || 110.0 } do
      assert_raises DeadlineExceededError do
        driver.run
      end
    end
    assert_empty stub.requests
  end

  def test_run_raises_deadline_exceeded_when_clock_advances_past_deadline_mid_batch
    current_time = 100.0
    responses = [
      FakeResponse.new(
        status:  200,
        headers: { "X-Goog-Upload-Status" => "active", "X-Goog-Upload-URL" => "https://example.com/session" },
        body:    ""
      )
    ]
    stub = FakeClientStub.new responses
    # Advance clock past deadline (105.0) mid-batch during NotifyProgress(:finalizing) before SendChunk
    on_progress = lambda do |progress|
      current_time = 110.0 if progress.phase == :finalizing
    end
    config = StartUploadConfig.new(
      initial_url: "https://example.com/upload",
      stream:      StringIO.new("0123"),
      upload_size: 4,
      chunk_size:  10,
      timeout:     5,
      on_progress: on_progress
    )
    driver = Driver.new client_stub: stub, config: config

    Process.stub :clock_gettime, ->(_clock_id) { current_time } do
      assert_raises DeadlineExceededError do
        driver.run
      end
    end

    # Only the start request was made; SendChunk hit deadline_exceeded? inside make_post_request
    assert_equal 1, stub.requests.size
  end

  def test_make_post_request_passes_timeout_close_to_remaining_budget_and_decreases_across_calls
    current_time = 1000.0
    stub = FakeClientStub.new(scripted_recovery_responses, on_request: -> { current_time += 10.0 })
    config = StartUploadConfig.new(
      initial_url:             "https://example.com/upload",
      stream:                  StringIO.new("0123"),
      upload_size:             4,
      chunk_size:              10,
      timeout:                 100.0,
      data_plane_retry_policy: Gapic::Common::RetryPolicy.new(timeout: 85.0)
    )
    driver = Driver.new client_stub: stub, config: config

    Process.stub :clock_gettime, ->(_clock_id) { current_time } do
      assert_equal "done", driver.run
    end

    timeouts = stub.requests.map { |req| req[:options][:timeout] }
    assert_equal [100.0, 85.0, 80.0, 70.0], timeouts
    timeouts.each_cons 2 do |prev_timeout, next_timeout|
      assert_operator prev_timeout, :>, next_timeout
    end
  end

  def test_start_headers_without_caller_headers_is_unchanged
    config = StartUploadConfig.new initial_url: "https://example.com/upload", stream: StringIO.new("0123")
    driver = Driver.new client_stub: FakeClientStub.new, config: config
    instruction = Instruction::SendStart.new url: "https://example.com/upload"

    headers = driver.send :start_headers, instruction

    assert_equal({ "X-Goog-Upload-Protocol" => "resumable", "X-Goog-Upload-Command" => "start" }, headers)
  end

  def test_start_headers_merges_caller_pass_through_upload_header
    caller_headers = {
      "X-Goog-Upload-Header-Content-Disposition" => 'attachment; filename="movie.mp4"',
      "X-Custom"                                 => "value"
    }
    config = StartUploadConfig.new(
      initial_url:     "https://example.com/upload",
      stream:          StringIO.new("content"),
      initial_headers: caller_headers,
      content_type:    "video/mp4",
      upload_size:     7
    )
    driver = Driver.new client_stub: FakeClientStub.new, config: config
    instruction = Instruction::SendStart.new url: "https://example.com/upload", headers: caller_headers

    headers = driver.send :start_headers, instruction

    assert_equal 'attachment; filename="movie.mp4"', headers["X-Goog-Upload-Header-Content-Disposition"]
    assert_equal "value", headers["X-Custom"]
    assert_equal "resumable", headers["X-Goog-Upload-Protocol"]
    assert_equal "start", headers["X-Goog-Upload-Command"]
    assert_equal "video/mp4", headers["X-Goog-Upload-Header-Content-Type"]
    assert_equal "7", headers["X-Goog-Upload-Header-Content-Length"]
  end

  private

  def scripted_recovery_responses
    [
      FakeResponse.new(
        status:  200,
        headers: { "X-Goog-Upload-Status" => "active", "X-Goog-Upload-URL" => "https://example.com/session" },
        body:    ""
      ),
      Gapic::Rest::Error.new(
        "Service Unavailable",
        503,
        headers: { "X-Goog-Upload-Status" => "active" }
      ),
      FakeResponse.new(
        status:  200,
        headers: { "X-Goog-Upload-Status" => "active", "X-Goog-Upload-Size-Received" => "0" },
        body:    ""
      ),
      FakeResponse.new(
        status:  200,
        headers: { "X-Goog-Upload-Status" => "final" },
        body:    "done"
      )
    ]
  end
end
