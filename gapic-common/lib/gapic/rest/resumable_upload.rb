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
    # * {BadResponseError} - Unexpected or malformed HTTP response (includes {HasResumeHandle}).
    # * {UnseekableStreamError} - Stream rewinding required on an unseekable stream (includes {HasResumeHandle}).
    # * {StreamMismatchError} - Stream content or length does not match resumed upload (includes {HasResumeHandle}).
    # * {InvalidTransitionError} - Unmatched event for the current protocol state (includes {HasResumeHandle}).
    # * {UploadRejectedError} - Server explicitly rejected the upload session (final).
    # * {SessionStateError} - Upload session lifecycle rule violation, e.g. starting a second run while one
    #   is in flight (final).
    #
    module ResumableUpload
      ##
      # @private
      # Backoff settings carried from a caller's retry policy into the initiation policy, mapped to the
      # {Gapic::Common::RetryPolicy} value a reader returns when the setting was never set.
      #
      # `jitter`'s default is a private constant, so it is read off a default policy rather than named.
      #
      # @return [Hash{Symbol=>Numeric}]
      BACKOFF_DEFAULTS = {
        initial_delay: Gapic::Common::RetryPolicy::DEFAULT_INITIAL_DELAY,
        max_delay:     Gapic::Common::RetryPolicy::DEFAULT_MAX_DELAY,
        multiplier:    Gapic::Common::RetryPolicy::DEFAULT_MULTIPLIER,
        jitter:        Gapic::Common::RetryPolicy.new.jitter
      }.freeze

      ##
      # @private
      # Converts the per-call options a generated client assembles into overrides for the initiation
      # retry policy.
      #
      # Returns a **Hash**, never a policy object: the protocol treats a {Gapic::Common::RetryPolicy} as a
      # wholesale replacement and a Hash as a per-key override. Initiation's default policy carries a
      # predicate that treats a response missing `X-Goog-Upload-Status` as retriable gateway noise, and
      # handing over an object would silently drop it.
      #
      # `timeout` is always set, and becomes the local deadline of the initiation request alone — the
      # whole-upload budget is separate and is not derived here. Without it, initiation would inherit
      # {Gapic::Common::RetryPolicy::DEFAULT_TIMEOUT} (one hour), because `Gapic::CallOptions::RetryPolicy`
      # never populates `@timeout` even though it subclasses {Gapic::Common::RetryPolicy}.
      #
      # Backoff settings and retry codes are copied only where the caller set them, which is why each is
      # compared against the corresponding default: a reader on an unset policy returns that default, and
      # the initiation defaults are the values that should survive. An empty `retry_codes` list counts as
      # unset. A `retry_predicate` is deliberately not copied; the initiation predicate stays in place.
      #
      # @param options [Gapic::CallOptions, nil] Per-call options from a generated client method
      # @return [Hash] Overrides for the initiation retry policy
      # @raise [ArgumentError] If the call options carry a Proc (or any other non-{Gapic::Common::RetryPolicy})
      #   retry policy, which has no coherent meaning across the three retry planes of an upload
      def self.start_retry_policy_for options
        overrides = { timeout: options&.timeout }
        policy = options&.retry_policy
        return overrides if policy.nil?
        unless policy.is_a? Gapic::Common::RetryPolicy
          raise ArgumentError,
                "Resumable upload cannot derive an initiation retry policy from a #{policy.class}; " \
                "use a Gapic::Common::RetryPolicy or a Hash of retry settings"
        end

        overrides[:retry_codes] = policy.retry_codes unless policy.retry_codes.empty?
        BACKOFF_DEFAULTS.each do |setting, default|
          value = policy.public_send setting
          overrides[setting] = value unless value == default
        end
        overrides
      end
    end
  end
end
