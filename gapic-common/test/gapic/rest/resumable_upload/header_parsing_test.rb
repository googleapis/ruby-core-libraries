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
# Tests for the protocol headers an `active` answer must carry, and for strict parsing of the numeric ones.
#
# * A query answer whose `X-Goog-Upload-Size-Received` is missing or malformed is Category 2 and is re-queried
#   with backoff.
# * A start answer without `X-Goog-Upload-URL` is Category 2, which is terminal in `:starting`.
# * An `X-Goog-Upload-Chunk-Granularity` that is missing, malformed or zero is treated as absent.
#
# See `design/resumable_upload/implementation-guide.md` sections 4.1, 4.2, 5 and 6.1.2.
#
class HeaderParsingTest < Minitest::Test
  include Gapic::Rest::ResumableUpload

  FakeResponse = Struct.new :status, :headers, :body, keyword_init: true

  SESSION_URL = "https://example.com/session"

  # Delays 1, 2, 4, then capped at 5.
  BACKOFF = { initial_delay: 1, multiplier: 2, max_delay: 5, jitter: 0 }.freeze

  # Values that are not a non-negative decimal integer.
  MALFORMED = ["", "   ", "-5", "+5", "1.5", "12abc", "abc", "0x10", "1e3", "1_000"].freeze

  class FakeClientStub
    attr_reader :commands

    def initialize outcomes
      @outcomes = outcomes
      @commands = []
    end

    def make_post_request uri:, body:, params:, options:, method_name: nil
      _ = [uri, body, params, method_name]
      @commands << options[:metadata]["X-Goog-Upload-Command"]
      outcome = @outcomes.shift
      raise "Unexpected request: no scripted response left" if outcome.nil?
      raise outcome if outcome.is_a? Exception
      outcome
    end
  end

  def setup
    @config = StartUploadConfig.new(
      initial_url: "https://example.com/upload",
      stream:      StringIO.new("0123456789"),
      upload_size: 10,
      chunk_size:  4
    )
  end

  # --- Rules.parse_header_non_negative_integer ---

  def test_parses_non_negative_decimal_integers
    assert_equal 0, Rules.parse_header_non_negative_integer("0")
    assert_equal 123, Rules.parse_header_non_negative_integer("123")
    assert_equal 123, Rules.parse_header_non_negative_integer(" 123 ")
    assert_equal 8, Rules.parse_header_non_negative_integer("008")
    assert_equal 2**40, Rules.parse_header_non_negative_integer((2**40).to_s)
  end

  def test_rejects_everything_else
    ([nil] + MALFORMED).each do |value|
      assert_nil Rules.parse_header_non_negative_integer(value), "value #{value.inspect}"
    end
  end

  # --- X-Goog-Upload-Size-Received on the query answer ---

  def test_query_answer_without_a_parseable_offset_is_category_2
    ([nil] + MALFORMED).each do |value|
      assert_equal :response_cat2, Rules.classify_http_response(query_response(value), :recovery),
                   "value #{value.inspect}"
    end
  end

  def test_query_answer_with_a_parseable_offset_is_active
    ["0", "8", " 8 "].each do |value|
      assert_equal :response_active, Rules.classify_http_response(query_response(value), :recovery),
                   "value #{value.inspect}"
    end
  end

  # Each status requires only the headers of the command it awaits. Chunk acknowledgements carry neither.
  def test_no_header_is_required_outside_starting_and_recovery
    bare_active = Event::HttpResponse.new status: 200, headers: { "x-goog-upload-status" => "active" }
    (Rules::STATUSES - [:starting, :recovery]).each do |status|
      assert_equal :response_active, Rules.classify_http_response(bare_active, status), "status #{status.inspect}"
    end
  end

  # --- X-Goog-Upload-URL on the start answer ---

  def test_start_answer_without_an_upload_url_is_category_2
    [nil, "", "   "].each do |url|
      assert_equal :response_cat2, Rules.classify_http_response(start_response(nil, url: url), :starting),
                   "url #{url.inspect}"
    end
    assert_equal :response_active, Rules.classify_http_response(start_response(nil), :starting)
  end

  def test_start_answer_without_an_upload_url_fails_with_a_bad_response
    decision = Rules.decide State.new(status: :starting), start_response(nil, url: nil), @config

    assert_equal :fail_with_bad_response, decision.recipe
    assert_equal :error, decision.next_state.status
    assert_instance_of BadResponseError, decision.next_state.last_error
    assert_nil Rules.resume_handle_from(decision.next_state)
  end

  def test_driver_fails_without_a_resume_handle_when_the_upload_url_is_missing
    initiation = FakeResponse.new status: 200, headers: { "X-Goog-Upload-Status" => "active" }, body: ""
    stub = FakeClientStub.new [initiation]

    error = assert_raises BadResponseError do
      run_upload stub
    end

    assert_nil error.resume_handle
    assert_equal ["start"], stub.commands
  end

  def test_missing_offset_re_queries_with_backoff_instead_of_realigning
    state = recovery_state offset: 4, recovery_offset: 4
    decision = Rules.decide state, query_response(nil), @config

    assert_equal :retry_recovery, decision.recipe
    assert_equal :response_cat2, decision.shape
    assert_equal :recovery, decision.next_state.status
    assert_equal 4, decision.next_state.offset
    assert_equal 4, decision.next_state.recovery_offset
    assert_empty decision.instructions.grep(Instruction::RealignBuffer)
    assert decision.instructions.grep(Instruction::SendQuery).first.backoff
  end

  def test_zero_offset_realigns_to_zero
    state = recovery_state offset: 0, recovery_offset: 0
    next_state, instructions = Rules.step state, query_response("0"), @config

    assert_equal :transmission_reading, next_state.status
    assert_equal 0, next_state.offset
    assert_equal 0, instructions.grep(Instruction::RealignBuffer).first.server_offset
  end

  def test_valid_offset_is_used
    state = recovery_state offset: 4, recovery_offset: 4
    next_state, = Rules.step state, query_response(" 8 "), @config

    assert_equal 8, next_state.offset
    assert_nil next_state.recovery_offset
  end

  # --- X-Goog-Upload-Chunk-Granularity on the start answer ---

  def test_unparseable_or_zero_granularity_is_treated_as_absent
    absent_state, absent_instructions = Rules.step State.new(status: :starting), start_response(nil), @config

    (MALFORMED + ["0", "00"]).each do |value|
      next_state, instructions = Rules.step State.new(status: :starting), start_response(value), @config

      assert_nil next_state.chunk_granularity, "value #{value.inspect}"
      assert_equal absent_state, next_state, "value #{value.inspect}"
      assert_equal absent_instructions, instructions, "value #{value.inspect}"
    end
  end

  def test_valid_granularity_aligns_the_chunk_size
    next_state, = Rules.step State.new(status: :starting), start_response(" 3 "), @config

    assert_equal 3, next_state.chunk_granularity
    assert_equal 3, next_state.chunk_size
  end

  # --- Driver ---

  # A negative offset used to reach `stream.seek(-5)` and escape as `Errno::EINVAL`. It is now re-queried.
  def test_malformed_offset_is_re_queried_after_a_backoff
    outcomes = [initiation_response, http_error(503), query_answer("-5"), query_answer("0"), final_response]
    stub = FakeClientStub.new outcomes

    result, delays = run_recording_delays stub

    assert_equal '{"done":true}', result
    assert_equal [1.0], delays
    assert_equal ["start", "upload, finalize", "query", "query", "upload, finalize"], stub.commands
  end

  def test_endless_missing_offset_backs_off_until_the_deadline
    outcomes = [initiation_response, http_error(503)] + Array.new(50) { query_answer(nil) }
    stub = FakeClientStub.new outcomes

    delays = []
    clock = 0.0
    sleep_stub = lambda do |seconds|
      delays << seconds.to_f
      clock += seconds
    end
    Process.stub :clock_gettime, ->(*) { clock } do
      Kernel.stub :sleep, sleep_stub do
        assert_raises DeadlineExceededError do
          run_upload stub, timeout: 20
        end
      end
    end

    assert_equal [1.0, 2.0, 4.0, 5.0, 5.0], delays.first(5)
    refute_includes stub.commands.drop(2), "upload, finalize"
  end

  # --- UploadLog ---

  def test_wire_receive_logs_only_parseable_numeric_headers
    fields = wire_receive_fields "X-Goog-Upload-Size-Received" => "12abc", "X-Goog-Upload-Chunk-Granularity" => "-1"
    refute fields.key?("sizeReceived")
    refute fields.key?("granularity")

    fields = wire_receive_fields "X-Goog-Upload-Size-Received" => "0", "X-Goog-Upload-Chunk-Granularity" => "256"
    assert_equal 0, fields["sizeReceived"]
    assert_equal 256, fields["granularity"]
  end

  private

  def recovery_state offset:, recovery_offset:
    State.new status: :recovery, upload_url: SESSION_URL, offset: offset, chunk_size: 4,
              recovery_offset: recovery_offset
  end

  def start_response granularity, url: SESSION_URL
    headers = { "x-goog-upload-status" => "active" }
    headers["x-goog-upload-url"] = url unless url.nil?
    headers["x-goog-upload-chunk-granularity"] = granularity unless granularity.nil?
    Event::HttpResponse.new status: 200, headers: headers
  end

  def query_response received
    headers = { "x-goog-upload-status" => "active" }
    headers["x-goog-upload-size-received"] = received unless received.nil?
    Event::HttpResponse.new status: 200, headers: headers
  end

  def run_recording_delays stub
    delays = []
    result = Kernel.stub :sleep, ->(seconds) { delays << seconds.to_f } do
      run_upload stub
    end
    [result, delays]
  end

  def run_upload stub, **overrides
    config = StartUploadConfig.new(
      initial_url:                "https://example.com/upload",
      stream:                     StringIO.new("0123"),
      upload_size:                4,
      chunk_size:                 10,
      data_plane_retry_policy:    { retry_codes: [] },
      control_plane_retry_policy: BACKOFF,
      **overrides
    )
    Driver.new(client_stub: stub, config: config).run
  end

  def initiation_response
    FakeResponse.new status: 200, headers: { "X-Goog-Upload-URL" => SESSION_URL, "X-Goog-Upload-Status" => "active" },
                     body: ""
  end

  def query_answer received
    headers = { "X-Goog-Upload-Status" => "active" }
    headers["X-Goog-Upload-Size-Received"] = received unless received.nil?
    FakeResponse.new status: 200, headers: headers, body: ""
  end

  def final_response
    FakeResponse.new status: 200, headers: { "X-Goog-Upload-Status" => "final" }, body: '{"done":true}'
  end

  def http_error status
    Faraday::ServerError.new "the server responded with status #{status}", { status: status, headers: {}, body: "" }
  end

  def wire_receive_fields headers
    recording = RecordingLogger.new
    stub_logger = Gapic::LoggingConcerns::StubLogger.new logger: recording, service: "ResumableUpload"
    upload_log = Driver::UploadLog.new stub_logger, upload_id: "test-upload"
    upload_log.wire_receive Event::HttpResponse.new(status: 200, headers: headers, body: "")
    recording.entries.last.message.fields
  end
end
