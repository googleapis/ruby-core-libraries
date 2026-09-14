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

require "integration_helper"
require "json"
require "stringio"

##
# Suite D: Integration tests for Resumable Upload Session resumption against Showcase.
#
class ResumeTest < ShowcaseIntegrationTest
  ##
  # Custom error to simulate a user aborting an in-progress transfer from inside on_progress.
  #
  class UserPauseError < StandardError
    attr_reader :resume_handle

    def initialize message, resume_handle
      super message
      @resume_handle = resume_handle
    end
  end

  # D1. Resume an in-progress upload on a seekable stream.
  def test_resume_in_progress_upload
    upload_url = raw_start upload_size: DEFAULT_PAYLOAD_SIZE
    chunk1 = payload(DEFAULT_PAYLOAD_SIZE).byteslice 0, DEFAULT_CHUNK_SIZE
    raw_upload upload_url: upload_url, offset: 0, bytes: chunk1, finalize: false

    session = build_session
    result = session.resume upload_url: upload_url, chunk_size: DEFAULT_CHUNK_SIZE
    parsed = JSON.parse result

    assert_equal DEFAULT_PAYLOAD_SIZE, parsed["size"]
    assert_equal [:initiating, :uploading, :uploading, :uploading, :finalizing, :completed], phases
    assert_equal [0, 262_144, 524_288, 786_432, 786_432, 786_432], offsets
  end

  # D2. Resuming an already-finalized upload terminates cleanly and returns final body.
  def test_resume_finalized_upload
    upload_url = raw_start upload_size: DEFAULT_CHUNK_SIZE
    raw_upload upload_url: upload_url, offset: 0, bytes: payload(DEFAULT_CHUNK_SIZE), finalize: true

    session = build_session stream: StringIO.new(payload(DEFAULT_CHUNK_SIZE)), upload_size: DEFAULT_CHUNK_SIZE
    result = session.resume upload_url: upload_url, chunk_size: DEFAULT_CHUNK_SIZE
    parsed = JSON.parse result

    assert_equal DEFAULT_CHUNK_SIZE, parsed["size"]
    assert_equal [:initiating, :completed], phases
  end

  # D3a. Non-fatal 503 error on query during resume is absorbed by control plane retry policy.
  def test_resume_query_503_absorbed_by_retry
    upload_url = raw_start(
      scenario:        "non_fatal_error_on_query",
      scenario_config: { error_code: 503, failure_count: 1 },
      upload_size:     DEFAULT_PAYLOAD_SIZE
    )
    chunk1 = payload(DEFAULT_PAYLOAD_SIZE).byteslice 0, DEFAULT_CHUNK_SIZE
    raw_upload upload_url: upload_url, offset: 0, bytes: chunk1, finalize: false

    session = build_session
    result = session.resume upload_url: upload_url, chunk_size: DEFAULT_CHUNK_SIZE
    parsed = JSON.parse result

    assert_equal DEFAULT_PAYLOAD_SIZE, parsed["size"]
    assert_equal [:initiating, :uploading, :uploading, :uploading, :finalizing, :completed], phases
    refute_includes @log_output.string, "retry_recovery"
  end

  # D3b. Non-fatal 409 error on query during resume triggers protocol retry_recovery without progress notification.
  def test_resume_query_409_triggers_retry_recovery
    upload_url = raw_start(
      scenario:        "non_fatal_error_on_query",
      scenario_config: { error_code: 409, failure_count: 1 },
      upload_size:     DEFAULT_PAYLOAD_SIZE
    )
    chunk1 = payload(DEFAULT_PAYLOAD_SIZE).byteslice 0, DEFAULT_CHUNK_SIZE
    raw_upload upload_url: upload_url, offset: 0, bytes: chunk1, finalize: false

    session = build_session
    result = session.resume upload_url: upload_url, chunk_size: DEFAULT_CHUNK_SIZE
    parsed = JSON.parse result

    assert_equal DEFAULT_PAYLOAD_SIZE, parsed["size"]
    assert_equal [:initiating, :uploading, :uploading, :uploading, :finalizing, :completed], phases
    refute_includes phases, :recovering
    assert_includes @log_output.string, "retry_recovery"
  end

  # D4. Resume fast-forwards by discarding bytes on an unseekable stream starting at byte 0.
  def test_resume_unseekable_stream_fast_forwards
    upload_url = raw_start upload_size: DEFAULT_PAYLOAD_SIZE
    chunk1 = payload(DEFAULT_PAYLOAD_SIZE).byteslice 0, DEFAULT_CHUNK_SIZE
    raw_upload upload_url: upload_url, offset: 0, bytes: chunk1, finalize: false

    stream = UnseekableStream.new payload(DEFAULT_PAYLOAD_SIZE)
    session = build_session stream: stream
    result = session.resume upload_url: upload_url, chunk_size: DEFAULT_CHUNK_SIZE
    parsed = JSON.parse result

    assert_equal DEFAULT_PAYLOAD_SIZE, parsed["size"]
    assert_equal [:initiating, :uploading, :uploading, :uploading, :finalizing, :completed], phases
    assert_equal [0, 262_144, 524_288, 786_432, 786_432, 786_432], offsets
  end

  # D5a. Resume with unseekable stream shorter than acknowledged server offset raises StreamMismatchError.
  def test_resume_wrong_stream_unseekable_mismatch
    upload_url = raw_start upload_size: DEFAULT_CHUNK_SIZE
    raw_upload upload_url: upload_url, offset: 0, bytes: payload(DEFAULT_CHUNK_SIZE), finalize: false

    stream = UnseekableStream.new payload(100)
    session = build_session stream: stream, upload_size: nil

    assert_raises Gapic::Rest::ResumableUpload::StreamMismatchError do
      session.resume upload_url: upload_url, chunk_size: DEFAULT_CHUNK_SIZE
    end
    refute_includes phases, :finalizing
  end

  # D5b. Resume with seekable stream shorter than server offset raises StreamMismatchError via stream.size guard.
  def test_resume_wrong_stream_seekable_size_guard
    upload_url = raw_start upload_size: DEFAULT_CHUNK_SIZE
    raw_upload upload_url: upload_url, offset: 0, bytes: payload(DEFAULT_CHUNK_SIZE), finalize: false

    stream = StringIO.new payload(100)
    session = build_session stream: stream, upload_size: nil

    assert_raises Gapic::Rest::ResumableUpload::StreamMismatchError do
      session.resume upload_url: upload_url, chunk_size: DEFAULT_CHUNK_SIZE
    end
    refute_includes phases, :finalizing
  end

  # D6a. Golden user-style resume on a seekable stream after user abort in on_progress.
  def test_golden_user_style_resume_seekable
    stream = StringIO.new payload(DEFAULT_PAYLOAD_SIZE)
    session1 = nil
    on_progress = lambda do |progress|
      if progress.phase == :uploading && progress.bytes_uploaded == DEFAULT_CHUNK_SIZE
        raise UserPauseError.new("user paused", session1.resume_handle)
      end
    end

    session1 = build_session stream: stream, on_progress: on_progress
    err = assert_raises UserPauseError do
      start_session session1
    end

    assert session1.bound?
    assert session1.resumable?
    handle = err.resume_handle
    refute_nil handle

    stream.rewind
    session2 = build_session stream: stream
    result = session2.resume resume_handle: handle
    parsed = JSON.parse result

    assert_equal DEFAULT_PAYLOAD_SIZE, parsed["size"]
    assert session2.bound?
    refute session2.resumable?
  end

  # D6b. Golden user-style resume with a fresh unseekable stream starting at byte 0.
  def test_golden_user_style_resume_unseekable
    session1 = nil
    on_progress = lambda do |progress|
      if progress.phase == :uploading && progress.bytes_uploaded == DEFAULT_CHUNK_SIZE
        raise UserPauseError.new("user paused", session1.resume_handle)
      end
    end

    session1 = build_session stream: UnseekableStream.new(payload(DEFAULT_PAYLOAD_SIZE)), on_progress: on_progress
    err = assert_raises UserPauseError do
      start_session session1
    end

    assert session1.bound?
    assert session1.resumable?
    handle = err.resume_handle
    refute_nil handle

    session2 = build_session stream: UnseekableStream.new(payload(DEFAULT_PAYLOAD_SIZE))
    result = session2.resume resume_handle: handle
    parsed = JSON.parse result

    assert_equal DEFAULT_PAYLOAD_SIZE, parsed["size"]
    assert session2.bound?
    refute session2.resumable?
  end

  # D7. Lifecycle and contract violations on session runs.
  def test_lifecycle_violations
    session = build_session stream: StringIO.new(payload(100)), upload_size: 100
    start_session session

    assert session.bound?

    # Second start on executed session raises SessionStateError
    assert_raises Gapic::Rest::ResumableUpload::SessionStateError do
      start_session session
    end

    # Resume on already bound/executed session raises SessionStateError
    assert_raises Gapic::Rest::ResumableUpload::SessionStateError do
      session.resume upload_url: "https://example.com/test", chunk_size: DEFAULT_CHUNK_SIZE
    end

    # Resume without parameters on fresh session raises ArgumentError
    fresh_session = build_session
    assert_raises ArgumentError do
      fresh_session.resume
    end
  end
end
