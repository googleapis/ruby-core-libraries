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
# Tests for ResumableUpload Rules terminal error transitions and actionable error formatting.
#
class RulesErrorTest < Minitest::Test
  include Gapic::Rest::ResumableUpload

  def setup
    @config = StartUploadConfig.new(
      initial_url:     "https://example.com/upload",
      initial_headers: { "X-Custom" => "value" },
      initial_body:    '{"name":"obj"}',
      stream:          StringIO.new("data"),
      upload_size:     1024,
      chunk_size:      512
    )
  end

  def test_transition_starting_rejected
    state = State.new status: :starting
    resp = Event::HttpResponse.new status: 403, headers: { "x-goog-upload-status" => "final" }, body: "Forbidden"
    next_state, instructions = Rules.step state, resp, @config

    assert_equal :rejected, next_state.status
    assert_instance_of UploadRejectedError, next_state.last_error
    assert_equal "Forbidden", next_state.last_error.response_body
    assert_equal 1, instructions.size
    assert_instance_of Instruction::TerminateFailure, instructions.first
    assert_equal next_state.last_error, instructions.first.error
  end

  def test_transition_starting_fatal_error
    state = State.new status: :starting
    resp = Event::HttpResponse.new status: 400, headers: {}, body: "Bad Request"
    next_state, instructions = Rules.step state, resp, @config

    assert_equal :error, next_state.status
    assert_instance_of BadResponseError, next_state.last_error
    assert_equal 400, next_state.last_error.status_code
    assert_equal 1, instructions.size
    assert_instance_of Instruction::TerminateFailure, instructions.first
  end

  def test_transition_starting_request_failed
    state = State.new status: :starting
    err = StandardError.new "DNS resolution failed"
    failed = Event::RequestFailed.new kind: :connection_failed, message: "DNS resolution failed", source_error: err
    next_state, instructions = Rules.step state, failed, @config

    assert_equal :error, next_state.status
    assert_instance_of RequestFailedError, next_state.last_error
    assert_equal err, next_state.last_error.cause
    assert_equal 1, instructions.size
    assert_instance_of Instruction::TerminateFailure, instructions.first
    assert_equal next_state.last_error, instructions.first.error
  end

  def test_transition_starting_timeout_terminates_failure
    state = State.new status: :starting
    err = StandardError.new "Read timeout"
    req_failed = Event::RequestFailed.new kind: :timeout, message: "Read timeout", source_error: err
    next_state, instructions = Rules.step state, req_failed, @config

    assert_equal :error, next_state.status
    assert_equal 0, next_state.in_flight_length
    assert_instance_of RequestFailedError, next_state.last_error
    assert_equal err, next_state.last_error.cause
    assert_equal 1, instructions.size
    assert_instance_of Instruction::TerminateFailure, instructions.first
    assert_equal next_state.last_error, instructions.first.error
  end

  def test_transition_transmission_sending_retries_exhausted_terminates_failure
    state = State.new status: :transmission_sending, upload_url: "https://example.com/session", offset: 0,
                      in_flight_length: 512
    err = StandardError.new "Retries exhausted"
    req_failed = Event::RequestFailed.new kind: :retries_exhausted, message: "Retries exhausted", source_error: err
    next_state, instructions = Rules.step state, req_failed, @config

    assert_equal :error, next_state.status
    assert_equal 0, next_state.in_flight_length
    assert_instance_of RequestFailedError, next_state.last_error
    assert_equal err, next_state.last_error.cause
    assert_equal 1, instructions.size
    assert_instance_of Instruction::TerminateFailure, instructions.first
    assert_equal next_state.last_error, instructions.first.error
  end

  def test_transition_recovery_timeout_terminates_failure
    state = State.new status: :recovery, upload_url: "https://example.com/session"
    err = StandardError.new "Query read timeout"
    req_failed = Event::RequestFailed.new kind: :timeout, message: "Query read timeout", source_error: err
    next_state, instructions = Rules.step state, req_failed, @config

    assert_equal :error, next_state.status
    assert_equal 0, next_state.in_flight_length
    assert_instance_of RequestFailedError, next_state.last_error
    assert_equal err, next_state.last_error.cause
    assert_equal 1, instructions.size
    assert_instance_of Instruction::TerminateFailure, instructions.first
    assert_equal next_state.last_error, instructions.first.error
  end

  def test_transition_global_deadline_exceeded
    state = State.new status: :transmission_sending, upload_url: "https://example.com/session"
    next_state, instructions = Rules.step state, Event::GlobalDeadlineExceeded.new, @config

    assert_equal :error, next_state.status
    assert_instance_of DeadlineExceededError, next_state.last_error
    assert_equal 1, instructions.size
    assert_instance_of Instruction::TerminateFailure, instructions.first
  end

  def test_out_of_phase_final_response_during_transmission_fails_as_bad_response
    state = State.new status: :transmission_sending, upload_url: "https://upload.example.com/session_abc"
    resp = Event::HttpResponse.new status: 200, headers: { "X-Goog-Upload-Status" => "final" }, body: '{"done":true}'

    next_state, instructions = Rules.step state, resp, @config

    assert_equal :error, next_state.status
    err = next_state.last_error
    assert_instance_of BadResponseError, err
    expected_msg = "Resumable upload failed while sending a chunk of data with HTTP 200 OK " \
                   "(X-Goog-Upload-Status: 'final')" \
                   "#{HasResumeHandle::RESUMABLE_SUFFIX}"
    assert_equal expected_msg, err.message
    assert_equal 200, err.status_code
    assert_equal '{"done":true}', err.response_body
    assert_equal "https://upload.example.com/session_abc", err.resume_handle.upload_url
    assert_instance_of Instruction::TerminateFailure, instructions.first
  end

  def test_out_of_band_cancellation_during_transmission_terminates_as_cancelled
    state = State.new status: :transmission_sending, upload_url: "https://upload.example.com/session_abc"
    resp = Event::HttpResponse.new status: 200, headers: { "x-goog-upload-status" => "cancelled" }

    next_state, instructions = Rules.step state, resp, @config

    assert_equal :cancelled, next_state.status
    err = next_state.last_error
    assert_instance_of UploadCancelledError, err
    assert_equal "Resumable upload session was cancelled (detected while sending a chunk of data)", err.message
    assert_instance_of Instruction::TerminateFailure, instructions.first
  end

  def test_out_of_band_cancellation_is_not_resumable
    state = State.new status: :recovery, upload_url: "https://upload.example.com/session_abc", chunk_size: 512
    resp = Event::HttpResponse.new status: 200, headers: { "x-goog-upload-status" => "cancelled" }

    next_state, = Rules.step state, resp, @config
    err = next_state.last_error

    assert_equal :cancelled, next_state.status
    assert_instance_of UploadCancelledError, err
    # The session is gone: rescuing HasResumeHandle must not catch this, or a caller following the
    # documented "retry with the handle" idiom would loop against a session that can never accept a byte.
    refute_operator HasResumeHandle, :===, err
    refute_includes err.message, "(upload session is resumable: see #resume_handle)"
    assert_equal "Resumable upload session was cancelled " \
                 "(detected while querying upload offset for recovery)",
                 err.message
  end

  def test_client_requested_cancellation_still_completes_normally
    state = State.new status: :cancelling, upload_url: "https://upload.example.com/session_abc"
    resp = Event::HttpResponse.new status: 200, headers: { "x-goog-upload-status" => "cancelled" }

    next_state, = Rules.step state, resp, @config

    assert_equal :cancelled, next_state.status
    assert_instance_of UploadCancelledError, next_state.last_error
    assert_equal :complete_cancellation, Rules.route(:cancelling, :response_cancelled)
  end

  def test_invalid_transition_shows_missing_when_upload_status_header_absent
    state = State.new status: :transmission_reading
    resp = Event::HttpResponse.new status: 200, headers: {}, body: ""

    err = assert_raises InvalidTransitionError do
      Rules.step state, resp, @config
    end

    expected_msg = "Resumable upload failed while reading chunk from stream: " \
                   "received an unexpected HTTP 200 response (X-Goog-Upload-Status: missing)."
    assert_equal expected_msg, err.message
    assert_equal :transmission_reading, err.state
    assert_equal resp, err.response
  end

  def test_invalid_transition_raises_error_for_non_http_event
    state = State.new status: :starting
    event = Event::ChunkRead.new bytes_buffered: 512, eof: false

    err = assert_raises InvalidTransitionError do
      Rules.step state, event, @config
    end

    expected_msg = "Resumable upload failed while initiating upload session: " \
                   "received unexpected stream chunk read (512 bytes, eof: false)."
    assert_equal expected_msg, err.message
    assert_equal :starting, err.state
    assert_equal event, err.event
    assert_nil err.response
  end

  def test_rejected_with_wrapped_error_deprefixes_message_and_preserves_metadata
    details = [{ "reason" => "ACCESS_DENIED" }]
    headers = { "x-goog-upload-status" => "final", "content-type" => "application/json" }
    wrapped_err = Gapic::Rest::Error.new(
      "#{Gapic::Rest::Error::REST_ERROR_PREFIX}: The caller does not have permission",
      403,
      status:  "PERMISSION_DENIED",
      details: details,
      headers: headers
    )
    resp = Event::HttpResponse.new(
      status:  403,
      headers: headers,
      body:    '{"error":{"message":"The caller does not have permission"}}',
      error:   wrapped_err
    )

    state = State.new status: :starting
    next_state, instructions = Rules.step state, resp, @config

    assert_equal :rejected, next_state.status
    err = next_state.last_error
    assert_instance_of UploadRejectedError, err
    assert_equal "Upload rejected by server with HTTP 403 PERMISSION_DENIED: The caller does not have permission",
                 err.message
    assert_equal 403, err.status_code
    assert_equal "PERMISSION_DENIED", err.status
    assert_equal details, err.details
    assert_equal details, err.status_details
    assert_equal headers, err.headers
    assert_equal headers, err.header
    assert_equal '{"error":{"message":"The caller does not have permission"}}', err.response_body
    assert_equal err, instructions.first.error
  end

  def test_rejected_fallback_without_wrapped_error
    resp = Event::HttpResponse.new status: 403, headers: { "x-goog-upload-status" => "final" }, body: "Forbidden"
    state = State.new status: :starting
    next_state, _instructions = Rules.step state, resp, @config

    assert_equal :rejected, next_state.status
    err = next_state.last_error
    assert_instance_of UploadRejectedError, err
    assert_equal "Upload rejected by server with HTTP 403 Forbidden (X-Goog-Upload-Status: 'final')", err.message
    assert_equal 403, err.status_code
    assert_equal "Forbidden", err.response_body
  end

  def test_bad_response_with_wrapped_error_deprefixes_message_and_preserves_metadata
    details = ["Quota limit details"]
    headers = { "x-goog-upload-status" => "active" }
    wrapped_err = Gapic::Rest::Error.new(
      "#{Gapic::Rest::Error::REST_ERROR_PREFIX}: Quota limit reached",
      429,
      status:  "RESOURCE_EXHAUSTED",
      details: details,
      headers: headers
    )
    resp = Event::HttpResponse.new status: 429, headers: headers, body: "Too many requests", error: wrapped_err

    state = State.new status: :starting
    next_state, _instructions = Rules.step state, resp, @config

    assert_equal :error, next_state.status
    err = next_state.last_error
    assert_instance_of BadResponseError, err
    assert_equal "Resumable upload failed while initiating upload session with HTTP 429 RESOURCE_EXHAUSTED: " \
                 "Quota limit reached",
                 err.message
    assert_equal 429, err.status_code
    assert_equal "RESOURCE_EXHAUSTED", err.status
    assert_equal details, err.status_details
    assert_equal headers, err.headers
    assert_equal "Too many requests", err.response_body
  end

  def test_bad_response_fallback_without_wrapped_error
    resp = Event::HttpResponse.new status: 503, headers: {}, body: "Service unavailable"
    state = State.new status: :starting
    next_state, _instructions = Rules.step state, resp, @config

    assert_equal :error, next_state.status
    err = next_state.last_error
    assert_instance_of BadResponseError, err
    assert_equal "Resumable upload failed while initiating upload session with HTTP 503 Service Unavailable " \
                 "(X-Goog-Upload-Status: missing)",
                 err.message
    assert_equal 503, err.status_code
    assert_equal "Service unavailable", err.response_body
  end

  def test_format_status_preserves_canonical_status_token
    wrapped_err = Gapic::Rest::Error.new(
      "#{Gapic::Rest::Error::REST_ERROR_PREFIX}: Object not found",
      404,
      status:  "NOT_FOUND",
      headers: { "x-goog-upload-status" => "final" }
    )
    resp = Event::HttpResponse.new status: 404, headers: { "x-goog-upload-status" => "final" },
                                   body: "Not found", error: wrapped_err
    err = UploadRejectedError.from resp
    assert_equal "Upload rejected by server with HTTP 404 NOT_FOUND: Object not found", err.message
    assert_equal "NOT_FOUND", err.status
  end

  def test_error_class_inheritance_hierarchy
    assert_operator UploadCancelledError, :<, Gapic::Common::Error
    refute_operator UploadCancelledError, :<, Gapic::Rest::Error

    assert_operator DeadlineExceededError, :<, Gapic::Common::Error
    refute_operator DeadlineExceededError, :<, Gapic::Rest::Error

    assert_operator UploadRejectedError, :<, Gapic::Rest::Error
    assert_operator BadResponseError, :<, Gapic::Rest::Error

    assert_operator StreamMismatchError, :<, Gapic::Common::Error
    assert_operator RequestFailedError, :<, Gapic::Common::Error
    assert_operator HasResumeHandle, :===, BadResponseError.new
    assert_operator HasResumeHandle, :===, DeadlineExceededError.new
    assert_operator HasResumeHandle, :===, UnseekableStreamError.new
    refute_operator HasResumeHandle, :===, InvalidTransitionError.new("invalid")
    assert_operator InvalidTransitionError, :<, InternalError
    assert_operator InternalError, :===, InvalidTransitionError.new("invalid")
    assert_operator HasResumeHandle, :===, StreamMismatchError.new
    assert_operator HasResumeHandle, :===, RequestFailedError.new("failed")
    refute_operator HasResumeHandle, :===, UploadRejectedError.new
    refute_operator HasResumeHandle, :===, UploadCancelledError.new
  end

  def test_rules_resume_handle_from
    assert_nil Rules.resume_handle_from(nil)
    assert_nil Rules.resume_handle_from(State.new(status: :starting, upload_url: nil))
    assert_nil Rules.resume_handle_from(State.new(status: :rejected, upload_url: "https://upload.example.com/id123"))
    assert_nil Rules.resume_handle_from(State.new(status: :cancelled, upload_url: "https://upload.example.com/id123"))
    assert_nil Rules.resume_handle_from(State.new(status: :success, upload_url: "https://upload.example.com/id123"))

    state = State.new status: :transmission_sending, upload_url: "https://upload.example.com/id123", chunk_size: 1024
    handle = Rules.resume_handle_from state
    refute_nil handle
    assert_equal "https://upload.example.com/id123", handle.upload_url
    assert_equal 1024, handle.chunk_size
  end

  def test_resume_handle_present_on_errors_when_upload_url_set
    state = State.new(
      status:     :transmission_sending,
      upload_url: "https://upload.example.com/session_abc",
      chunk_size: 512
    )

    # 1. Deadline exceeded
    next_state, = Rules.step state, Event::GlobalDeadlineExceeded.new, @config
    assert_equal :error, next_state.status
    deadline_err = next_state.last_error
    assert_instance_of DeadlineExceededError, deadline_err
    refute_nil deadline_err.resume_handle
    assert_equal "https://upload.example.com/session_abc", deadline_err.resume_handle.upload_url
    assert_equal 512, deadline_err.resume_handle.chunk_size
    assert_includes deadline_err.message, "(upload session is resumable: see #resume_handle)"

    # 2. Bad response
    resp = Event::HttpResponse.new status: 401, headers: {}, body: "Fatal 401"
    next_state, = Rules.step state, resp, @config
    assert_equal :error, next_state.status
    bad_resp_err = next_state.last_error
    assert_instance_of BadResponseError, bad_resp_err
    refute_nil bad_resp_err.resume_handle
    assert_equal "https://upload.example.com/session_abc", bad_resp_err.resume_handle.upload_url
    assert_equal 512, bad_resp_err.resume_handle.chunk_size
    assert_includes bad_resp_err.message, "(upload session is resumable: see #resume_handle)"

    # 3. Unmatched transition — an internal bug, never resumable, even with an established session
    unmatched_err = assert_raises InvalidTransitionError do
      Rules.step state, Object.new, @config
    end
    refute_operator HasResumeHandle, :===, unmatched_err
    refute_includes unmatched_err.message, "(upload session is resumable: see #resume_handle)"

    # 4. Request failed (retries exhausted)
    req_failed = Event::RequestFailed.new(
      kind: :retries_exhausted,
      message: "Connection reset",
      source_error: StandardError.new("reset")
    )
    next_state, = Rules.step state, req_failed, @config
    assert_equal :error, next_state.status
    req_err = next_state.last_error
    assert_instance_of RequestFailedError, req_err
    refute_nil req_err.resume_handle
    assert_equal "https://upload.example.com/session_abc", req_err.resume_handle.upload_url
    assert_equal 512, req_err.resume_handle.chunk_size
    assert_equal "reset", req_err.cause.message
    assert_includes req_err.message, "(upload session is resumable: see #resume_handle)"
  end

  def test_resume_handle_nil_on_errors_before_session_created
    state = State.new status: :starting, upload_url: nil

    # 1. Deadline exceeded before session creation
    next_state, = Rules.step state, Event::GlobalDeadlineExceeded.new, @config
    assert_equal :error, next_state.status
    deadline_err = next_state.last_error
    assert_nil deadline_err.resume_handle
    refute_includes deadline_err.message, "(upload session is resumable: see #resume_handle)"

    # 2. Bad response before session creation
    resp = Event::HttpResponse.new status: 503, headers: {}, body: "Init failed"
    next_state, = Rules.step state, resp, @config
    assert_equal :error, next_state.status
    bad_resp_err = next_state.last_error
    assert_nil bad_resp_err.resume_handle
    refute_includes bad_resp_err.message, "(upload session is resumable: see #resume_handle)"

    # 3. Unmatched transition before session creation
    unmatched_err = assert_raises InvalidTransitionError do
      Rules.step state, Object.new, @config
    end
    refute_operator HasResumeHandle, :===, unmatched_err
    refute_includes unmatched_err.message, "(upload session is resumable: see #resume_handle)"

    # 4. Request failed before session creation
    req_failed = Event::RequestFailed.new(
      kind: :connection_failed,
      message: "Connection reset",
      source_error: StandardError.new("reset")
    )
    next_state, = Rules.step state, req_failed, @config
    assert_equal :error, next_state.status
    req_err = next_state.last_error
    assert_instance_of RequestFailedError, req_err
    assert_nil req_err.resume_handle
    refute_includes req_err.message, "(upload session is resumable: see #resume_handle)"
  end

  def test_resume_handle_absent_on_rejected_and_cancelled
    state = State.new(
      status:     :transmission_sending,
      upload_url: "https://upload.example.com/session_abc",
      chunk_size: 512
    )

    # 1. Rejected error
    rejected_resp = Event::HttpResponse.new status: 403, headers: { "x-goog-upload-status" => "final" },
                                           body: "Access Denied"
    next_state, = Rules.step state, rejected_resp, @config
    assert_equal :rejected, next_state.status
    rejected_err = next_state.last_error
    assert_instance_of UploadRejectedError, rejected_err
    refute_respond_to rejected_err, :resume_handle
    refute_includes rejected_err.message, "(upload session is resumable: see #resume_handle)"

    # 2. Cancelled error
    cancelling_state = state.with status: :cancelling
    cancelled_resp = Event::HttpResponse.new status: 200, headers: { "x-goog-upload-status" => "cancelled" },
                                            body: ""
    next_state, = Rules.step cancelling_state, cancelled_resp, @config
    assert_equal :cancelled, next_state.status
    cancelled_err = next_state.last_error
    assert_instance_of UploadCancelledError, cancelled_err
    refute_respond_to cancelled_err, :resume_handle
    refute_includes cancelled_err.message, "(upload session is resumable: see #resume_handle)"
  end

  def test_stream_mismatch_error_behavior
    handle = ResumeHandle.new upload_url: "https://upload.example.com/resume", chunk_size: 256
    err_with_handle = StreamMismatchError.new "Stream too short", resume_handle: handle

    assert_instance_of StreamMismatchError, err_with_handle
    assert_equal handle, err_with_handle.resume_handle
    assert_equal "Stream too short (upload session is resumable: see #resume_handle)", err_with_handle.message

    err_from = StreamMismatchError.from "Stream corrupted", resume_handle: handle
    assert_equal handle, err_from.resume_handle
    assert_equal "Stream corrupted (upload session is resumable: see #resume_handle)", err_from.message

    err_without_handle = StreamMismatchError.new "No handle"
    assert_nil err_without_handle.resume_handle
    assert_equal "No handle", err_without_handle.message
  end

  def test_request_failed_error_behavior
    handle = ResumeHandle.new upload_url: "https://upload.example.com/resume", chunk_size: 256
    cause = Gapic::Rest::Error.new "Underlying Faraday error", 500, status: "INTERNAL", details: ["foo"], headers: { "k" => "v" }

    err_with_handle = RequestFailedError.from cause, resume_handle: handle
    assert_instance_of RequestFailedError, err_with_handle
    assert_equal cause, err_with_handle.cause
    assert_equal handle, err_with_handle.resume_handle
    assert_equal 500, err_with_handle.status_code
    assert_equal "INTERNAL", err_with_handle.status
    assert_equal ["foo"], err_with_handle.details
    assert_equal({ "k" => "v" }, err_with_handle.headers)
    assert_equal "Underlying Faraday error (upload session is resumable: see #resume_handle)", err_with_handle.message

    err_without_handle = RequestFailedError.from cause
    assert_nil err_without_handle.resume_handle
    assert_equal "Underlying Faraday error", err_without_handle.message
  end
end
