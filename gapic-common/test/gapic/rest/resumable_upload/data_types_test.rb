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
# Tests for data types in resumable upload.
#
class DataTypesTest < Minitest::Test
  include Gapic::Rest::ResumableUpload

  def test_start_upload_config_defaults
    stream = StringIO.new "content"
    config = StartUploadConfig.new(
      initial_url: "https://example.com",
      stream:      stream
    )

    assert_equal "https://example.com", config.initial_url
    assert_same stream, config.stream
    assert_nil config.initial_body
    assert_equal({}, config.initial_headers)
    assert_nil config.upload_size
    assert_nil config.chunk_size
    assert_nil config.content_type
    assert_nil config.timeout
    assert_nil config.start_retry_policy
    assert_nil config.control_plane_retry_policy
    assert_nil config.data_plane_retry_policy
    assert_nil config.on_progress
  end

  def test_start_upload_config_validations
    stream = StringIO.new "content"

    assert_raises ArgumentError do
      StartUploadConfig.new initial_url: nil, stream: stream
    end

    assert_raises ArgumentError do
      StartUploadConfig.new initial_url: "   ", stream: stream
    end

    assert_raises ArgumentError do
      StartUploadConfig.new initial_url: "https://example.com", stream: nil
    end
  end

  def test_start_upload_config_rejects_reserved_initial_headers
    stream = StringIO.new "content"
    reserved = ["X-Goog-Upload-Command", "x-goog-upload-command", "X-GOOG-UPLOAD-COMMAND",
                "X-Goog-Upload-Protocol", "x-goog-upload-offset",
                "X-Goog-Upload-Header-Content-Type", "x-goog-upload-header-content-length"]

    reserved.each do |header|
      error = assert_raises ArgumentError do
        StartUploadConfig.new initial_url: "https://example.com", stream: stream, initial_headers: { header => "x" }
      end
      assert_match(/must not set protocol header/, error.message)
      assert_includes error.message, header
    end
  end

  def test_start_upload_config_allows_caller_owned_initial_headers
    stream = StringIO.new "content"
    headers = {
      "Authorization" => "Bearer token",
      "X-Custom"      => "value"
    }

    config = StartUploadConfig.new initial_url: "https://example.com", stream: stream, initial_headers: headers

    assert_equal headers, config.initial_headers
  end

  def test_state_defaults_and_with
    state = State.new

    assert_equal :initializing, state.status
    assert_nil state.upload_url
    assert_equal 0, state.offset
    assert_equal 8_388_608, state.chunk_size
    assert_nil state.chunk_granularity
    assert_equal 0, state.in_flight_length
    assert_nil state.last_error

    modified = state.with status: :starting, upload_url: "https://example.com/upload"
    assert_equal :starting, modified.status
    assert_equal "https://example.com/upload", modified.upload_url
    assert_equal :initializing, state.status
  end

  def test_event_instantiation
    start_event = Event::StartUpload.new
    assert_instance_of Event::StartUpload, start_event

    chunk = Event::ChunkRead.new bytes_buffered: 100, eof: true
    assert_equal 100, chunk.bytes_buffered
    assert chunk.eof

    http = Event::HttpResponse.new status: 200, headers: { "a" => "b" }, body: "body"
    assert_equal 200, http.status
    assert_equal({ "a" => "b" }, http.headers)
    assert_equal "body", http.body

    req_fail = Event::RequestFailed.new kind: :connection_failed, message: "err"
    assert_equal :connection_failed, req_fail.kind
    assert_equal "err", req_fail.message
  end

  def test_instruction_instantiation
    start = Instruction::SendStart.new url: "https://example.com"
    assert_equal "https://example.com", start.url
    assert_equal({}, start.headers)
    assert_nil start.body

    chunk = Instruction::SendChunk.new url: "https://example.com", offset: 0, length: 100
    assert_equal 0, chunk.offset
    assert_equal 100, chunk.length
    refute chunk.finalize

    realign = Instruction::RealignBuffer.new server_offset: 500
    assert_equal 500, realign.server_offset
  end

  def test_progress_instantiation
    Progress::PHASES.each do |phase|
      progress = Progress.new phase: phase, bytes_uploaded: 512, total_bytes: 2048
      assert_equal phase, progress.phase
      assert_equal 512, progress.bytes_uploaded
      assert_equal 2048, progress.total_bytes
    end

    progress_unknown = Progress.new phase: :uploading, bytes_uploaded: 1024
    assert_equal :uploading, progress_unknown.phase
    assert_equal 1024, progress_unknown.bytes_uploaded
    assert_nil progress_unknown.total_bytes

    assert_raises ArgumentError do
      Progress.new bytes_uploaded: 512, total_bytes: 2048
    end

    assert_raises ArgumentError do
      Progress.new phase: :invalid_phase, bytes_uploaded: 512, total_bytes: 2048
    end
  end

  def test_resume_handle_instantiation
    handle = ResumeHandle.new upload_url: "https://upload.example.com/session123", chunk_size: 1_048_576
    assert_equal "https://upload.example.com/session123", handle.upload_url
    assert_equal 1_048_576, handle.chunk_size

    assert_raises ArgumentError do
      ResumeHandle.new upload_url: "https://upload.example.com/session123"
    end

    assert_raises NoMethodError do
      handle.upload_url = "https://mutated.com"
    end
  end

  def test_resume_upload_config_defaults
    stream = StringIO.new "content"
    config = ResumeUploadConfig.new(
      upload_url: "https://upload.example.com/session1",
      chunk_size: 1024,
      stream:     stream
    )

    assert_equal "https://upload.example.com/session1", config.upload_url
    assert_equal 1024, config.chunk_size
    assert_same stream, config.stream
    assert_nil config.upload_size
    assert_nil config.content_type
    assert_nil config.timeout
    refute_respond_to config, :start_retry_policy
    assert_nil config.control_plane_retry_policy
    assert_nil config.data_plane_retry_policy
    assert_nil config.on_progress
  end

  def test_resume_upload_config_validations
    stream = StringIO.new "content"

    assert_raises ArgumentError do
      ResumeUploadConfig.new upload_url: nil, chunk_size: 1024, stream: stream
    end

    assert_raises ArgumentError do
      ResumeUploadConfig.new upload_url: "   ", chunk_size: 1024, stream: stream
    end

    assert_raises ArgumentError do
      ResumeUploadConfig.new upload_url: "https://example.com", chunk_size: 0, stream: stream
    end

    assert_raises ArgumentError do
      ResumeUploadConfig.new upload_url: "https://example.com", chunk_size: -10, stream: stream
    end

    assert_raises ArgumentError do
      ResumeUploadConfig.new upload_url: "https://example.com", chunk_size: "1024", stream: stream
    end

    assert_raises ArgumentError do
      ResumeUploadConfig.new upload_url: "https://example.com", chunk_size: 1024, stream: nil
    end
  end
end
