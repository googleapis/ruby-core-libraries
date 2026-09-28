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
# Tests for strict parsing of the numeric protocol headers `X-Goog-Upload-Size-Received` and
# `X-Goog-Upload-Chunk-Granularity`. A malformed value is treated exactly like a missing one: the offset
# falls back to 0 and the granularity to `nil`.
#
# See `design/resumable_upload/implementation-guide.md` sections 3 and 5.
#
class HeaderParsingTest < Minitest::Test
  include Gapic::Rest::ResumableUpload

  FakeResponse = Struct.new :status, :headers, :body, keyword_init: true

  SESSION_URL = "https://example.com/session"

  # Values that must parse as if the header were absent.
  UNPARSEABLE = [nil, "", "   ", "0", "00", "-5", "+5", "1.5", "12abc", "abc", "0x10", "1e3", "1_000"].freeze

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

  # --- Rules.parse_header_positive_integer ---

  def test_parses_positive_decimal_integers
    assert_equal 123, Rules.parse_header_positive_integer("123")
    assert_equal 123, Rules.parse_header_positive_integer(" 123 ")
    assert_equal 8, Rules.parse_header_positive_integer("008")
    assert_equal 2**40, Rules.parse_header_positive_integer((2**40).to_s)
  end

  def test_rejects_everything_else
    UNPARSEABLE.each do |value|
      assert_nil Rules.parse_header_positive_integer(value), "value #{value.inspect}"
    end
  end

  # --- X-Goog-Upload-Chunk-Granularity on the start response ---

  def test_unparseable_granularity_is_treated_as_absent
    absent_state, absent_instructions = Rules.step State.new(status: :starting), start_response(nil), @config

    UNPARSEABLE.each do |value|
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

  # --- X-Goog-Upload-Size-Received on the query response ---

  def test_unparseable_offset_realigns_to_zero
    UNPARSEABLE.each do |value|
      state = State.new status: :recovery, upload_url: SESSION_URL, offset: 4, chunk_size: 4, recovery_offset: 4
      next_state, instructions = Rules.step state, query_response(value), @config

      assert_equal :transmission_reading, next_state.status, "value #{value.inspect}"
      assert_equal 0, next_state.offset, "value #{value.inspect}"
      assert_equal 4, next_state.recovery_offset, "value #{value.inspect}"
      realign = instructions.grep(Instruction::RealignBuffer).first
      assert_equal 0, realign.server_offset, "value #{value.inspect}"
      progress = instructions.grep(Instruction::NotifyProgress).first.progress
      assert_equal 0, progress.bytes_uploaded, "value #{value.inspect}"
    end
  end

  def test_trailing_garbage_does_not_yield_a_partial_offset
    state = State.new status: :recovery, upload_url: SESSION_URL, offset: 0, chunk_size: 4, recovery_offset: 0
    next_state, = Rules.step state, query_response("8abc"), @config

    assert_equal 0, next_state.offset
  end

  def test_valid_offset_is_used
    state = State.new status: :recovery, upload_url: SESSION_URL, offset: 4, chunk_size: 4, recovery_offset: 4
    next_state, = Rules.step state, query_response(" 8 "), @config

    assert_equal 8, next_state.offset
    assert_nil next_state.recovery_offset
  end

  # --- Driver ---

  # A negative offset used to reach `stream.seek(-5)` and escape as `Errno::EINVAL`. It now realigns to 0
  # and re-sends the data from the start.
  def test_negative_offset_restarts_the_upload_from_zero
    outcomes = [
      FakeResponse.new(status: 200, headers: { "X-Goog-Upload-URL" => SESSION_URL, "X-Goog-Upload-Status" => "active" },
                       body: ""),
      FakeResponse.new(status: 503, headers: {}, body: "Service Unavailable"),
      FakeResponse.new(status: 200, headers: { "X-Goog-Upload-Status" => "active", "X-Goog-Upload-Size-Received" => "-5" },
                       body: ""),
      FakeResponse.new(status: 200, headers: { "X-Goog-Upload-Status" => "final" }, body: '{"done":true}')
    ]
    stub = FakeClientStub.new outcomes
    config = StartUploadConfig.new(
      initial_url:                "https://example.com/upload",
      stream:                     StringIO.new("0123"),
      upload_size:                4,
      chunk_size:                 10,
      data_plane_retry_policy:    { retry_codes: [] },
      control_plane_retry_policy: { initial_delay: 0.01, jitter: 0 }
    )

    result = Driver.new(client_stub: stub, config: config).run

    assert_equal '{"done":true}', result
    assert_equal ["start", "upload, finalize", "query", "upload, finalize"], stub.commands
  end

  # --- UploadLog ---

  def test_wire_receive_logs_only_parseable_numeric_headers
    fields = wire_receive_fields "X-Goog-Upload-Size-Received" => "12abc", "X-Goog-Upload-Chunk-Granularity" => "-1"
    refute fields.key?("sizeReceived")
    refute fields.key?("granularity")

    fields = wire_receive_fields "X-Goog-Upload-Size-Received" => "12", "X-Goog-Upload-Chunk-Granularity" => "256"
    assert_equal 12, fields["sizeReceived"]
    assert_equal 256, fields["granularity"]
  end

  private

  def start_response granularity
    headers = { "x-goog-upload-status" => "active", "x-goog-upload-url" => SESSION_URL }
    headers["x-goog-upload-chunk-granularity"] = granularity unless granularity.nil?
    Event::HttpResponse.new status: 200, headers: headers
  end

  def query_response received
    headers = { "x-goog-upload-status" => "active" }
    headers["x-goog-upload-size-received"] = received unless received.nil?
    Event::HttpResponse.new status: 200, headers: headers
  end

  def wire_receive_fields headers
    recording = RecordingLogger.new
    stub_logger = Gapic::LoggingConcerns::StubLogger.new logger: recording, service: "ResumableUpload"
    upload_log = Driver::UploadLog.new stub_logger, upload_id: "test-upload"
    upload_log.wire_receive Event::HttpResponse.new(status: 200, headers: headers, body: "")
    recording.entries.last.message.fields
  end
end
