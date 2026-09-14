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

require "gapic/rest/resumable_upload/errors"
require "gapic/rest/resumable_upload/data_types"
require "gapic/rest/resumable_upload/events"
require "gapic/rest/resumable_upload/instructions"
require "gapic/rest/resumable_upload/retry_policies"
require "gapic/rest/resumable_upload/driver/abridge"
require "gapic/rest/resumable_upload/driver/upload_log"
require "gapic/rest/resumable_upload/rules"
require "gapic/rest/resumable_upload/core"
require "gapic/rest/resumable_upload/driver"
require "gapic/rest/resumable_upload/session"

module Gapic
  module Rest
    ##
    # Resumable Upload Protocol implementation for REST transport.
    #
    # {Session} is the primary public entry point for initiating and resuming uploads.
    # It manages session initiation, chunked streaming, automatic retries, progress
    # callbacks via {Progress}, and cross-session resumption via {ResumeHandle}.
    #
    # ### Error Types
    # * {RequestFailedError} - Transport connection failure, timeout, or retries exhausted (includes {HasResumeHandle}).
    # * {DeadlineExceededError} - Global upload timeout exceeded (includes {HasResumeHandle}).
    # * {BadResponseError} - Unexpected or malformed HTTP response (includes {HasResumeHandle}).
    # * {UnseekableStreamError} - Stream rewinding required on an unseekable stream (includes {HasResumeHandle}).
    # * {StreamMismatchError} - Stream content or length does not match resumed upload (includes {HasResumeHandle}).
    # * {InvalidTransitionError} - Unmatched event for the current protocol state (includes {HasResumeHandle}).
    # * {UploadRejectedError} - Server explicitly rejected the upload session (final).
    # * {SessionStateError} - Session lifecycle rule violation, e.g., calling `#start` twice (final).
    #
    # @example Initiating an upload, rescuing an error, and resuming from a fresh session
    #   session = Gapic::Rest::ResumableUpload::Session.new(
    #     client_stub: client_stub,
    #     stream: stream,
    #     initial_url: "https://example.googleapis.com/resumable/upload/v1/example/upload:new"
    #   )
    #
    #   begin
    #     response = session.start
    #   rescue Gapic::Rest::ResumableUpload::HasResumeHandle => e
    #     handle = e.resume_handle
    #     raise unless handle
    #
    #     stream.rewind
    #     resumed_session = Gapic::Rest::ResumableUpload::Session.new(
    #       client_stub: client_stub,
    #       stream: stream,
    #       initial_url: session.initial_url
    #     )
    #     response = resumed_session.resume resume_handle: handle
    #   end
    #
    module ResumableUpload
    end
  end
end
