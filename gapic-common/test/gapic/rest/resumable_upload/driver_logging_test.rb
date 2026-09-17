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
require "google/rpc/error_details_pb"

##
# Integration and unit tests for Driver logging concerns.
#
class DriverLoggingTest < Minitest::Test
  include Gapic::Rest::ResumableUpload

  FakeResponse = Struct.new :status, :headers, :body

  class FakeStub
    attr_reader :method_names

    def initialize responses
      @responses = responses
      @method_names = []
    end

    def endpoint
      "https://storage.googleapis.com"
    end

    def make_post_request uri:, body:, params:, options:, method_name: nil
      _ = uri
      _ = body
      _ = params
      _ = options
      @method_names << method_name
      resp = @responses.shift
      raise resp if resp.is_a?(Exception) || (resp.is_a?(Class) && resp < Exception)

      resp
    end
  end

  def test_all_entries_share_upload_id_and_pass_method_names
    recording = RecordingLogger.new
    responses = [
      FakeResponse.new(
        200,
        {
          "X-Goog-Upload-Status" => "active",
          "X-Goog-Upload-URL"    => "https://storage.googleapis.com/session?id=123"
        },
        ""
      ),
      FakeResponse.new(
        200,
        { "X-Goog-Upload-Status" => "final" },
        "done"
      )
    ]

    stub = FakeStub.new responses
    config = StartUploadConfig.new(
      initial_url: "https://storage.googleapis.com/upload",
      stream:      StringIO.new("hello world"),
      upload_size: 11,
      chunk_size:  256
    )

    driver = Driver.new client_stub: stub, config: config, logger: recording
    driver.run

    refute_empty recording.entries
    upload_ids = recording.entries.map { |e| e.message.fields["uploadId"] }.uniq
    assert_equal 1, upload_ids.size
    refute_nil upload_ids.first

    assert_equal ["ResumableUpload.start", "ResumableUpload.upload"], stub.method_names

    info_recipes = recording.entries.select { |e| e.severity == Logger::INFO }.map { |e| e.message.fields["recipe"] }
    assert_includes ["complete_upload_with_data", "complete_upload_finalized"], info_recipes.last
  end

  def test_method_name_prefixes_per_request_log_names
    responses = [
      FakeResponse.new(
        200,
        {
          "X-Goog-Upload-Status" => "active",
          "X-Goog-Upload-URL"    => "https://storage.googleapis.com/session?id=123"
        },
        ""
      ),
      FakeResponse.new(200, { "X-Goog-Upload-Status" => "final" }, "done")
    ]

    stub = FakeStub.new responses
    config = StartUploadConfig.new(
      initial_url: "https://storage.googleapis.com/upload",
      stream:      StringIO.new("hello world"),
      upload_size: 11,
      chunk_size:  256
    )

    driver = Driver.new client_stub: stub, config: config, logger: RecordingLogger.new,
                        method_name: "create_media_upload"
    driver.run

    assert_equal ["create_media_upload.start", "create_media_upload.upload"], stub.method_names
  end

  def test_multi_chunk_upload_logs_lifecycle_entries
    recording = RecordingLogger.new
    run_two_chunk_upload_with_secret recording

    info_recipes = recording.entries.select { |e| e.severity == Logger::INFO }.map { |e| e.message.fields["recipe"] }
    refute_includes info_recipes, "ack_chunk"
    assert_includes info_recipes, "start_session"
    assert_includes info_recipes, "begin_transmission"
    assert(info_recipes.any? { |r| ["complete_upload_with_data", "complete_upload_finalized"].include? r })
  end

  def test_recovery_scenario_logs_enter_recovery_and_realign
    recording = RecordingLogger.new
    responses = [
      FakeResponse.new(
        200,
        {
          "X-Goog-Upload-Status" => "active",
          "X-Goog-Upload-URL"    => "https://storage.googleapis.com/session?id=123"
        },
        ""
      ),
      FakeResponse.new(503, {}, "Service Unavailable"),
      FakeResponse.new(
        200,
        {
          "X-Goog-Upload-Status"        => "active",
          "X-Goog-Upload-Size-Received" => "0"
        },
        ""
      ),
      FakeResponse.new(
        200,
        { "X-Goog-Upload-Status" => "final" },
        "done"
      )
    ]

    stub = FakeStub.new responses
    config = StartUploadConfig.new(
      initial_url: "https://storage.googleapis.com/upload",
      stream:      StringIO.new("hello world"),
      upload_size: 11,
      chunk_size:  256
    )

    driver = Driver.new client_stub: stub, config: config, logger: recording
    driver.run

    info_recipes = recording.entries.select { |e| e.severity == Logger::INFO }.map { |e| e.message.fields["recipe"] }
    assert_includes info_recipes, "enter_recovery"
    assert_includes info_recipes, "realign_from_recovery"
  end

  def test_resume_upload_logs_resume_session_entry
    recording = RecordingLogger.new
    responses = [
      FakeResponse.new(
        200,
        {
          "X-Goog-Upload-Status"        => "active",
          "X-Goog-Upload-Size-Received" => "0"
        },
        ""
      ),
      FakeResponse.new(
        200,
        { "X-Goog-Upload-Status" => "final" },
        "done"
      )
    ]

    stub = FakeStub.new responses
    config = ResumeUploadConfig.new(
      upload_url:  "https://storage.googleapis.com/session?id=123",
      stream:      StringIO.new("hello world"),
      upload_size: 11,
      chunk_size:  256
    )

    driver = Driver.new client_stub: stub, config: config, logger: recording
    driver.run

    resume_entry = recording.entries.find do |e|
      e.severity == Logger::INFO && e.message.fields["recipe"] == "resume_session"
    end
    refute_nil resume_entry
    assert_equal Logger::INFO, resume_entry.severity
    assert_equal "Resuming upload session", resume_entry.message.message
    assert_equal 256, resume_entry.message.fields["chunkSize"]
    assert_includes resume_entry.message.fields["uploadUrl"], "session?id="
  end

  def test_fatal_failure_logs_warn_with_fail_with_recipe
    recording = RecordingLogger.new
    responses = [
      FakeResponse.new(
        403,
        { "X-Goog-Upload-Status" => "final" },
        "Forbidden"
      )
    ]

    stub = FakeStub.new responses
    config = StartUploadConfig.new(
      initial_url: "https://storage.googleapis.com/upload",
      stream:      StringIO.new("hello world"),
      upload_size: 11,
      chunk_size:  256
    )

    driver = Driver.new client_stub: stub, config: config, logger: recording
    assert_raises UploadRejectedError do
      driver.run
    end

    warn_entries = recording.entries.select { |e| e.severity == Logger::WARN }
    refute_empty warn_entries
    assert(warn_entries.any? { |e| e.message.fields["recipe"]&.start_with? "fail_with_" })
  end

  def test_unmatched_transition_logs_warn_and_reraises
    recording = RecordingLogger.new
    stub = FakeStub.new []
    config = StartUploadConfig.new(
      initial_url: "https://storage.googleapis.com/upload",
      stream:      StringIO.new("hello"),
      upload_size: 5,
      chunk_size:  256
    )

    failing_core = Minitest::Mock.new
    failing_core.expect :dispatch, nil do |_event|
      raise InvalidTransitionError, "unmatched transition in state"
    end
    failing_core.expect :state, State.new(status: :initializing)

    driver = Driver.new client_stub: stub, config: config, core: failing_core, logger: recording

    assert_raises InvalidTransitionError do
      driver.run
    end

    warn_entries = recording.entries.select { |e| e.severity == Logger::WARN }
    assert_equal 1, warn_entries.size
    fields = warn_entries.first.message.fields
    assert_equal "initializing", fields["status"]
    assert_equal "unmatched transition in state", fields["error"]
  end

  def test_full_log_corpus_redacts_secrets
    recording = RecordingLogger.new
    run_two_chunk_upload_with_secret recording

    corpus = log_corpus recording
    refute_includes corpus, "SECRET-123456"
  end

  def test_full_log_corpus_size_under_64kib
    recording = RecordingLogger.new
    run_two_chunk_upload_with_secret recording

    corpus = log_corpus recording
    assert_operator corpus.bytesize, :<, 65_536
  end

  def test_wire_receive_logs_error_status_and_abridged_error_message
    recording = RecordingLogger.new
    stub_logger = Gapic::LoggingConcerns::StubLogger.new logger: recording, service: "ResumableUpload"
    upload_log = Driver::UploadLog.new stub_logger, upload_id: "test-upload-1"

    err = Gapic::Rest::Error.new(
      "#{Gapic::Rest::Error::REST_ERROR_PREFIX}: Permission denied on resource",
      403,
      status: "PERMISSION_DENIED"
    )
    event = Event::HttpResponse.new(
      status:  403,
      headers: { "x-goog-upload-status" => "final" },
      body:    '{"raw":"error"}',
      error:   err
    )

    upload_log.wire_receive event

    debug_entries = recording.entries.select { |e| e.severity == Logger::DEBUG && e.message.message.include?("403") }
    refute_empty debug_entries
    fields = debug_entries.first.message.fields
    assert_equal 403, fields["status"]
    assert_equal "PERMISSION_DENIED", fields["errorStatus"]
    assert_equal "#{Gapic::Rest::Error::REST_ERROR_PREFIX}: Permission denied on resource", fields["body"]
  end

  def test_wire_receive_fallback_body_when_error_absent
    recording = RecordingLogger.new
    stub_logger = Gapic::LoggingConcerns::StubLogger.new logger: recording, service: "ResumableUpload"
    upload_log = Driver::UploadLog.new stub_logger, upload_id: "test-upload-2"

    event = Event::HttpResponse.new(
      status:  503,
      headers: {},
      body:    "Server unavailable",
      error:   nil
    )

    upload_log.wire_receive event

    debug_entries = recording.entries.select { |e| e.severity == Logger::DEBUG && e.message.message.include?("503") }
    refute_empty debug_entries
    fields = debug_entries.first.message.fields
    assert_equal 503, fields["status"]
    assert_nil fields["errorStatus"]
    assert_equal "Server unavailable", fields["body"]
  end

  def test_lifecycle_warn_carries_rich_message_when_driver_fails
    recording = RecordingLogger.new
    wrapped_err = Gapic::Rest::Error.new(
      "#{Gapic::Rest::Error::REST_ERROR_PREFIX}: Bucket access denied",
      403,
      status:  "PERMISSION_DENIED",
      headers: { "x-goog-upload-status" => "final" }
    )
    stub = FakeStub.new [wrapped_err]
    config = StartUploadConfig.new(
      initial_url: "https://storage.googleapis.com/upload",
      stream:      StringIO.new("data"),
      upload_size: 4,
      chunk_size:  256
    )

    driver = Driver.new client_stub: stub, config: config, logger: recording
    err = assert_raises UploadRejectedError do
      driver.run
    end

    assert_equal "Upload rejected by server with HTTP 403 PERMISSION_DENIED: Bucket access denied", err.message

    warn_entries = recording.entries.select { |e| e.severity == Logger::WARN }
    refute_empty warn_entries
    fail_warn = warn_entries.find { |e| e.message.fields["recipe"] == "fail_with_rejected" }
    refute_nil fail_warn
    assert_equal "Upload rejected by server with HTTP 403 PERMISSION_DENIED: Bucket access denied",
                 fail_warn.message.fields["error"]

    debug_entries = recording.entries.select { |e| e.severity == Logger::DEBUG && e.message.message.include?("403") }
    refute_empty debug_entries
    wire_recv = debug_entries.first
    assert_equal "PERMISSION_DENIED", wire_recv.message.fields["errorStatus"]
  end

  def test_driver_error_mapping_populates_error_on_rescue
    stub = FakeStub.new []
    config = StartUploadConfig.new(
      initial_url: "https://storage.googleapis.com/upload",
      stream:      StringIO.new("data"),
      upload_size: 4,
      chunk_size:  256
    )
    driver = Driver.new client_stub: stub, config: config

    rest_err = Gapic::Rest::Error.new "Forbidden", 403, status: "PERMISSION_DENIED"
    event = driver.send :rescue_request_error, rest_err
    assert_instance_of Event::HttpResponse, event
    assert_equal rest_err, event.error

    faraday_err = Faraday::ClientError.new "Client error", {
      status:  400,
      headers: { "content-type" => "application/json" },
      body:    '{"error":{"message":"Bad input","code":400,"status":"INVALID_ARGUMENT"}}'
    }
    faraday_event = driver.send :rescue_faraday_error, faraday_err
    assert_instance_of Event::HttpResponse, faraday_event
    assert_instance_of Gapic::Rest::Error, faraday_event.error
    assert_equal 400, faraday_event.error.status_code
    assert_equal "INVALID_ARGUMENT", faraday_event.error.status
  end

  def test_lifecycle_warn_includes_response_body_for_rejected_error
    recording = RecordingLogger.new
    raw_body = '{"error":{"code":403,"message":"Rejected by backend"}}'
    faraday_err = Faraday::ClientError.new "Client error", {
      status:  403,
      headers: { "x-goog-upload-status" => "final" },
      body:    raw_body
    }
    stub = FakeStub.new [faraday_err]
    config = StartUploadConfig.new(
      initial_url: "https://storage.googleapis.com/upload",
      stream:      StringIO.new("data"),
      upload_size: 4,
      chunk_size:  256
    )

    driver = Driver.new client_stub: stub, config: config, logger: recording
    err = assert_raises UploadRejectedError do
      driver.run
    end

    assert_equal raw_body, err.response_body

    warn_entries = recording.entries.select { |e| e.severity == Logger::WARN }
    fail_warn = warn_entries.find { |e| e.message.fields["recipe"] == "fail_with_rejected" }
    refute_nil fail_warn
    assert_equal raw_body, fail_warn.message.fields["responseBody"]
  end

  def test_lifecycle_warn_includes_response_body_for_bad_response_error
    recording = RecordingLogger.new
    raw_body = '{"error":{"message":"Invalid input","code":400}}'
    faraday_err = Faraday::ClientError.new "Client error", {
      status:  400,
      headers: { "x-goog-upload-status" => "active" },
      body:    raw_body
    }
    stub = FakeStub.new [faraday_err]
    config = StartUploadConfig.new(
      initial_url: "https://storage.googleapis.com/upload",
      stream:      StringIO.new("data"),
      upload_size: 4,
      chunk_size:  256
    )

    driver = Driver.new client_stub: stub, config: config, logger: recording
    err = assert_raises BadResponseError do
      driver.run
    end

    assert_equal raw_body, err.response_body

    warn_entries = recording.entries.select { |e| e.severity == Logger::WARN }
    fail_warn = warn_entries.find { |e| e.message.fields["recipe"] == "fail_with_bad_response" }
    refute_nil fail_warn
    assert_equal raw_body, fail_warn.message.fields["responseBody"]
  end

  def test_lifecycle_warn_omits_response_body_when_error_lacks_it
    recording = RecordingLogger.new
    stub_logger = Gapic::LoggingConcerns::StubLogger.new logger: recording, service: "ResumableUpload"
    upload_log = Driver::UploadLog.new stub_logger, upload_id: "test-upload-no-body"
    state = State.new(
      status:     :error,
      last_error: DeadlineExceededError.new("Upload deadline exceeded")
    )
    decision = Decision.new(
      from_status:  :transferring,
      shape:        :deadline_exceeded,
      recipe:       :fail_with_deadline_exceeded,
      next_state:   state,
      instructions: []
    )

    upload_log.lifecycle decision, StartUploadConfig.new(
      initial_url: "https://storage.googleapis.com/upload",
      stream:      StringIO.new("data"),
      upload_size: 4,
      chunk_size:  256
    )

    warn_entries = recording.entries.select { |e| e.severity == Logger::WARN }
    fail_warn = warn_entries.find { |e| e.message.fields["recipe"] == "fail_with_deadline_exceeded" }
    refute_nil fail_warn
    assert_equal "Upload deadline exceeded", fail_warn.message.fields["error"]
    assert_nil fail_warn.message.fields["responseBody"]
  end

  def test_error_info_reason_in_details_survives_in_error_and_logs
    recording = RecordingLogger.new
    error_info = Google::Rpc::ErrorInfo.new(
      reason:   "SERVICE_DISABLED",
      domain:   "googleapis.com",
      metadata: { "consumer" => "projects/12345", "service" => "storage.googleapis.com" }
    )
    error_info_any = Google::Protobuf::Any.pack error_info
    raw_body = JSON.dump(
      {
        "error" => {
          "code"    => 403,
          "message" => "Google Cloud Storage API has not been used in project 12345 or it is disabled.",
          "status"  => "PERMISSION_DENIED",
          "details" => [JSON.parse(error_info_any.to_json)]
        }
      }
    )
    faraday_err = Faraday::ClientError.new "Client error", {
      status:  403,
      headers: { "x-goog-upload-status" => "final" },
      body:    raw_body
    }
    stub = FakeStub.new [faraday_err]
    config = StartUploadConfig.new(
      initial_url: "https://storage.googleapis.com/upload",
      stream:      StringIO.new("data"),
      upload_size: 4,
      chunk_size:  256
    )

    driver = Driver.new client_stub: stub, config: config, logger: recording
    err = assert_raises UploadRejectedError do
      driver.run
    end

    refute_nil err.details
    unpacked_info = err.details.find { |d| d.is_a? Google::Rpc::ErrorInfo }
    refute_nil unpacked_info
    assert_equal "SERVICE_DISABLED", unpacked_info.reason
    assert_equal "googleapis.com", unpacked_info.domain
    assert_equal "projects/12345", unpacked_info.metadata["consumer"]

    expected_msg = "Upload rejected by server with HTTP 403 PERMISSION_DENIED: " \
                   "Google Cloud Storage API has not been used in project 12345 or it is disabled."
    assert_equal expected_msg, err.message
    assert_equal 403, err.status_code
    assert_equal "PERMISSION_DENIED", err.status
    assert_equal raw_body, err.response_body

    warn_entries = recording.entries.select { |e| e.severity == Logger::WARN }
    fail_warn = warn_entries.find { |e| e.message.fields["recipe"] == "fail_with_rejected" }
    refute_nil fail_warn
    assert_equal expected_msg, fail_warn.message.fields["error"]
    assert_equal raw_body, fail_warn.message.fields["responseBody"]
  end

  private

  def run_two_chunk_upload_with_secret recording
    chunk_size = 8 * 1024 * 1024
    secret = "SECRET-123456"
    binary_prefix = "\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09".b

    half = (chunk_size / 2) - 10
    chunk1 = binary_prefix + ("A" * half) + secret + ("A" * (chunk_size - 10 - half - secret.bytesize))
    chunk2 = binary_prefix + ("A" * (chunk_size - 10))
    stream_data = chunk1 + chunk2

    responses = [
      FakeResponse.new(
        200,
        {
          "X-Goog-Upload-Status" => "active",
          "X-Goog-Upload-URL"    => "https://storage.googleapis.com/session?sid=#{secret}"
        },
        ""
      ),
      FakeResponse.new(
        200,
        {
          "X-Goog-Upload-Status"        => "active",
          "X-Goog-Upload-Size-Received" => chunk_size.to_s
        },
        ""
      ),
      FakeResponse.new(
        200,
        {
          "X-Goog-Upload-Status"        => "active",
          "X-Goog-Upload-Size-Received" => (chunk_size * 2).to_s
        },
        ""
      ),
      FakeResponse.new(
        200,
        { "X-Goog-Upload-Status" => "final" },
        "done"
      )
    ]

    stub = FakeStub.new responses
    config = StartUploadConfig.new(
      initial_url:     "https://storage.googleapis.com/upload?token=#{secret}",
      initial_headers: { "Authorization" => "Bearer #{secret}" },
      stream:          StringIO.new(stream_data),
      upload_size:     stream_data.bytesize,
      chunk_size:      chunk_size
    )

    driver = Driver.new client_stub: stub, config: config, logger: recording
    driver.run
  end
end
