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

module Gapic
  module Rest
    ##
    # Resumable Upload Protocol implementation for REST transport: session initiation, chunked
    # streaming, automatic retries, progress reporting via {Progress}, and resumption via
    # {ResumeHandle}.
    #
    # **This namespace has no callable surface.** Every method and class in it is internal machinery,
    # documented as `@private` and excluded from these docs; what remains visible is the data a caller
    # receives — {Progress}, {ResumeHandle}, {HasResumeHandle} — and the error classes listed below.
    # Uploads are driven from {Gapic::ResumableUpload}, which sits above this namespace and coordinates
    # runs against it.
    #
    # Errors raised from here carry a {ResumeHandle} where the upload can still be continued, so the
    # usual shape of handling one is to rescue {HasResumeHandle} and hand the handle back to the
    # coordinator:
    #
    # @example Uploading, then resuming after a recoverable failure
    #   upload = client.upload_media ... # returns a Gapic::ResumableUpload
    #   begin
    #     upload.start stream: File.open("movie.mp4", "rb"), upload_size: File.size("movie.mp4")
    #   rescue Gapic::Rest::ResumableUpload::HasResumeHandle => e
    #     handle = e.resume_handle
    #     upload.resume stream: File.open("movie.mp4", "rb"), resume_handle: handle
    #   end
    #
    # ### Error Types
    # * {RequestFailedError} - Transport connection failure, timeout, or retries exhausted (includes {HasResumeHandle}).
    # * {DeadlineExceededError} - Whole-upload timeout exceeded (includes {HasResumeHandle}).
    # * {BadResponseError} - Unexpected, malformed, or out-of-phase HTTP response (includes {HasResumeHandle}).
    # * {UnseekableStreamError} - Stream rewinding required on an unseekable stream (includes {HasResumeHandle}).
    # * {StreamMismatchError} - Stream content or length does not match resumed upload (includes {HasResumeHandle}).
    # * {UploadRejectedError} - Server explicitly rejected the upload session (final).
    # * {UploadCancelledError} - Upload session was cancelled, either by this client or on the server while the
    #   upload was in flight. A cancelled session cannot be resumed, so this error carries no {ResumeHandle} (final).
    # * {SessionStateError} - Upload session lifecycle rule violation, e.g. starting a second run while one
    #   is in flight (final).
    # * Any other `Gapic::Common::Error` subclass signals a protocol implementation bug rather than a caller
    #   or server error (final).
    #
    module ResumableUpload
      ##
      # @private
      # Converts the per-call options a generated client assembles into overrides for the initiation
      # retry policy.
      #
      # Returns a **Hash**, never a policy object: the protocol treats a {Gapic::Common::RetryPolicy} as a
      # wholesale replacement and a Hash as a per-key override, so a Hash keeps every protocol default the
      # caller did not set (notably the initiation `retry_codes`).
      #
      # `timeout` is the one setting the caller cannot express here: it is set unconditionally from the
      # call's own timeout and becomes the local deadline of the initiation request alone — the
      # whole-upload budget is separate and is not derived here. A `timeout` inside the caller's retry
      # policy is inert at the call layer (`Gapic::CallOptions::RetryPolicy` never populates `@timeout`,
      # and `RpcCall` deadlines on `CallOptions#timeout`), so honouring it here would invent a meaning it
      # has nowhere else. With no call timeout, initiation falls back to
      # {Gapic::Common::RetryPolicy::DEFAULT_TIMEOUT} — one hour.
      #
      # Everything else the caller set is carried across as-is, by asking the policy what it carries
      # ({Gapic::Common::RetryPolicy#overrides}) rather than inferring it from the readers, so a choice
      # that happens to equal a library default still lands. That includes `retry_predicate`: the default
      # initiation policy has none, so a caller's predicate is consulted as-is, ahead of `retry_codes`.
      # The protocol's own retries (connection failures and a `200` without `X-Goog-Upload-Status`) and
      # its refusals (a `final` rejection) are decided before the policy is asked, so no predicate can
      # disable or override them.
      #
      # @param options [Gapic::CallOptions, nil] Per-call options from a generated client method
      # @return [Hash] Overrides for the initiation retry policy
      # @raise [ArgumentError] If the call options carry a Proc (or any other non-{Gapic::Common::RetryPolicy})
      #   retry policy, which has no coherent meaning across the three retry planes of an upload
      def self.start_retry_policy_for options
        policy = options&.retry_policy
        if policy && !policy.is_a?(Gapic::Common::RetryPolicy)
          raise ArgumentError,
                "Resumable upload cannot derive an initiation retry policy from a #{policy.class}; " \
                "use a Gapic::Common::RetryPolicy or a Hash of retry settings"
        end

        (policy&.overrides || {}).merge timeout: options&.timeout
      end
    end
  end
end
