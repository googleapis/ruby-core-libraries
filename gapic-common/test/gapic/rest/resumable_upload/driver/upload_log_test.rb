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
# Unit tests for Gapic::Rest::ResumableUpload::Driver::UploadLog.
#
class UploadLogTest < Minitest::Test
  include Gapic::Rest::ResumableUpload

  def setup
    @recording = RecordingLogger.new
    stub_logger = Gapic::LoggingConcerns::StubLogger.new logger: @recording, service: "ResumableUpload"
    @upload_log = Driver::UploadLog.new stub_logger, upload_id: "test-upload-id"
    @config = StartUploadConfig.new initial_url: "https://example.com/upload",
                                       initial_body: nil,
                                       initial_headers: {},
                                       stream: StringIO.new("data"),
                                       upload_size: 1024,
                                       chunk_size: 256,
                                       content_type: "text/plain",
                                       timeout: nil,
                                       start_retry_policy: nil,
                                       control_plane_retry_policy: nil,
                                       data_plane_retry_policy: nil,
                                       on_progress: nil
  end

  def test_decision_logs_debug_with_fields_from_rules_decide
    decision = Rules.decide State.new(status: :initializing), Event::StartUpload.new, @config

    @upload_log.decision decision

    assert_equal 1, @recording.entries.size
    entry = @recording.entries.first
    assert_equal Logger::DEBUG, entry.severity
    fields = entry.message.fields
    assert_equal "test-upload-id", fields["uploadId"]
    assert_equal "initializing", fields["fromStatus"]
    assert_equal "start_upload", fields["shape"]
    assert_equal "start_session", fields["recipe"]
    assert_equal "starting", fields["toStatus"]
    assert_equal 0, fields["offset"]
    assert_equal 0, fields["inFlightLength"]
    assert_equal [
      { "type" => "NotifyProgress", "phase" => "initiating", "bytesUploaded" => 0, "totalBytes" => 1024 },
      { "type" => "SendStart", "url" => "https://example.com/upload" }
    ], fields["instructions"]
  end

  def test_lifecycle_start_session_logs_info
    decision = Rules.decide State.new(status: :initializing), Event::StartUpload.new, @config

    @upload_log.lifecycle decision, @config

    entry = @recording.entries.first
    assert_equal Logger::INFO, entry.severity
    fields = entry.message.fields
    assert_equal "start_session", fields["recipe"]
    assert_equal 1024, fields["uploadSize"]
    assert_equal 256, fields["requestedChunkSize"]
  end

  def test_lifecycle_send_chunk_logs_debug
    state = State.new status: :transmission_reading, upload_url: "https://example.com/session", offset: 0, chunk_size: 256
    event = Event::ChunkRead.new bytes_buffered: 256, eof: false
    decision = Rules.decide state, event, @config

    @upload_log.lifecycle decision, @config

    entry = @recording.entries.first
    assert_equal Logger::DEBUG, entry.severity
    fields = entry.message.fields
    assert_equal "send_chunk", fields["recipe"]
    assert_equal 0, fields["offset"]
    assert_equal 256, fields["inFlightLength"]
  end

  def test_lifecycle_terminal_failure_logs_warn
    state = State.new status: :starting
    event = Event::HttpResponse.new status: 403, headers: { "x-goog-upload-status" => "final" }, body: "Forbidden"
    decision = Rules.decide state, event, @config

    @upload_log.lifecycle decision, @config

    entry = @recording.entries.first
    assert_equal Logger::WARN, entry.severity
    fields = entry.message.fields
    assert_equal "fail_with_rejected", fields["recipe"]
    assert_includes fields["error"], "Forbidden"
  end

  def test_lifecycle_silent_recipes_emit_no_logs
    state = State.new status: :cancelling
    decision = Rules.decide state, Event::Cancel.new, @config
    assert_equal :ignore_duplicate_cancel, decision.recipe

    @upload_log.lifecycle decision, @config

    assert_empty @recording.entries
  end

  def test_lifecycle_table_matches_rules_recipes
    lifecycle_keys = Driver::UploadLog::LIFECYCLE.keys
    silent_keys = Driver::UploadLog::SILENT_RECIPES
    all_upload_log_recipes = lifecycle_keys + silent_keys

    assert_empty Rules::RECIPES - all_upload_log_recipes,
                 "Rules recipes not covered by UploadLog::LIFECYCLE or SILENT_RECIPES"
    assert_empty all_upload_log_recipes - Rules::RECIPES,
                 "Extra recipes in UploadLog::LIFECYCLE or SILENT_RECIPES not in Rules::RECIPES"
    assert_empty lifecycle_keys & silent_keys,
                 "Recipes present in both UploadLog::LIFECYCLE and SILENT_RECIPES"
  end

  def test_wire_send_logs_debug_with_start_attempt_and_hex_body
    @upload_log.wire_send method: "POST",
                          url: "https://example.com/session?key=SECRET",
                          headers: {
                            "X-Goog-Upload-Command" => "upload",
                            "X-Goog-Upload-Offset"  => "256",
                            "Authorization"         => "Bearer SECRET"
                          },
                          start_attempt: 2,
                          body_size: 4,
                          body: "test"

    entry = @recording.entries.first
    assert_equal Logger::DEBUG, entry.severity
    fields = entry.message.fields
    assert_equal "POST", fields["method"]
    assert_equal "upload", fields["command"]
    assert_equal 256, fields["offset"]
    assert_equal "https://example.com/session?key=<...>", fields["url"]
    assert_equal 2, fields["startAttempt"]
    assert_equal 4, fields["bodySize"]
    assert_equal "74657374", fields["body"]
    assert_equal "<...>", fields["headers"]["Authorization"]
    assert_equal "upload", fields["headers"]["X-Goog-Upload-Command"]
  end

  def test_wire_receive_logs_debug
    event = Event::HttpResponse.new status: 200,
                                    headers: {
                                      "X-Goog-Upload-Status"            => "active",
                                      "X-Goog-Upload-Size-Received"     => "256",
                                      "X-Goog-Upload-Chunk-Granularity" => "256"
                                    },
                                    body: "ok"

    @upload_log.wire_receive event

    entry = @recording.entries.first
    assert_equal Logger::DEBUG, entry.severity
    fields = entry.message.fields
    assert_equal 200, fields["status"]
    assert_equal "active", fields["uploadStatus"]
    assert_equal 256, fields["sizeReceived"]
    assert_equal 256, fields["granularity"]
    assert_equal "6f6b", fields["body"]
  end

  def test_wire_failure_logs_debug
    event = Event::RequestFailed.new kind: :timeout, message: "timed out"

    @upload_log.wire_failure event

    entry = @recording.entries.first
    assert_equal Logger::DEBUG, entry.severity
    fields = entry.message.fields
    assert_equal "timeout", fields["kind"]
  end

  def test_buffer_realign_logs_warn_and_debug_on_unseekable_rewind
    @upload_log.buffer_realign "rewind", server_offset: 0, current_offset: 256, unseekable: true

    assert_equal 2, @recording.entries.size
    warn_entry, debug_entry = @recording.entries
    assert_equal Logger::WARN, warn_entry.severity
    assert_equal "rewind", warn_entry.message.fields["action"]
    assert_equal 0, warn_entry.message.fields["serverOffset"]
    assert_equal 256, warn_entry.message.fields["currentOffset"]

    assert_equal Logger::DEBUG, debug_entry.severity
  end

  def test_unmatched_transition_logs_warn
    state = State.new status: :initializing
    event = Event::HttpResponse.new status: 200, headers: {}, body: ""
    err = InvalidTransitionError.new "no transition"

    @upload_log.unmatched_transition state, event, err

    entry = @recording.entries.first
    assert_equal Logger::WARN, entry.severity
    fields = entry.message.fields
    assert_equal "initializing", fields["status"]
    assert_equal "no transition", fields["error"]
  end
end
