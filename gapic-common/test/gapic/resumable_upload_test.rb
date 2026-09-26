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
require "gapic/rest"
require "stringio"

class ResumableUploadTest < Minitest::Test
  include Gapic::Rest::ResumableUpload

  FakeResponse = Struct.new :status, :headers, :body, keyword_init: true

  INITIAL_URL = "https://example.com/initiate"
  INITIAL_BODY = '{"name":"test.txt"}'
  SESSION_URL = "https://upload.example.com/session_1"

  # A zero budget: the Driver re-sends nothing, so a scripted connection failure on initiation or a query
  # surfaces at once instead of being retried against the next scripted response.
  NO_RETRY = { timeout: 0 }.freeze

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

  # Stream that reports no position at all, which a resumed run has to trust.
  class StreamWithoutPos
    def initialize string
      @io = StringIO.new string
    end

    def read length = nil
      @io.read length
    end
  end

  # Stream that records whether anything read from it, to pin down when a run first touches it.
  class WatchedStream
    attr_reader :reads

    def initialize string
      @io = StringIO.new string
      @reads = 0
    end

    def pos
      @io.pos
    end

    def read length = nil
      @reads += 1
      @io.read length
    end
  end

  def setup
    @proc_calls = []
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  def build_upload stub: nil, response_type: nil, initial_request: nil, **kwargs
    @stub = stub || ScriptedClientStub.new
    Gapic::ResumableUpload.new(
      client_stub_proc:     lambda {
        @proc_calls << :client_stub
        @stub
      },
      initial_request_proc: lambda {
        @proc_calls << :initial_request
        initial_request || [INITIAL_URL, INITIAL_BODY]
      },
      response_type:        response_type,
      **kwargs
    )
  end

  def start_upload upload, stream: nil, upload_size: 10, chunk_size: 4, **overrides
    upload.start stream:      stream || StringIO.new("0123456789"),
                 upload_size: upload_size,
                 chunk_size:  chunk_size,
                 **overrides
  end

  def driver_of upload
    upload.instance_variable_get :@driver
  end

  def config_of upload
    driver_of(upload).instance_variable_get :@config
  end

  def initiation_response url: SESSION_URL, granularity: 4
    FakeResponse.new(
      status:  200,
      headers: {
        "x-goog-upload-status"            => "active",
        "x-goog-upload-url"               => url,
        "x-goog-upload-chunk-granularity" => granularity.to_s
      },
      body:    ""
    )
  end

  def query_response received: 0
    FakeResponse.new(
      status:  200,
      headers: { "x-goog-upload-status" => "active", "x-goog-upload-size-received" => received.to_s },
      body:    ""
    )
  end

  def chunk_response
    FakeResponse.new status: 200, headers: { "x-goog-upload-status" => "active" }, body: ""
  end

  def final_response body = '{"text":"done"}'
    FakeResponse.new status: 200, headers: { "x-goog-upload-status" => "final" }, body: body
  end

  # Initiation plus a single finalizing chunk, enough for a two-byte stream.
  def short_upload_responses body: '{"text":"done"}'
    [initiation_response, final_response(body)]
  end

  # Recovery query plus a single finalizing chunk, enough to resume a two-byte stream.
  def short_resume_responses body: '{"text":"done"}'
    [query_response, final_response(body)]
  end

  def resume_handle_for url: SESSION_URL, chunk_size: 4
    ResumeHandle.new upload_url: url, chunk_size: chunk_size
  end

  # ============================================================================
  # 1. Deferred procs
  # ============================================================================

  def test_start_calls_client_stub_proc_then_initial_request_proc
    upload = build_upload stub: ScriptedClientStub.new(short_upload_responses)

    start_upload upload, stream: StringIO.new("01"), upload_size: 2

    assert_equal [:client_stub, :initial_request], @proc_calls
  end

  def test_resume_never_calls_initial_request_proc
    upload = build_upload stub: ScriptedClientStub.new(short_resume_responses)

    upload.resume stream: StringIO.new("01"), upload_size: 2, resume_handle: resume_handle_for

    assert_equal [:client_stub], @proc_calls
  end

  def test_raising_client_stub_proc_surfaces_before_the_stream_is_read
    stream = WatchedStream.new "0123456789"
    upload = Gapic::ResumableUpload.new(
      client_stub_proc:     -> { raise ArgumentError, "REST is unavailable" },
      initial_request_proc: -> { [INITIAL_URL, INITIAL_BODY] },
      response_type:        nil
    )

    error = assert_raises ArgumentError do
      upload.start stream: stream, upload_size: 10
    end

    assert_equal "REST is unavailable", error.message
    assert_equal 0, stream.reads
    refute upload.running?
    assert_nil driver_of(upload)
  end

  def test_resume_rejects_a_non_zero_stream_before_calling_the_client_stub_proc
    stream = StringIO.new "0123456789"
    stream.seek 4
    upload = build_upload

    error = assert_raises ArgumentError do
      upload.resume stream: stream, resume_handle: resume_handle_for
    end

    assert_includes error.message, "Stream must be positioned at byte 0 to resume an upload (got pos 4)"
    assert_empty @proc_calls
  end

  # ============================================================================
  # 2. Configuration construction
  # ============================================================================

  def test_start_builds_a_start_config_from_constructor_and_run_arguments
    upload = build_upload stub:               ScriptedClientStub.new(short_upload_responses),
                          initial_headers:    { "X-Goog-Test" => "yes", :symbol_key => 7 },
                          start_retry_policy: { initial_delay: 0.01 }

    start_upload upload, stream: StringIO.new("01"), upload_size: 2, chunk_size: 4,
                 content_type: "text/plain", upload_timeout: 42

    config = config_of upload
    assert_instance_of StartUploadConfig, config
    assert_equal INITIAL_URL, config.initial_url
    assert_equal INITIAL_BODY, config.initial_body
    assert_equal({ "X-Goog-Test" => "yes", "symbol_key" => "7" }, config.initial_headers)
    assert_equal 4, config.chunk_size
    assert_equal({ initial_delay: 0.01 }, config.start_retry_policy)
    assert_equal 2, config.upload_size
    assert_equal "text/plain", config.content_type
    assert_equal 42, config.timeout
  end

  def test_resume_builds_a_resume_config_from_the_handle
    upload = build_upload stub: ScriptedClientStub.new(short_resume_responses)
    handle = resume_handle_for url: "https://upload.example.com/persisted", chunk_size: 8

    upload.resume stream: StringIO.new("01"), upload_size: 2, resume_handle: handle

    config = config_of upload
    assert_instance_of ResumeUploadConfig, config
    assert_equal "https://upload.example.com/persisted", config.upload_url
    assert_equal 8, config.chunk_size
  end

  def test_upload_timeout_is_omitted_when_unset
    upload = build_upload stub: ScriptedClientStub.new(short_upload_responses)

    start_upload upload, stream: StringIO.new("01"), upload_size: 2

    assert_nil config_of(upload).timeout
  end

  def test_plane_retry_policies_come_from_the_constructor
    upload = build_upload stub:                       ScriptedClientStub.new(short_upload_responses),
                          control_plane_retry_policy: { initial_delay: 0.02 },
                          data_plane_retry_policy:    { initial_delay: 0.03 }

    start_upload upload, stream: StringIO.new("01"), upload_size: 2

    config = config_of upload
    assert_equal({ initial_delay: 0.02 }, config.control_plane_retry_policy)
    assert_equal({ initial_delay: 0.03 }, config.data_plane_retry_policy)
  end

  def test_reserved_initial_header_raises_before_any_request
    stub = ScriptedClientStub.new
    upload = build_upload stub: stub, initial_headers: { "X-Goog-Upload-Header-Content-Type" => "image/png" }

    error = assert_raises ArgumentError do
      start_upload upload, stream: StringIO.new("01"), upload_size: 2
    end

    assert_match(/must not set protocol header/, error.message)
    assert_empty stub.requests
    assert_nil driver_of(upload)
  end

  # ============================================================================
  # 3. Lifecycle
  # ============================================================================

  def test_readers_before_the_first_run
    upload = build_upload

    assert_nil upload.resume_handle
    refute upload.resumable?
    refute upload.running?
  end

  def test_successful_run_leaves_nothing_to_resume
    upload = build_upload stub: ScriptedClientStub.new(short_upload_responses)

    result = start_upload upload, stream: StringIO.new("01"), upload_size: 2

    assert_equal '{"text":"done"}', result
    refute upload.running?
    refute upload.resumable?
    assert_nil upload.resume_handle
  end

  def test_handle_is_reusable_across_runs
    responses = short_upload_responses(body: '{"text":"first"}') +
                short_upload_responses(body: '{"text":"second"}')
    upload = build_upload stub: ScriptedClientStub.new(responses)

    assert_equal '{"text":"first"}', start_upload(upload, stream: StringIO.new("01"), upload_size: 2)
    first_driver = driver_of upload

    assert_equal '{"text":"second"}', start_upload(upload, stream: StringIO.new("01"), upload_size: 2)
    refute_same first_driver, driver_of(upload)
  end

  def test_concurrent_run_raises_session_state_error
    started_q = Queue.new
    unblock_q = Queue.new
    blocking_proc = proc do
      started_q.push :started
      unblock_q.pop
      initiation_response
    end
    upload = build_upload stub: ScriptedClientStub.new([blocking_proc, final_response])

    worker = Thread.new { start_upload upload, stream: StringIO.new("01"), upload_size: 2 }
    started_q.pop
    assert upload.running?

    error = assert_raises SessionStateError do
      upload.resume stream: StringIO.new("01"), resume_handle: resume_handle_for
    end
    assert_includes error.message, "A run is already in progress for this upload"

    assert_raises SessionStateError do
      start_upload upload, stream: StringIO.new("01"), upload_size: 2
    end

    unblock_q.push :continue
    assert_equal '{"text":"done"}', worker.value
    refute upload.running?
  end

  def test_run_slot_is_released_after_a_failed_run
    stub = ScriptedClientStub.new [initiation_response, Faraday::ConnectionFailed.new("boom"),
                                   Faraday::ConnectionFailed.new("boom")]
    upload = build_upload stub: stub, control_plane_retry_policy: NO_RETRY

    assert_raises RequestFailedError do
      start_upload upload, stream: StringIO.new("01"), upload_size: 2
    end

    refute upload.running?
    assert upload.resumable?
  end

  def test_run_slot_is_released_after_a_progress_callback_raises
    upload = build_upload stub: ScriptedClientStub.new(short_upload_responses)
    on_progress = ->(_progress) { raise "callback exploded" }

    error = assert_raises RuntimeError do
      start_upload upload, stream: StringIO.new("01"), upload_size: 2, on_progress: on_progress
    end

    assert_equal "callback exploded", error.message
    refute upload.running?
  end

  def test_run_slot_is_released_after_a_configuration_error
    upload = build_upload start_retry_policy: "nonsense"

    assert_raises ArgumentError do
      start_upload upload, stream: StringIO.new("01"), upload_size: 2
    end

    refute upload.running?
    assert_nil driver_of(upload)
  end

  def test_configuration_error_leaves_an_earlier_runs_resume_handle_intact
    stub = ScriptedClientStub.new [initiation_response, Faraday::ConnectionFailed.new("boom"),
                                   Faraday::ConnectionFailed.new("boom")]
    upload = build_upload stub: stub, control_plane_retry_policy: NO_RETRY
    assert_raises RequestFailedError do
      start_upload upload, stream: StringIO.new("01"), upload_size: 2
    end
    handle = upload.resume_handle
    refute_nil handle

    assert_raises ArgumentError do
      upload.resume stream: StringIO.new("01"), upload_size: 2, resume_handle: resume_handle_for(chunk_size: -1)
    end

    assert_equal handle, upload.resume_handle
  end

  def test_a_second_run_replaces_the_previous_runs_resume_handle
    stub = ScriptedClientStub.new [initiation_response, Faraday::ConnectionFailed.new("boom"),
                                   Faraday::ConnectionFailed.new("boom"),
                                   Faraday::ConnectionFailed.new("boom")]
    upload = build_upload stub: stub, start_retry_policy: NO_RETRY, control_plane_retry_policy: NO_RETRY
    assert_raises RequestFailedError do
      start_upload upload, stream: StringIO.new("01"), upload_size: 2
    end
    refute_nil upload.resume_handle

    # The second run fails at initiation, so it establishes no upload of its own. Its driver still takes
    # over the reader: the previous run's handle is replaced, not kept as a fallback.
    assert_raises RequestFailedError do
      start_upload upload, stream: StringIO.new("01"), upload_size: 2
    end

    assert_nil upload.resume_handle
    refute upload.resumable?
  end

  # ============================================================================
  # 4. Resume forms
  # ============================================================================

  def test_resume_with_an_explicit_handle
    upload = build_upload stub: ScriptedClientStub.new(short_resume_responses(body: '{"text":"resumed"}'))
    handle = resume_handle_for url: "https://upload.example.com/persisted", chunk_size: 4

    result = upload.resume stream: StringIO.new("01"), upload_size: 2, resume_handle: handle

    assert_equal '{"text":"resumed"}', result
    assert_equal "https://upload.example.com/persisted", @stub.requests.first[:uri]
  end

  def test_bare_resume_reuses_the_retained_drivers_handle
    stub = ScriptedClientStub.new [initiation_response, Faraday::ConnectionFailed.new("boom"),
                                   Faraday::ConnectionFailed.new("boom"),
                                   query_response, final_response('{"text":"resumed"}')]
    upload = build_upload stub: stub, control_plane_retry_policy: NO_RETRY
    assert_raises RequestFailedError do
      start_upload upload, stream: StringIO.new("01"), upload_size: 2
    end
    assert upload.resumable?

    result = upload.resume stream: StringIO.new("01"), upload_size: 2

    assert_equal '{"text":"resumed"}', result
    assert_equal SESSION_URL, stub.requests.last[:uri]
  end

  def test_bare_resume_without_a_previous_run_raises_argument_error
    upload = build_upload

    error = assert_raises ArgumentError do
      upload.resume stream: StringIO.new("01")
    end

    assert_includes error.message, "No upload to resume"
  end

  def test_bare_resume_after_a_successful_run_raises_argument_error
    upload = build_upload stub: ScriptedClientStub.new(short_upload_responses)
    start_upload upload, stream: StringIO.new("01"), upload_size: 2

    assert_raises ArgumentError do
      upload.resume stream: StringIO.new("01")
    end
  end

  def test_bare_resume_after_an_unresumable_failure_raises_argument_error
    upload = build_upload stub:               ScriptedClientStub.new([Faraday::ConnectionFailed.new("boom")]),
                          start_retry_policy: NO_RETRY
    assert_raises RequestFailedError do
      start_upload upload, stream: StringIO.new("01"), upload_size: 2
    end
    refute upload.resumable?

    assert_raises ArgumentError do
      upload.resume stream: StringIO.new("01")
    end
  end

  def test_resume_trusts_a_stream_that_reports_no_position
    upload = build_upload stub: ScriptedClientStub.new(short_resume_responses)

    result = upload.resume stream:        StreamWithoutPos.new("01"),
                           upload_size:   2,
                           resume_handle: resume_handle_for

    assert_equal '{"text":"done"}', result
  end

  # ============================================================================
  # 5. Response decoding
  # ============================================================================

  def test_decodes_the_final_body_into_the_response_type
    upload = build_upload stub:          ScriptedClientStub.new(short_upload_responses(body: '{"text":"decoded"}')),
                          response_type: Gapic::Examples::Post

    result = start_upload upload, stream: StringIO.new("01"), upload_size: 2

    assert_instance_of Gapic::Examples::Post, result
    assert_equal "decoded", result.text
  end

  def test_decodes_an_empty_final_body_into_an_empty_message
    upload = build_upload stub:          ScriptedClientStub.new(short_upload_responses(body: "")),
                          response_type: Gapic::Examples::Post

    result = start_upload upload, stream: StringIO.new("01"), upload_size: 2

    assert_equal Gapic::Examples::Post.new, result
  end

  def test_decodes_an_absent_final_body_into_an_empty_message
    upload = build_upload stub:          ScriptedClientStub.new(short_upload_responses(body: nil)),
                          response_type: Gapic::Examples::Post

    result = start_upload upload, stream: StringIO.new("01"), upload_size: 2

    assert_equal Gapic::Examples::Post.new, result
  end

  def test_malformed_final_body_raises_a_parse_error
    upload = build_upload stub:          ScriptedClientStub.new(short_upload_responses(body: '{"text":')),
                          response_type: Gapic::Examples::Post

    assert_raises Google::Protobuf::ParseError do
      start_upload upload, stream: StringIO.new("01"), upload_size: 2
    end
  end

  def test_ignores_unknown_fields_in_the_final_body
    body = '{"text":"decoded","unknown_field":true}'
    upload = build_upload stub:          ScriptedClientStub.new(short_upload_responses(body: body)),
                          response_type: Gapic::Examples::Post

    assert_equal "decoded", start_upload(upload, stream: StringIO.new("01"), upload_size: 2).text
  end

  def test_no_response_type_returns_the_raw_body
    upload = build_upload stub: ScriptedClientStub.new(short_upload_responses(body: "not json at all"))

    assert_equal "not json at all", start_upload(upload, stream: StringIO.new("01"), upload_size: 2)
  end

  def test_no_response_type_returns_nil_for_a_bodiless_response
    upload = build_upload stub: ScriptedClientStub.new(short_upload_responses(body: nil))

    assert_nil start_upload(upload, stream: StringIO.new("01"), upload_size: 2)
  end

  # ============================================================================
  # 6. Error handling
  # ============================================================================

  class WrappedError < StandardError; end

  def failing_upload **kwargs
    stub = ScriptedClientStub.new [initiation_response, Faraday::ConnectionFailed.new("boom"),
                                   Faraday::ConnectionFailed.new("boom")]
    build_upload stub: stub, control_plane_retry_policy: NO_RETRY, **kwargs
  end

  def test_error_handler_replaces_the_raised_error
    upload = failing_upload error_handler: ->(e) { WrappedError.new "wrapped: #{e.message}" }

    error = assert_raises WrappedError do
      start_upload upload, stream: StringIO.new("01"), upload_size: 2
    end

    assert_includes error.message, "wrapped:"
  end

  def test_wrapped_error_remains_rescuable_as_has_resume_handle
    upload = failing_upload error_handler: ->(_e) { WrappedError.new "wrapped" }

    error = assert_raises HasResumeHandle do
      start_upload upload, stream: StringIO.new("01"), upload_size: 2
    end

    assert_instance_of WrappedError, error
    assert_equal upload.resume_handle, error.resume_handle
    assert_equal SESSION_URL, error.resume_handle.upload_url
  end

  def test_error_handler_returning_nil_reraises_the_original
    upload = failing_upload error_handler: ->(_e) { nil }

    assert_raises RequestFailedError do
      start_upload upload, stream: StringIO.new("01"), upload_size: 2
    end
  end

  def test_error_handler_returning_the_original_reraises_it
    upload = failing_upload error_handler: ->(e) { e }

    assert_raises RequestFailedError do
      start_upload upload, stream: StringIO.new("01"), upload_size: 2
    end
  end

  def test_an_error_without_a_resume_handle_is_not_decorated
    upload = build_upload stub:          ScriptedClientStub.new(short_upload_responses),
                          error_handler: ->(_e) { WrappedError.new "wrapped" }
    on_progress = ->(_progress) { raise "callback exploded" }

    error = assert_raises WrappedError do
      start_upload upload, stream: StringIO.new("01"), upload_size: 2, on_progress: on_progress
    end

    refute error.is_a?(HasResumeHandle)
  end

  def test_no_error_handler_propagates_the_protocol_error
    upload = failing_upload

    error = assert_raises RequestFailedError do
      start_upload upload, stream: StringIO.new("01"), upload_size: 2
    end

    assert_equal upload.resume_handle, error.resume_handle
  end

  # ============================================================================
  # 7. Logging
  # ============================================================================

  def test_method_name_reaches_the_client_stub
    upload = build_upload stub: ScriptedClientStub.new(short_upload_responses), method_name: "create_media_upload"

    start_upload upload, stream: StringIO.new("01"), upload_size: 2

    assert_equal ["create_media_upload.start", "create_media_upload.upload"],
                 @stub.requests.map { |request| request[:method_name] }
  end

  def test_method_name_defaults_to_the_protocol_name
    upload = build_upload stub: ScriptedClientStub.new(short_upload_responses)

    start_upload upload, stream: StringIO.new("01"), upload_size: 2

    assert_equal ["ResumableUpload.start", "ResumableUpload.upload"],
                 @stub.requests.map { |request| request[:method_name] }
  end
end
