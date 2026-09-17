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
# Tests for ResumableUpload Driver synchronous upload execution engine.
#
class DriverTest < Minitest::Test
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
      @requests << { uri: uri, body: body, params: params, options: options }
      raise "Unexpected request: no scripted response left" if @responses.empty?

      @responses.shift
    end
  end

  def test_multi_chunk_upload_with_active_responses
    progress_records = []
    stub = FakeClientStub.new build_scripted_responses
    config = StartUploadConfig.new(
      initial_url: "https://example.com/upload",
      stream:      StringIO.new("0123456789"),
      upload_size: 10,
      chunk_size:  4,
      on_progress: ->(p) { progress_records << p }
    )

    driver = Driver.new client_stub: stub, config: config
    result = driver.run

    assert_equal '{"done":true}', result
    assert_equal 4, stub.requests.size
    assert_start_request stub.requests[0]
    assert_chunk_request stub.requests[1], offset: "0", length: "4", body: "0123", finalize: false
    assert_chunk_request stub.requests[2], offset: "4", length: "4", body: "4567", finalize: false
    assert_chunk_request stub.requests[3], offset: "8", length: "2", body: "89", finalize: true

    assert_equal [
      Progress.new(phase: :initiating, bytes_uploaded: 0, total_bytes: 10),
      Progress.new(phase: :uploading, bytes_uploaded: 0, total_bytes: 10),
      Progress.new(phase: :uploading, bytes_uploaded: 4, total_bytes: 10),
      Progress.new(phase: :uploading, bytes_uploaded: 8, total_bytes: 10),
      Progress.new(phase: :finalizing, bytes_uploaded: 8, total_bytes: 10),
      Progress.new(phase: :completed, bytes_uploaded: 10, total_bytes: 10)
    ], progress_records
  end

  def test_upload_recovers_when_chunk_response_lacks_status_header
    progress_records = []
    responses = build_recovery_responses
    stub = FakeClientStub.new responses
    config = StartUploadConfig.new(
      initial_url: "https://example.com/upload",
      stream:      StringIO.new("0123456789"),
      upload_size: 10,
      chunk_size:  4,
      on_progress: ->(p) { progress_records << p }
    )

    driver = Driver.new client_stub: stub, config: config
    result = driver.run

    assert_equal '{"done":true}', result
    assert_equal 5, stub.requests.size
    assert_start_request stub.requests[0]
    assert_chunk_request stub.requests[1], offset: "0", length: "4", body: "0123", finalize: false
    assert_query_request stub.requests[2]
    assert_chunk_request stub.requests[3], offset: "4", length: "4", body: "4567", finalize: false
    assert_chunk_request stub.requests[4], offset: "8", length: "2", body: "89", finalize: true

    assert_equal [
      Progress.new(phase: :initiating, bytes_uploaded: 0, total_bytes: 10),
      Progress.new(phase: :uploading, bytes_uploaded: 0, total_bytes: 10),
      Progress.new(phase: :recovering, bytes_uploaded: 0, total_bytes: 10),
      Progress.new(phase: :uploading, bytes_uploaded: 4, total_bytes: 10),
      Progress.new(phase: :uploading, bytes_uploaded: 8, total_bytes: 10),
      Progress.new(phase: :finalizing, bytes_uploaded: 8, total_bytes: 10),
      Progress.new(phase: :completed, bytes_uploaded: 10, total_bytes: 10)
    ], progress_records
  end

  def test_resume_upload_success
    progress_records = []
    responses = [
      FakeResponse.new(
        status:  200,
        headers: {
          "X-Goog-Upload-Status"        => "active",
          "X-Goog-Upload-Size-Received" => "4"
        },
        body:    ""
      ),
      FakeResponse.new(status: 200, headers: { "X-Goog-Upload-Status" => "active" }, body: ""),
      FakeResponse.new(status: 200, headers: { "X-Goog-Upload-Status" => "final" }, body: '{"done":true}')
    ]
    stub = FakeClientStub.new responses
    config = ResumeUploadConfig.new(
      upload_url:  "https://example.com/session/1",
      chunk_size:  4,
      stream:      StringIO.new("0123456789"),
      upload_size: 10,
      on_progress: ->(p) { progress_records << p }
    )

    driver = Driver.new client_stub: stub, config: config
    result = driver.run

    assert_equal '{"done":true}', result
    assert_equal 3, stub.requests.size
    assert_query_request stub.requests[0]
    assert_chunk_request stub.requests[1], offset: "4", length: "4", body: "4567", finalize: false
    assert_chunk_request stub.requests[2], offset: "8", length: "2", body: "89", finalize: true

    assert_equal [
      Progress.new(phase: :initiating, bytes_uploaded: 0, total_bytes: 10),
      Progress.new(phase: :uploading, bytes_uploaded: 4, total_bytes: 10),
      Progress.new(phase: :uploading, bytes_uploaded: 8, total_bytes: 10),
      Progress.new(phase: :finalizing, bytes_uploaded: 8, total_bytes: 10),
      Progress.new(phase: :completed, bytes_uploaded: 10, total_bytes: 10)
    ], progress_records
  end

  def test_resume_upload_with_409_recovery_retry
    progress_records = []
    responses = [
      FakeResponse.new(
        status:  409,
        headers: { "X-Goog-Upload-Status" => "active" },
        body:    "Conflict"
      ),
      FakeResponse.new(
        status:  200,
        headers: {
          "X-Goog-Upload-Status"        => "active",
          "X-Goog-Upload-Size-Received" => "4"
        },
        body:    ""
      ),
      FakeResponse.new(status: 200, headers: { "X-Goog-Upload-Status" => "active" }, body: ""),
      FakeResponse.new(status: 200, headers: { "X-Goog-Upload-Status" => "final" }, body: '{"done":true}')
    ]
    stub = FakeClientStub.new responses
    config = ResumeUploadConfig.new(
      upload_url:  "https://example.com/session/1",
      chunk_size:  4,
      stream:      StringIO.new("0123456789"),
      upload_size: 10,
      on_progress: ->(p) { progress_records << p }
    )

    driver = Driver.new client_stub: stub, config: config
    result = driver.run

    assert_equal '{"done":true}', result
    assert_equal 4, stub.requests.size
    assert_query_request stub.requests[0]
    assert_query_request stub.requests[1]
    assert_chunk_request stub.requests[2], offset: "4", length: "4", body: "4567", finalize: false
    assert_chunk_request stub.requests[3], offset: "8", length: "2", body: "89", finalize: true

    assert_equal [
      Progress.new(phase: :initiating, bytes_uploaded: 0, total_bytes: 10),
      Progress.new(phase: :uploading, bytes_uploaded: 4, total_bytes: 10),
      Progress.new(phase: :uploading, bytes_uploaded: 8, total_bytes: 10),
      Progress.new(phase: :finalizing, bytes_uploaded: 8, total_bytes: 10),
      Progress.new(phase: :completed, bytes_uploaded: 10, total_bytes: 10)
    ], progress_records
  end

  def test_run_returns_nil_body_when_final_response_has_none
    responses = [
      FakeResponse.new(
        status:  200,
        headers: {
          "X-Goog-Upload-URL"    => "https://example.com/session/1",
          "X-Goog-Upload-Status" => "active"
        },
        body:    ""
      ),
      FakeResponse.new(
        status:  200,
        headers: { "X-Goog-Upload-Status" => "final" },
        body:    nil
      )
    ]
    stub = FakeClientStub.new responses
    config = StartUploadConfig.new(
      initial_url: "https://example.com/upload",
      stream:      StringIO.new("ab"),
      upload_size: 2,
      chunk_size:  4
    )

    driver = Driver.new client_stub: stub, config: config
    result = driver.run

    assert_nil result
    assert_equal 2, stub.requests.size
  end

  # Fake Core yielding a fixed Decision to test Driver#run invariant guards.
  class FakeCore
    attr_reader :state, :last_decision

    def initialize decision
      @decision = decision
      @state = decision.next_state
      @last_decision = nil
    end

    def dispatch _event
      @last_decision = @decision
      @decision.instructions
    end
  end

  def test_run_raises_internal_error_on_empty_batch
    config = StartUploadConfig.new(
      initial_url: "https://example.com/upload",
      stream:      StringIO.new("data"),
      upload_size: 4
    )
    decision = Decision.new(
      from_status:  :initializing,
      shape:        :start_upload,
      recipe:       :broken_empty,
      next_state:   State.new(status: :starting),
      instructions: []
    )
    driver = Driver.new client_stub: FakeClientStub.new([]), config: config, core: FakeCore.new(decision)

    err = assert_raises InternalError do
      driver.run
    end
    assert_equal "Resumable upload internal error: recipe :broken_empty " \
                 "produced no continuation event and did not terminate",
                 err.message
  end

  def test_run_raises_internal_error_on_multiple_continuation_events
    config = StartUploadConfig.new(
      initial_url: "https://example.com/upload",
      stream:      StringIO.new("data"),
      upload_size: 4
    )
    send_start = Instruction::SendStart.new url: "https://example.com/upload", headers: {}, body: ""
    decision = Decision.new(
      from_status:  :initializing,
      shape:        :start_upload,
      recipe:       :broken_multi,
      next_state:   State.new(status: :starting),
      instructions: [send_start, send_start]
    )
    resp = FakeResponse.new(
      status:  200,
      headers: {
        "X-Goog-Upload-URL"    => "https://example.com/session/1",
        "X-Goog-Upload-Status" => "active"
      },
      body:    ""
    )
    stub = FakeClientStub.new [resp, resp]
    driver = Driver.new client_stub: stub, config: config, core: FakeCore.new(decision)

    err = assert_raises InternalError do
      driver.run
    end
    assert_equal "Resumable upload internal error: recipe :broken_multi produced multiple continuation events",
                 err.message
    assert_empty stub.requests
  end

  def test_run_raises_internal_error_on_mixed_continuation_and_terminal
    config = StartUploadConfig.new(
      initial_url: "https://example.com/upload",
      stream:      StringIO.new("data"),
      upload_size: 4
    )
    send_start = Instruction::SendStart.new url: "https://example.com/upload", headers: {}, body: ""
    term_success = Instruction::TerminateSuccess.new response: Event::HttpResponse.new(status: 200, headers: {}, body: "")
    decision = Decision.new(
      from_status:  :initializing,
      shape:        :start_upload,
      recipe:       :broken_mixed,
      next_state:   State.new(status: :starting),
      instructions: [send_start, term_success]
    )
    stub = FakeClientStub.new []
    driver = Driver.new client_stub: stub, config: config, core: FakeCore.new(decision)

    err = assert_raises InternalError do
      driver.run
    end
    assert_equal "Resumable upload internal error: recipe :broken_mixed " \
                 "produced both a continuation event and a terminal instruction",
                 err.message
    assert_empty stub.requests
  end

  def test_run_raises_internal_error_on_unclassified_instruction
    config = StartUploadConfig.new(
      initial_url: "https://example.com/upload",
      stream:      StringIO.new("data"),
      upload_size: 4
    )
    decision = Decision.new(
      from_status:  :initializing,
      shape:        :start_upload,
      recipe:       :broken_unclassified,
      next_state:   State.new(status: :starting),
      instructions: [Object.new]
    )
    stub = FakeClientStub.new []
    driver = Driver.new client_stub: stub, config: config, core: FakeCore.new(decision)

    err = assert_raises InternalError do
      driver.run
    end
    assert_equal "Resumable upload internal error: recipe :broken_unclassified emitted unclassified instruction Object",
                 err.message
    assert_empty stub.requests
  end

  def test_on_progress_return_value_does_not_leak_into_trampoline_invariant
    stub = FakeClientStub.new build_scripted_responses
    config = StartUploadConfig.new(
      initial_url: "https://example.com/upload",
      stream:      StringIO.new("0123456789"),
      upload_size: 10,
      chunk_size:  4,
      on_progress: ->(_p) { Event::HttpResponse.new status: 200, headers: {} }
    )

    driver = Driver.new client_stub: stub, config: config
    result = driver.run

    assert_equal '{"done":true}', result
  end

  private

  def build_scripted_responses
    [
      FakeResponse.new(
        status:  200,
        headers: {
          "X-Goog-Upload-URL"    => "https://example.com/session/1",
          "X-Goog-Upload-Status" => "active"
        },
        body:    ""
      ),
      FakeResponse.new(status: 200, headers: { "X-Goog-Upload-Status" => "active" }, body: ""),
      FakeResponse.new(status: 200, headers: { "X-Goog-Upload-Status" => "active" }, body: ""),
      FakeResponse.new(status: 200, headers: { "X-Goog-Upload-Status" => "final" }, body: '{"done":true}')
    ]
  end

  def build_recovery_responses
    [
      FakeResponse.new(
        status:  200,
        headers: {
          "X-Goog-Upload-URL"    => "https://example.com/session/1",
          "X-Goog-Upload-Status" => "active"
        },
        body:    ""
      ),
      FakeResponse.new(status: 503, headers: {}, body: "Service Unavailable"),
      FakeResponse.new(
        status:  200,
        headers: {
          "X-Goog-Upload-Status"        => "active",
          "X-Goog-Upload-Size-Received" => "4"
        },
        body:    ""
      ),
      FakeResponse.new(status: 200, headers: { "X-Goog-Upload-Status" => "active" }, body: ""),
      FakeResponse.new(status: 200, headers: { "X-Goog-Upload-Status" => "final" }, body: '{"done":true}')
    ]
  end

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

  # `upload_url` reports the session URL whatever the lifecycle status, while `resume_handle` reports one
  # only while the upload is still resumable.
  def test_upload_url_and_resume_handle_across_statuses
    config = StartUploadConfig.new(
      initial_url: "https://example.com/upload",
      stream:      StringIO.new("data"),
      upload_size: 4,
      chunk_size:  4
    )
    driver = Driver.new client_stub: FakeClientStub.new([]), config: config

    assert_nil driver.upload_url

    set_driver_status driver, :transmission_sending
    assert_equal "https://upload.example.com/sess1", driver.upload_url
    assert_equal "https://upload.example.com/sess1", driver.resume_handle.upload_url

    [:rejected, :cancelled, :success].each do |status|
      set_driver_status driver, status
      assert_equal "https://upload.example.com/sess1", driver.upload_url
      assert_nil driver.resume_handle
    end
  end

  def set_driver_status driver, status
    driver.core.instance_variable_set(
      :@state,
      driver.core.state.with(status: status, upload_url: "https://upload.example.com/sess1")
    )
  end
end
