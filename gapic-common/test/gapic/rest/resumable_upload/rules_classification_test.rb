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

##
# Tests for classification and header extraction rules in the Resumable Upload protocol.
#
class RulesClassificationTest < Minitest::Test
  include Gapic::Rest::ResumableUpload

  def test_header_value_exact_match
    headers = { "X-Goog-Upload-Status" => "active" }
    assert_equal "active", Rules.header_value(headers, "X-Goog-Upload-Status")
  end

  def test_header_value_case_insensitivity
    assert_equal "active", Rules.header_value({ "x-goog-upload-status" => "active" }, "X-Goog-Upload-Status")
    assert_equal "active", Rules.header_value({ "X-GOOG-UPLOAD-STATUS" => "active" }, "X-Goog-Upload-Status")
    assert_equal "active", Rules.header_value({ "x-Goog-UpLoad-Status" => "active" }, "X-Goog-Upload-Status")
  end

  def test_header_value_with_symbol_keys
    headers = { :"x-goog-upload-status" => "active" }
    assert_equal "active", Rules.header_value(headers, "X-Goog-Upload-Status")
  end

  def test_header_value_missing_or_non_hash
    assert_nil Rules.header_value({ "Content-Type" => "text/plain" }, "X-Goog-Upload-Status")
    assert_nil Rules.header_value(nil, "X-Goog-Upload-Status")
    assert_nil Rules.header_value([], "X-Goog-Upload-Status")
    assert_nil Rules.header_value("string", "X-Goog-Upload-Status")
  end

  def test_classify_http_response_active
    resp_200 = Event::HttpResponse.new status: 200, headers: { "X-Goog-Upload-Status" => "active" }, body: ""
    assert_equal :response_active, Rules.classify_http_response(resp_200)

    # Value case variations
    ["Active", "ACTIVE", "aCtIvE"].each do |val|
      resp = Event::HttpResponse.new status: 200, headers: { "X-Goog-Upload-Status" => val }, body: ""
      assert_equal :response_active, Rules.classify_http_response(resp)
    end

    # Non-200 with active maps to Category 2
    [503, 500, 400, 408].each do |code|
      resp_non_200 = Event::HttpResponse.new status: code, headers: { "X-Goog-Upload-Status" => "active" }, body: ""
      assert_equal :response_cat2, Rules.classify_http_response(resp_non_200)
    end
  end

  def test_classify_http_response_final
    resp_200 = Event::HttpResponse.new status: 200, headers: { "X-Goog-Upload-Status" => "final" }, body: ""
    assert_equal :response_final, Rules.classify_http_response(resp_200)

    # Value case variations
    ["Final", "FINAL"].each do |val|
      resp = Event::HttpResponse.new status: 200, headers: { "X-Goog-Upload-Status" => val }, body: ""
      assert_equal :response_final, Rules.classify_http_response(resp)
    end

    # Non-200 with final maps to response_rejected
    [400, 404, 500].each do |code|
      resp_non_200 = Event::HttpResponse.new status: code, headers: { "X-Goog-Upload-Status" => "final" }, body: ""
      assert_equal :response_rejected, Rules.classify_http_response(resp_non_200)
    end
  end

  def test_classify_http_response_cancelled
    resp_200 = Event::HttpResponse.new status: 200, headers: { "X-Goog-Upload-Status" => "cancelled" }, body: ""
    assert_equal :response_cancelled, Rules.classify_http_response(resp_200)

    # Value case variations
    ["Cancelled", "CANCELLED"].each do |val|
      resp = Event::HttpResponse.new status: 200, headers: { "X-Goog-Upload-Status" => val }, body: ""
      assert_equal :response_cancelled, Rules.classify_http_response(resp)
    end

    # Non-200 with cancelled maps to fatal bad response
    [400, 500].each do |code|
      resp_non_200 = Event::HttpResponse.new status: code, headers: { "X-Goog-Upload-Status" => "cancelled" }, body: ""
      assert_equal :response_fatal_bad_response, Rules.classify_http_response(resp_non_200)
    end
  end

  def test_classify_http_response_missing_header_non_fatal
    # HTTP 200 missing header
    resp_200 = Event::HttpResponse.new status: 200, headers: {}, body: ""
    assert_equal :response_cat2, Rules.classify_http_response(resp_200)

    # Recoverable 4xx missing header
    Rules::CAT2_STATUS_CODES.each do |code|
      resp = Event::HttpResponse.new status: code, headers: {}, body: ""
      assert_equal :response_cat2, Rules.classify_http_response(resp), "Expected #{code} to classify as :response_cat2"
    end

    # 5xx server/gateway errors missing header
    [500, 502, 503, 504].each do |code|
      resp = Event::HttpResponse.new status: code, headers: {}, body: ""
      assert_equal :response_cat2, Rules.classify_http_response(resp), "Expected #{code} to classify as :response_cat2"
    end

    # Empty string header
    resp_empty = Event::HttpResponse.new status: 200, headers: { "X-Goog-Upload-Status" => "" }, body: ""
    assert_equal :response_cat2, Rules.classify_http_response(resp_empty)
  end

  def test_classify_http_response_missing_header_fatal_status_codes
    Rules::FATAL_STATUS_CODES.each do |code|
      resp = Event::HttpResponse.new status: code, headers: {}, body: ""
      assert_equal :response_fatal_bad_response, Rules.classify_http_response(resp),
                   "Expected fatal code #{code} to classify as :response_fatal_bad_response"

      resp_empty = Event::HttpResponse.new status: code, headers: { "X-Goog-Upload-Status" => "" }, body: ""
      assert_equal :response_fatal_bad_response, Rules.classify_http_response(resp_empty),
                   "Expected fatal code #{code} with empty header to classify as :response_fatal_bad_response"
    end
  end

  def test_classify_http_response_unknown_header_values
    ["absconded", "pending", "in_progress", "error", "unknown"].each do |unknown_val|
      resp_200 = Event::HttpResponse.new status: 200, headers: { "X-Goog-Upload-Status" => unknown_val }, body: ""
      assert_equal :response_fatal_bad_response, Rules.classify_http_response(resp_200)

      resp_400 = Event::HttpResponse.new status: 400, headers: { "X-Goog-Upload-Status" => unknown_val }, body: ""
      assert_equal :response_fatal_bad_response, Rules.classify_http_response(resp_400)
    end
  end

  def test_classify_http_response_header_key_casing
    keys = ["x-goog-upload-status", "X-GOOG-UPLOAD-STATUS", "X-Goog-Upload-Status", :"x-goog-upload-status"]
    keys.each do |key|
      resp = Event::HttpResponse.new status: 200, headers: { key => "active" }, body: ""
      assert_equal :response_active, Rules.classify_http_response(resp)
    end
  end

  def test_shape_of_control_events
    assert_equal :start_upload, Rules.shape_of(Event::StartUpload.new)
    assert_equal :start_upload, Rules.shape_of(Event::StartUpload)
    assert_equal :resume_upload, Rules.shape_of(Event::ResumeUpload.new)
    assert_equal :resume_upload, Rules.shape_of(Event::ResumeUpload)
    assert_equal :user_cancel, Rules.shape_of(Event::Cancel.new)
    assert_equal :user_cancel, Rules.shape_of(Event::Cancel)
    assert_equal :global_deadline_exceeded, Rules.shape_of(Event::GlobalDeadlineExceeded.new)
    assert_equal :global_deadline_exceeded, Rules.shape_of(Event::GlobalDeadlineExceeded)
  end

  def test_shape_of_chunk_read
    full_chunk = Event::ChunkRead.new bytes_buffered: 4096, eof: false
    assert_equal :chunk_read_full, Rules.shape_of(full_chunk)

    eof_data = Event::ChunkRead.new bytes_buffered: 1024, eof: true
    assert_equal :chunk_read_eof_with_data, Rules.shape_of(eof_data)

    eof_empty = Event::ChunkRead.new bytes_buffered: 0, eof: true
    assert_equal :chunk_read_eof_empty, Rules.shape_of(eof_empty)
  end

  def test_shape_of_request_failed
    timeout = Event::RequestFailed.new kind: :timeout, message: "read timeout"
    assert_equal :request_timeout, Rules.shape_of(timeout)

    exhausted = Event::RequestFailed.new kind: :retries_exhausted, message: "exhausted"
    assert_equal :request_retries_exhausted, Rules.shape_of(exhausted)

    conn_failed = Event::RequestFailed.new kind: :connection_failed, message: "dropped"
    assert_equal :request_connection_failed, Rules.shape_of(conn_failed)

    other = Event::RequestFailed.new kind: :other, message: "unknown error"
    assert_equal :request_failed_unknown, Rules.shape_of(other)
  end

  def test_shape_of_http_response_delegates_to_classify
    resp = Event::HttpResponse.new status: 200, headers: { "X-Goog-Upload-Status" => "active" }, body: ""
    assert_equal :response_active, Rules.shape_of(resp)
  end

  def test_shape_of_unknown_event
    assert_equal :unknown, Rules.shape_of(Object.new)
    assert_equal :unknown, Rules.shape_of(nil)
    assert_equal :unknown, Rules.shape_of("unrecognized_event")
  end

  ##
  # One event per shape Rules can produce. Used to check SHAPES in both directions, so that a new shape must
  # be added to the constant and a retired shape must be removed from it.
  #
  def shape_corpus
    active = { "X-Goog-Upload-Status" => "active" }
    final = { "X-Goog-Upload-Status" => "final" }
    cancelled = { "X-Goog-Upload-Status" => "cancelled" }
    {
      start_upload:                Event::StartUpload.new,
      resume_upload:               Event::ResumeUpload.new,
      user_cancel:                 Event::Cancel.new,
      global_deadline_exceeded:    Event::GlobalDeadlineExceeded.new,
      chunk_read_full:             Event::ChunkRead.new(bytes_buffered: 4096, eof: false),
      chunk_read_eof_with_data:    Event::ChunkRead.new(bytes_buffered: 1024, eof: true),
      chunk_read_eof_empty:        Event::ChunkRead.new(bytes_buffered: 0, eof: true),
      request_timeout:             Event::RequestFailed.new(kind: :timeout),
      request_retries_exhausted:   Event::RequestFailed.new(kind: :retries_exhausted),
      request_connection_failed:   Event::RequestFailed.new(kind: :connection_failed),
      request_failed_unknown:      Event::RequestFailed.new(kind: :something_else),
      response_active:             Event::HttpResponse.new(status: 200, headers: active),
      response_final:              Event::HttpResponse.new(status: 200, headers: final),
      response_cancelled:          Event::HttpResponse.new(status: 200, headers: cancelled),
      response_rejected:           Event::HttpResponse.new(status: 400, headers: final),
      response_cat2:               Event::HttpResponse.new(status: 200, headers: {}),
      response_fatal_bad_response: Event::HttpResponse.new(status: 401, headers: {}),
      unknown:                     Object.new
    }
  end

  def test_shapes_constant_is_exhaustive_and_minimal
    corpus = shape_corpus

    corpus.each do |expected_shape, event|
      assert_equal expected_shape, Rules.shape_of(event),
                   "Corpus event for #{expected_shape} no longer classifies as that shape"
    end

    assert_empty Rules::SHAPES - corpus.keys,
                 "SHAPES members that no corpus event produces (phantom or untested shapes)"
    assert_empty corpus.keys - Rules::SHAPES,
                 "shape_of produces shapes that are missing from SHAPES"
    assert_predicate Rules::SHAPES, :frozen?
  end

  def test_statuses_tracks_state_descriptions
    assert_empty Rules::STATUSES - Rules::STATE_DESCRIPTIONS.keys,
                 "status missing a description"
    assert_empty Rules::STATE_DESCRIPTIONS.keys - Rules::STATUSES,
                 "description for unknown status"
    assert_equal Rules::STATUSES.uniq, Rules::STATUSES
    assert_predicate Rules::STATUSES, :frozen?

    assert_empty Rules::TERMINAL_STATUSES - Rules::STATUSES,
                 "TERMINAL_STATUSES contains statuses outside STATUSES"
    assert_predicate Rules::TERMINAL_STATUSES, :frozen?
  end

  def test_resume_handle_from_returns_nil_for_all_terminal_statuses_except_error
    base_state = State.new upload_url: "https://example.com/session/123", chunk_size: 262_144

    Rules::TERMINAL_STATUSES.each do |terminal_status|
      state = base_state.with status: terminal_status
      handle = Rules.resume_handle_from state
      if terminal_status == :error
        refute_nil handle, "Expected resume_handle_from to return a ResumeHandle for :error status"
      else
        assert_nil handle, "Expected resume_handle_from to return nil for terminal status #{terminal_status.inspect}"
      end
    end
  end

  def test_decide_rejects_a_shape_outside_the_vocabulary
    state = State.new
    config = StartUploadConfig.new initial_url: "https://example.com/upload", stream: StringIO.new("data")

    error = Rules.stub :shape_of, :not_a_real_shape do
      assert_raises InternalError do
        Rules.decide state, Event::StartUpload.new, config
      end
    end

    assert_match(/Resumable upload internal error: shape_of returned unknown shape :not_a_real_shape/, error.message)
  end

  def test_decide_rejects_a_recipe_outside_the_vocabulary
    state = State.new
    config = StartUploadConfig.new initial_url: "https://example.com/upload", stream: StringIO.new("data")
    original_recipes = Rules::RECIPES

    error = begin
      Rules.send :remove_const, :RECIPES
      Rules.const_set :RECIPES, [].freeze
      assert_raises InternalError do
        Rules.decide state, Event::StartUpload.new, config
      end
    ensure
      Rules.send :remove_const, :RECIPES
      Rules.const_set :RECIPES, original_recipes
    end

    assert_match(/Resumable upload internal error: decide selected unknown recipe :start_session/, error.message)
  end

  def test_resolve_chunk_size
    # nil or non-positive granularity keeps user or default chunk size
    assert_equal 1024, Rules.resolve_chunk_size(1024, nil)
    assert_equal Rules::DEFAULT_CHUNK_SIZE, Rules.resolve_chunk_size(nil, nil)
    assert_equal 1024, Rules.resolve_chunk_size(1024, 0)
    assert_equal Rules::DEFAULT_CHUNK_SIZE, Rules.resolve_chunk_size(nil, -1)

    # Exact multiple (including equality) is preserved
    assert_equal 1024, Rules.resolve_chunk_size(1024, 256)
    assert_equal 256, Rules.resolve_chunk_size(256, 256)
    assert_equal 8_388_608, Rules.resolve_chunk_size(nil, 262_144)

    # Non-multiple rounds down to nearest multiple of granularity
    assert_equal 768, Rules.resolve_chunk_size(1000, 256)
    assert_equal 8_000_000, Rules.resolve_chunk_size(nil, 500_000)

    # Chunk size smaller than granularity promotes to granularity
    assert_equal 256, Rules.resolve_chunk_size(100, 256)
    assert_equal 16_777_216, Rules.resolve_chunk_size(nil, 16_777_216)
  end
end
