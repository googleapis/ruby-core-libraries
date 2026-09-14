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

class SessionTest < Minitest::Test
  include Gapic::Rest::ResumableUpload

  FakeResponse = Struct.new :status, :headers, :body, keyword_init: true

  class ScriptedClientStub
    attr_reader :requests

    def initialize responses = []
      @responses = responses.dup
      @requests = []
    end

    def make_post_request uri:, body:, params:, options:, method_name: nil
      @requests << { uri: uri, body: body, params: params, options: options, method_name: method_name }
      raise "Unexpected request: no scripted response left" if @responses.empty?

      res = @responses.shift
      if res.is_a? Proc
        res.call
      elsif res.is_a? Exception
        raise res
      else
        res
      end
    end
  end

  class UnseekableStream
    attr_reader :pos

    def initialize string
      @io = StringIO.new string
      @pos = 0
    end

    def read length = nil
      chunk = @io.read length
      @pos += chunk.bytesize if chunk
      chunk
    end
  end

  class StreamWithoutPos
    def initialize string
      @io = StringIO.new string
    end

    def read length = nil
      @io.read length
    end
  end

  START_ONLY_KEYS = [:initial_url, :initial_body, :initial_headers, :chunk_size, :start_retry_policy].freeze

  # Builds a session from the shared arguments and remembers the per-run arguments that #start needs,
  # so tests can keep calling `start_session session`.
  def build_session stub: nil, stream: nil, upload_size: 10, chunk_size: 4, **kwargs
    stream ||= StringIO.new "0123456789"
    stub ||= ScriptedClientStub.new
    @start_args = {
      initial_url:  "https://example.com/initiate",
      initial_body: '{"name":"test.txt"}',
      chunk_size:   chunk_size
    }.merge(kwargs.slice(*START_ONLY_KEYS))

    Session.new(
      client_stub: stub,
      stream:      stream,
      upload_size: upload_size,
      **kwargs.except(*START_ONLY_KEYS)
    )
  end

  def start_session session, **overrides
    session.start(**@start_args, **overrides)
  end

  # ============================================================================
  # 1. Initialization and argument validation
  # ============================================================================

  def test_initialize_mandatory_arguments
    assert_raises ArgumentError do
      Session.new stream: StringIO.new
    end

    assert_raises ArgumentError do
      Session.new client_stub: ScriptedClientStub.new
    end
  end

  def test_initialize_rejects_per_run_arguments
    assert_raises ArgumentError do
      Session.new client_stub: ScriptedClientStub.new, stream: StringIO.new, initial_url: "http://x"
    end

    assert_raises ArgumentError do
      Session.new client_stub: ScriptedClientStub.new, stream: StringIO.new, chunk_size: 4
    end
  end

  def test_initialize_defaults
    session = Session.new(
      client_stub: ScriptedClientStub.new,
      stream:      StringIO.new("abc"),
      upload_size: 300
    )

    assert_equal 300, session.upload_size
    assert_nil session.content_type
    assert_nil session.timeout
    assert_nil session.control_plane_retry_policy
    assert_nil session.data_plane_retry_policy
    assert_nil session.on_progress
    assert_nil session.logger
  end

  def test_start_without_initial_url_raises_argument_error
    session = Session.new client_stub: ScriptedClientStub.new, stream: StringIO.new("abc"), upload_size: 3

    error = assert_raises ArgumentError do
      session.start
    end
    assert_match(/initial_url/, error.message)
  end

  def test_start_with_blank_initial_url_raises_argument_error
    session = Session.new client_stub: ScriptedClientStub.new, stream: StringIO.new("abc"), upload_size: 3

    error = assert_raises ArgumentError do
      session.start initial_url: "   "
    end
    assert_match(/initial_url is required/, error.message)
  end

  def test_start_with_malformed_retry_policy_raises_argument_error
    session = build_session

    error = assert_raises ArgumentError do
      start_session session, start_retry_policy: "nonsense"
    end
    assert_match(/Expected RetryPolicy, Hash, or nil/, error.message)
  end

  def test_start_with_reserved_initial_header_raises_before_any_request
    stub = ScriptedClientStub.new
    session = build_session stub: stub

    error = assert_raises ArgumentError do
      start_session session, initial_headers: { "X-Goog-Upload-Header-Content-Type" => "image/png" }
    end
    assert_match(/must not set protocol header/, error.message)
    assert_empty stub.requests
    refute session.bound?
  end

  def test_failed_start_leaves_session_reusable
    session = build_session

    assert_raises ArgumentError do
      start_session session, start_retry_policy: "nonsense"
    end

    refute session.running?
    refute session.bound?
  end

  def test_resume_needs_no_initiation_arguments
    responses = [
      FakeResponse.new(
        status:  200,
        headers: {
          "x-goog-upload-status"        => "active",
          "x-goog-upload-size-received" => "0"
        },
        body:    ""
      ),
      FakeResponse.new(
        status:  200,
        headers: { "x-goog-upload-status" => "final" },
        body:    '{"resumed":true}'
      )
    ]
    session = Session.new(
      client_stub: ScriptedClientStub.new(responses),
      stream:      StringIO.new("01"),
      upload_size: 2
    )
    handle = ResumeHandle.new upload_url: "https://upload.example.com/persisted", chunk_size: 4

    result = session.resume resume_handle: handle

    assert_equal '{"resumed":true}', result
    assert_equal "https://upload.example.com/persisted", session.upload_url
  end

  # ============================================================================
  # 2. Observable States: Unbound & Bound
  # ============================================================================

  def test_initial_unbound_state
    session = build_session
    refute session.bound?
    assert_nil session.upload_url
    assert_nil session.resume_handle
    refute session.resumable?
    refute session.running?
  end

  # ============================================================================
  # 3. Start Lifecycle & Single-Run Contract
  # ============================================================================

  def test_start_successful_upload_transitions_to_bound
    responses = [
      # Initiation response
      FakeResponse.new(
        status:  200,
        headers: {
          "x-goog-upload-status"            => "active",
          "x-goog-upload-url"               => "https://upload.example.com/session_1",
          "x-goog-upload-chunk-granularity" => "4"
        },
        body:    ""
      ),
      # Chunk 1 (0-3)
      FakeResponse.new(
        status:  200,
        headers: { "x-goog-upload-status" => "active" },
        body:    ""
      ),
      # Chunk 2 (4-7)
      FakeResponse.new(
        status:  200,
        headers: { "x-goog-upload-status" => "active" },
        body:    ""
      ),
      # Final Chunk (8-9)
      FakeResponse.new(
        status:  200,
        headers: { "x-goog-upload-status" => "final" },
        body:    '{"status":"completed"}'
      )
    ]

    stub = ScriptedClientStub.new responses
    session = build_session stub: stub, upload_size: 10, chunk_size: 4

    result = start_session session

    assert_equal '{"status":"completed"}', result
    assert session.bound?
    assert_equal "https://upload.example.com/session_1", session.upload_url
    refute session.running?
    refute session.resumable?
    assert_nil session.resume_handle
  end

  def test_second_start_raises_session_state_error
    responses = [
      FakeResponse.new(
        status:  200,
        headers: {
          "x-goog-upload-status"            => "active",
          "x-goog-upload-url"               => "https://upload.example.com/session_1",
          "x-goog-upload-chunk-granularity" => "4"
        },
        body:    ""
      ),
      FakeResponse.new(
        status:  200,
        headers: { "x-goog-upload-status" => "final" },
        body:    '{"done":true}'
      )
    ]
    session = build_session(
      stub:        ScriptedClientStub.new(responses),
      stream:      StringIO.new("01"),
      upload_size: 2,
      chunk_size:  4
    )
    start_session session

    assert session.bound?

    err = assert_raises SessionStateError do
      start_session session
    end
    assert_includes err.message, "Session has already executed a run"
  end

  def test_resume_after_start_raises_session_state_error
    responses = [
      FakeResponse.new(
        status:  200,
        headers: {
          "x-goog-upload-status"            => "active",
          "x-goog-upload-url"               => "https://upload.example.com/session_1",
          "x-goog-upload-chunk-granularity" => "4"
        },
        body:    ""
      ),
      FakeResponse.new(
        status:  200,
        headers: { "x-goog-upload-status" => "final" },
        body:    '{"done":true}'
      )
    ]
    session = build_session(
      stub:        ScriptedClientStub.new(responses),
      stream:      StringIO.new("01"),
      upload_size: 2,
      chunk_size:  4
    )
    start_session session

    handle = ResumeHandle.new upload_url: "https://upload.example.com/session_1", chunk_size: 4
    err = assert_raises SessionStateError do
      session.resume resume_handle: handle
    end
    assert_includes err.message, "Session has already executed a run"
  end

  # ============================================================================
  # 4. Resume Forms: Explicit URL or ResumeHandle
  # ============================================================================

  def test_resume_explicit_url_and_chunk_size_binds_and_executes
    responses = [
      FakeResponse.new(
        status:  200,
        headers: {
          "x-goog-upload-status"        => "active",
          "x-goog-upload-size-received" => "0"
        },
        body:    ""
      ),
      FakeResponse.new(
        status:  200,
        headers: { "x-goog-upload-status" => "final" },
        body:    '{"from_url":true}'
      )
    ]
    stub = ScriptedClientStub.new responses
    session = build_session stub: stub, stream: StringIO.new("01"), upload_size: 2, chunk_size: 4

    refute session.bound?
    result = session.resume upload_url: "https://upload.example.com/direct", chunk_size: 4

    assert_equal '{"from_url":true}', result
    assert session.bound?
    assert_equal "https://upload.example.com/direct", session.upload_url
  end

  def test_resume_resume_handle_binds_and_executes
    responses = [
      FakeResponse.new(
        status:  200,
        headers: {
          "x-goog-upload-status"        => "active",
          "x-goog-upload-size-received" => "0"
        },
        body:    ""
      ),
      FakeResponse.new(
        status:  200,
        headers: { "x-goog-upload-status" => "final" },
        body:    '{"from_handle":true}'
      )
    ]
    stub = ScriptedClientStub.new responses
    session = build_session stub: stub, stream: StringIO.new("01"), upload_size: 2, chunk_size: 4

    handle = ResumeHandle.new upload_url: "https://upload.example.com/from_handle", chunk_size: 4

    refute session.bound?
    result = session.resume resume_handle: handle

    assert_equal '{"from_handle":true}', result
    assert session.bound?
    assert_equal "https://upload.example.com/from_handle", session.upload_url
  end

  def test_start_after_resume_raises_session_state_error
    responses = [
      FakeResponse.new(
        status:  200,
        headers: {
          "x-goog-upload-status"        => "active",
          "x-goog-upload-size-received" => "0"
        },
        body:    ""
      ),
      FakeResponse.new(status: 200, headers: { "x-goog-upload-status" => "final" }, body: '{"ok":true}')
    ]
    stub = ScriptedClientStub.new responses
    session = build_session stub: stub, stream: StringIO.new("01"), upload_size: 2, chunk_size: 4
    session.resume upload_url: "https://upload.example.com/direct", chunk_size: 4

    assert session.bound?
    err = assert_raises SessionStateError do
      start_session session
    end
    assert_includes err.message, "Session has already executed a run"
  end

  def test_second_resume_raises_session_state_error
    responses = [
      FakeResponse.new(
        status:  200,
        headers: {
          "x-goog-upload-status"        => "active",
          "x-goog-upload-size-received" => "0"
        },
        body:    ""
      ),
      FakeResponse.new(status: 200, headers: { "x-goog-upload-status" => "final" }, body: '{"ok":true}')
    ]
    stub = ScriptedClientStub.new responses
    session = build_session stub: stub, stream: StringIO.new("01"), upload_size: 2, chunk_size: 4
    session.resume upload_url: "https://upload.example.com/direct", chunk_size: 4

    assert session.bound?
    err = assert_raises SessionStateError do
      session.resume upload_url: "https://upload.example.com/direct", chunk_size: 4
    end
    assert_includes err.message, "Session has already executed a run"
  end

  # ============================================================================
  # 5. Argument Shape & Preconditions
  # ============================================================================

  def test_resume_without_arguments_raises_argument_error
    session = build_session
    err = assert_raises ArgumentError do
      session.resume
    end
    assert_includes err.message, "Must provide either resume_handle or upload_url and chunk_size"
  end

  def test_resume_mixing_arguments_raises_argument_error
    session = build_session
    handle = ResumeHandle.new upload_url: "https://example.com", chunk_size: 4

    assert_raises ArgumentError do
      session.resume resume_handle: handle, upload_url: "https://example.com"
    end

    assert_raises ArgumentError do
      session.resume resume_handle: handle, chunk_size: 4
    end

    assert_raises ArgumentError do
      session.resume upload_url: "https://example.com"
    end

    assert_raises ArgumentError do
      session.resume chunk_size: 4
    end

    assert_raises ArgumentError do
      session.resume handle
    end
  end

  def test_resume_with_non_zero_stream_pos_raises_argument_error
    stream = StringIO.new "0123456789"
    stream.seek 4

    session = build_session stream: stream
    handle = ResumeHandle.new upload_url: "https://upload.example.com/from_handle", chunk_size: 4

    err = assert_raises ArgumentError do
      session.resume resume_handle: handle
    end
    assert_includes err.message, "Stream must be positioned at byte 0 to resume an upload (got pos 4)"
  end

  def test_resume_with_stream_without_pos_is_trusted
    stream = StreamWithoutPos.new "01"
    responses = [
      FakeResponse.new(
        status:  200,
        headers: {
          "x-goog-upload-status"        => "active",
          "x-goog-upload-size-received" => "0"
        },
        body:    ""
      ),
      FakeResponse.new(status: 200, headers: { "x-goog-upload-status" => "final" }, body: '{"ok":true}')
    ]
    stub = ScriptedClientStub.new responses
    session = build_session stub: stub, stream: stream, upload_size: 2, chunk_size: 4

    result = session.resume upload_url: "https://upload.example.com/direct", chunk_size: 4
    assert_equal '{"ok":true}', result
  end

  # ============================================================================
  # 6. Cross-Session Resumption
  # ============================================================================

  def test_cross_session_resumption_from_failed_run
    stream = StringIO.new "0123456789"
    stub1 = ScriptedClientStub.new [
      # Initiation succeeds
      FakeResponse.new(
        status:  200,
        headers: {
          "x-goog-upload-status"            => "active",
          "x-goog-upload-url"               => "https://upload.example.com/session_cross",
          "x-goog-upload-chunk-granularity" => "4"
        },
        body:    ""
      ),
      # Chunk 1 returns 503
      FakeResponse.new(status: 503, headers: {}, body: "Service Unavailable"),
      # Recovery query fails
      Faraday::ConnectionFailed.new("network connection failed")
    ]

    session1 = build_session stub: stub1, stream: stream, upload_size: 10, chunk_size: 4
    raised = assert_raises RequestFailedError do
      start_session session1
    end

    assert session1.bound?
    assert session1.resumable?
    handle = session1.resume_handle
    refute_nil handle
    assert_equal handle, raised.resume_handle
    assert_equal "https://upload.example.com/session_cross", handle.upload_url
    assert_equal 4, handle.chunk_size

    # Prepare for session 2: rewind the stream to byte 0
    stream.rewind
    assert_equal 0, stream.pos

    stub2 = ScriptedClientStub.new [
      # Recovery query on resume: server acknowledges 0 bytes received
      FakeResponse.new(
        status:  200,
        headers: {
          "x-goog-upload-status"        => "active",
          "x-goog-upload-size-received" => "0"
        },
        body:    ""
      ),
      # Chunk 1
      FakeResponse.new(status: 200, headers: { "x-goog-upload-status" => "active" }, body: ""),
      # Chunk 2
      FakeResponse.new(status: 200, headers: { "x-goog-upload-status" => "active" }, body: ""),
      # Chunk 3 (final)
      FakeResponse.new(status: 200, headers: { "x-goog-upload-status" => "final" }, body: '{"resumed":true}')
    ]

    session2 = build_session stub: stub2, stream: stream, upload_size: 10, chunk_size: 4
    refute session2.bound?

    result = session2.resume resume_handle: handle
    assert_equal '{"resumed":true}', result
    assert session2.bound?
    refute session2.resumable?
    assert_nil session2.resume_handle
  end

  # ============================================================================
  # 7. Concurrency & Running Guard
  # ============================================================================

  def test_running_guard_prevents_concurrent_runs
    started_q = Queue.new
    unblock_q = Queue.new

    blocking_proc = proc do
      started_q.push :started
      unblock_q.pop # wait until test signals to proceed
      FakeResponse.new(
        status:  200,
        headers: {
          "x-goog-upload-status"            => "active",
          "x-goog-upload-url"               => "https://upload.example.com/session_block",
          "x-goog-upload-chunk-granularity" => "4"
        },
        body:    ""
      )
    end

    stub = ScriptedClientStub.new [
      blocking_proc,
      FakeResponse.new(
        status:  200,
        headers: { "x-goog-upload-status" => "final" },
        body:    '{"done":true}'
      )
    ]
    session = build_session(
      stub:        stub,
      stream:      StringIO.new("01"),
      upload_size: 2,
      chunk_size:  4
    )

    worker = Thread.new do
      start_session session
    end

    started_q.pop # wait for worker thread to enter driver.run
    assert session.running?

    # Concurrent call from another thread raises SessionStateError
    handle = ResumeHandle.new upload_url: "https://upload.example.com/session_block", chunk_size: 4
    err = assert_raises SessionStateError do
      session.resume resume_handle: handle
    end
    assert_includes err.message, "A run is already in progress for this session"

    err_start = assert_raises SessionStateError do
      start_session session
    end
    assert_includes err_start.message, "A run is already in progress for this session"

    # Unblock worker thread
    unblock_q.push :continue
    result = worker.value

    assert_equal '{"done":true}', result
    refute session.running?
  end

  # ============================================================================
  # 8. Driver#upload_url Direct Verification
  # ============================================================================

  def test_driver_upload_url_across_statuses
    dummy_client = ScriptedClientStub.new
    config = StartUploadConfig.new(
      initial_url: "https://example.com/upload",
      stream:      StringIO.new("data"),
      upload_size: 4,
      chunk_size:  4
    )
    driver = Driver.new client_stub: dummy_client, config: config

    assert_nil driver.upload_url

    # Active
    driver.core.instance_variable_set(
      :@state,
      driver.core.state.with(status: :transmission_sending, upload_url: "https://upload.example.com/sess1")
    )
    assert_equal "https://upload.example.com/sess1", driver.upload_url
    assert_equal "https://upload.example.com/sess1", driver.resume_handle.upload_url

    # Rejected (resume_handle is nil, but upload_url remains readable)
    driver.core.instance_variable_set(
      :@state,
      driver.core.state.with(status: :rejected, upload_url: "https://upload.example.com/sess1")
    )
    assert_equal "https://upload.example.com/sess1", driver.upload_url
    assert_nil driver.resume_handle

    # Cancelled (resume_handle is nil, but upload_url remains readable)
    driver.core.instance_variable_set(
      :@state,
      driver.core.state.with(status: :cancelled, upload_url: "https://upload.example.com/sess1")
    )
    assert_equal "https://upload.example.com/sess1", driver.upload_url
    assert_nil driver.resume_handle

    # Success (resume_handle is nil, but upload_url remains readable)
    driver.core.instance_variable_set(
      :@state,
      driver.core.state.with(status: :success, upload_url: "https://upload.example.com/sess1")
    )
    assert_equal "https://upload.example.com/sess1", driver.upload_url
    assert_nil driver.resume_handle
  end
end
