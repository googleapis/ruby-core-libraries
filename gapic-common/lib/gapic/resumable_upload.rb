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

require "gapic/rest/resumable_upload"

module Gapic
  ##
  # Coordinates resumable uploads for a client method that performs them.
  #
  # A client method that uploads media returns one of these handles instead of a response. No request is
  # sent and no byte is read from the stream until {#start} or {#resume} is called on it. Both are
  # synchronous: they block the calling thread for the whole upload and return the decoded response
  # message.
  #
  # ### Reusable
  #
  # A handle is reusable, and a failed run is resumed on the same object:
  #
  # @example Uploading, then resuming after a recoverable failure
  #   upload = client.create_media_upload request
  #   begin
  #     upload.start stream: File.open("movie.mp4", "rb"), content_type: "video/mp4"
  #   rescue Gapic::Rest::ResumableUpload::HasResumeHandle => e
  #     raise unless upload.resumable?
  #     upload.resume stream: File.open("movie.mp4", "rb")
  #   end
  #
  # The stream handed to {#resume} must be positioned at byte 0 of the whole object, not at the server's
  # acknowledged offset; the upload fast-forwards on its own, by seeking on a seekable stream or by
  # reading and discarding on an unseekable one. An unseekable stream therefore has to be freshly opened
  # rather than rewound.
  #
  # A run that failed in a way the protocol can recover from leaves a {Gapic::Rest::ResumableUpload::ResumeHandle}
  # behind, readable from {#resume_handle} and also carried on the error. Persisting that handle lets a
  # later process resume the same upload:
  #
  # @example Resuming an upload started by an earlier process
  #   upload = client.create_media_upload
  #   upload.resume stream:        File.open("movie.mp4", "rb"),
  #                 resume_handle: Gapic::Rest::ResumableUpload::ResumeHandle.new(
  #                   upload_url: row[:upload_url], chunk_size: row[:chunk_size]
  #                 )
  #
  # A completed upload is finalized: {#resume_handle} returns `nil` and {#resumable?} returns `false`, so
  # there is no handle to resume from. Calling {#start} again is permitted and begins a second, unrelated
  # upload.
  #
  # ### The Two Timeouts
  #
  # An upload is bounded by two independent budgets, and they are three orders of magnitude apart:
  #
  # | Budget | Set by | Covers |
  # |---|---|---|
  # | whole upload | `upload_timeout:` on {#start} and {#resume} | every request, retry and byte of the run |
  # | initiation request | per-call `timeout`, or `timeout:` in `start_retry_policy` | creating the session |
  #
  # The per-call `timeout` a client method takes reaches only the initiation request. An upload still
  # transferring bytes an hour later has long outlived it, and that is expected. To bound the run as a
  # whole, pass `upload_timeout:`.
  #
  # ### Threading
  #
  # {#start} and {#resume} block the calling thread, and the `on_progress` callback runs on that same
  # thread. The readers ({#resume_handle}, {#resumable?}, {#running?}) are guarded by an internal mutex and
  # may be called from another thread mid-run; values read that way are a best-effort snapshot of a state
  # the upload thread is still advancing.
  #
  # ### Defaults
  #
  # * `chunk_size` defaults to 8 MB, then rounds down to a multiple of any chunk granularity the server
  #   requires.
  # * `upload_timeout` defaults to `upload_size / 1 MB per second` when `upload_size` is known, floored at
  #   one hour, and to one hour flat when it is not.
  #
  # ### Retry Policies
  #
  # Retry behavior is partitioned across three policies. Only the initiation policy is caller-supplied;
  # the other two are the protocol's own and govern the requests no call option describes.
  #
  # | Policy | Governs | Default `retry_codes` |
  # |---|---|---|
  # | initiation | session initiation | the 4xx and 5xx sets below |
  # | control plane | `query` and `cancel` | the 4xx and 5xx sets below |
  # | data plane | `upload` and `finalize` | the 5xx set below only |
  #
  # * 4xx set: `ALREADY_EXISTS` (HTTP `409`), `RESOURCE_EXHAUSTED` (`429`), `CANCELLED` (`499`).
  # * 5xx set: `INTERNAL` (HTTP `500`), `UNAVAILABLE` (`503`), `DEADLINE_EXCEEDED` (`504`).
  #
  # None of the defaults carries a `retry_predicate`, so one supplied by the caller is consulted as-is,
  # ahead of `retry_codes`. All three share the same backoff: `initial_delay` `1.0` s, `max_delay`
  # `15.0` s, `multiplier` `1.3`.
  #
  # Some decisions belong to the protocol and are made before a policy is asked:
  #
  # * Initiation and control plane requests are re-sent, within the policy's deadline, after a connection
  #   or TLS failure, and after a `200` response missing `X-Goog-Upload-Status`.
  # * Data plane requests are never re-sent after an outcome that leaves the server offset unknown — a
  #   timeout, a connection failure, a missing status header, or any `4xx`. The upload re-queries the
  #   session and resumes from the offset the server reports instead.
  # * A response carrying `X-Goog-Upload-Status: final` is never retried.
  #
  class ResumableUpload
    ##
    # @private
    # Builds a coordinator for one client method call.
    #
    # Instances come from generated client methods; the arguments below are what such a method has to
    # hand over, not a surface a caller assembles.
    #
    # Both procs are deferred deliberately. `client_stub_proc` lets a client that cannot perform REST
    # calls hand back a working handle and fail only when an upload is actually attempted.
    # `initial_request_proc` means the initiation URL and body are computed on {#start} and never on
    # {#resume}, so a handle built without a request message is still fully functional for resuming.
    #
    # @param client_stub_proc [Proc] Returns the {Gapic::Rest::ClientStub} to upload through. Called at
    #   the top of every run, and may raise if the client cannot perform REST calls.
    # @param initial_request_proc [Proc] Returns the `[url, body]` pair for session initiation. Called by
    #   {#start} only.
    # @param response_type [Class, nil] Protobuf message class the final response body is decoded into.
    #   `nil` returns the raw body; see {#start}.
    # @param initial_headers [Hash] Headers for the initiation request. Keys and values are stringified.
    #   The five reserved protocol headers (`X-Goog-Upload-Protocol`, `X-Goog-Upload-Command`,
    #   `X-Goog-Upload-Offset`, `X-Goog-Upload-Header-Content-Type`, `X-Goog-Upload-Header-Content-Length`)
    #   are rejected in any casing; use `content_type` and `upload_size` on the run methods instead.
    # @param start_retry_policy [Gapic::Common::RetryPolicy, Hash, nil] Retry policy for the initiation
    #   request. A {Gapic::Common::RetryPolicy} replaces the default policy outright; a Hash overrides only
    #   the settings it names. See the "Retry Policies" section in the class documentation.
    # @param control_plane_retry_policy [Gapic::Common::RetryPolicy, Hash, nil] Retry policy for `query`
    #   and `cancel`. `nil` uses the protocol default.
    # @param data_plane_retry_policy [Gapic::Common::RetryPolicy, Hash, nil] Retry policy for `upload` and
    #   `finalize`. `nil` uses the protocol default.
    # @param error_handler [Proc, nil] Called with a run failure and **returns** the exception to raise in
    #   its place. It must not raise.
    # @param method_name [String, nil] RPC name used in log entries.
    #
    def initialize client_stub_proc:,
                   initial_request_proc:,
                   response_type:,
                   initial_headers: {},
                   start_retry_policy: nil,
                   control_plane_retry_policy: nil,
                   data_plane_retry_policy: nil,
                   error_handler: nil,
                   method_name: nil
      @client_stub_proc = client_stub_proc
      @initial_request_proc = initial_request_proc
      @response_type = response_type
      @initial_headers = stringify_headers initial_headers
      @start_retry_policy = start_retry_policy
      @control_plane_retry_policy = control_plane_retry_policy
      @data_plane_retry_policy = data_plane_retry_policy
      @error_handler = error_handler
      @method_name = method_name

      @mutex = Mutex.new
      @running = false
      @driver = nil
    end

    ##
    # Creates an upload session on the server and transfers the stream into it.
    #
    # Blocks the calling thread until the upload completes or fails. The stream is assumed to be
    # positioned at byte 0 (it is not rewound before reading) and is not closed after use.
    #
    # @example
    #   response = upload.start stream:         File.open("movie.mp4", "rb"),
    #                           content_type:   "video/mp4",
    #                           upload_size:    File.size("movie.mp4"),
    #                           upload_timeout: 4 * 3600,
    #                           on_progress:    ->(p) { puts "#{p.phase}: #{p.bytes_uploaded}" }
    #
    # @param stream [IO] Binary input stream to upload, positioned at byte 0.
    # @param content_type [String, nil] MIME type of the uploaded media.
    # @param upload_size [Integer, nil] Total upload bytes, if known upfront.
    # @param chunk_size [Integer, nil] Requested chunk size in bytes, defaulting to 8 MB. The effective
    #   size is rounded down to a multiple of any chunk granularity the server requires, or raised to that
    #   granularity if it exceeds the requested size. A resumed run has no such argument: it takes its
    #   chunk size from the {Gapic::Rest::ResumableUpload::ResumeHandle}.
    # @param upload_timeout [Numeric, nil] Budget in seconds for the **whole run** — every request, every
    #   retry, every byte — not for any single request. The per-call `timeout` a client method takes bounds
    #   the initiation request alone. When `nil`, resolves to `upload_size / 1 MB per second` floored at one
    #   hour if `upload_size` is known, and to one hour flat otherwise.
    # @param on_progress [Proc, nil] Called as `->(progress)` with a {Gapic::Rest::ResumableUpload::Progress}
    #   instance. Runs synchronously on the upload thread and must not block; an exception raised inside it
    #   aborts the run and propagates out of this method.
    # @return [Object] The final response decoded into the handle's response type, or the raw response body
    #   (a String, or `nil` when the final response carried none) when the handle has no response type.
    # @raise [ArgumentError] If the initiation headers set a reserved protocol header, if a retry policy is
    #   neither a {Gapic::Common::RetryPolicy}, a Hash, nor `nil`, or if the client cannot perform REST calls
    # @raise [Gapic::Rest::ResumableUpload::SessionStateError] If a run is already in progress
    # @raise [Gapic::Rest::ResumableUpload::RequestFailedError] If a transport error, timeout, or retry
    #   exhaustion occurs
    # @raise [Gapic::Rest::ResumableUpload::DeadlineExceededError] If `upload_timeout` is exceeded
    # @raise [Gapic::Rest::ResumableUpload::BadResponseError] If an unexpected or malformed HTTP response
    #   is received
    # @raise [Gapic::Rest::ResumableUpload::UnseekableStreamError] If stream rewinding is required during
    #   recovery on an unseekable stream
    # @raise [Gapic::Rest::ResumableUpload::StreamMismatchError] If stream content or length does not match
    #   protocol expectations
    # @raise [Gapic::Rest::ResumableUpload::UploadRejectedError] If the server explicitly rejects the upload
    # @raise [Gapic::Common::Error] Any other subclass signals a protocol implementation bug rather than a
    #   caller or server error
    #
    def start stream:,
              content_type: nil,
              upload_size: nil,
              chunk_size: nil,
              upload_timeout: nil,
              on_progress: nil
      execute_run do
        client_stub = @client_stub_proc.call
        initial_url, initial_body = @initial_request_proc.call
        config = ::Gapic::Rest::ResumableUpload::StartUploadConfig.new(
          initial_url:        initial_url,
          initial_body:       initial_body,
          initial_headers:    @initial_headers,
          chunk_size:         chunk_size,
          start_retry_policy: @start_retry_policy,
          **run_config_args(stream: stream, content_type: content_type, upload_size: upload_size,
                            upload_timeout: upload_timeout, on_progress: on_progress)
        )
        build_driver client_stub, config
      end
    end

    ##
    # Resumes an upload session the server has already created, transferring whatever it has not yet
    # acknowledged.
    #
    # Blocks the calling thread until the upload completes or fails. A resumed run sends no initiation
    # request, so it takes no initiation arguments and needs no request message.
    #
    # The target is a {Gapic::Rest::ResumableUpload::ResumeHandle}: either the one passed in, or — when
    # `resume_handle` is omitted — the one left behind by this handle's last run. The bare form raises
    # `ArgumentError` when there is none, which covers a handle that has never run, a run that finished
    # successfully, and a run that failed in a way the protocol considers unresumable.
    #
    # Resuming against a finalized upload URL is undefined behavior: it queries the server and might
    # return the response body or raise an error, depending on the server response.
    #
    # @param stream [IO] Binary input stream to upload, positioned at byte 0 of the **whole object**, not
    #   at the server's acknowledged offset. The upload fast-forwards on its own, by seeking or by reading
    #   and discarding. Not closed after use.
    # @param resume_handle [Gapic::Rest::ResumableUpload::ResumeHandle, nil] Upload to resume. Defaults to
    #   the one left behind by this handle's last run.
    # @param content_type [String, nil] MIME type of the uploaded media.
    # @param upload_size [Integer, nil] Total upload bytes, if known upfront.
    # @param upload_timeout [Numeric, nil] Budget in seconds for the **whole run**. See {#start}.
    # @param on_progress [Proc, nil] Called as `->(progress)` with a {Gapic::Rest::ResumableUpload::Progress}
    #   instance. Runs synchronously on the upload thread and must not block.
    # @return [Object] The final response decoded into the handle's response type, or the raw response body
    #   (a String, or `nil` when the final response carried none) when the handle has no response type.
    # @raise [ArgumentError] If there is no upload to resume, if the stream is not positioned at byte 0, if
    #   a retry policy is neither a {Gapic::Common::RetryPolicy}, a Hash, nor `nil`, or if the client cannot
    #   perform REST calls
    # @raise [Gapic::Rest::ResumableUpload::SessionStateError] If a run is already in progress
    # @raise [Gapic::Rest::ResumableUpload::RequestFailedError] If a transport error, timeout, or retry
    #   exhaustion occurs
    # @raise [Gapic::Rest::ResumableUpload::DeadlineExceededError] If `upload_timeout` is exceeded
    # @raise [Gapic::Rest::ResumableUpload::BadResponseError] If an unexpected or malformed HTTP response
    #   is received
    # @raise [Gapic::Rest::ResumableUpload::UnseekableStreamError] If stream rewinding is required during
    #   recovery on an unseekable stream
    # @raise [Gapic::Rest::ResumableUpload::StreamMismatchError] If stream content or length does not match
    #   the resumed upload
    # @raise [Gapic::Rest::ResumableUpload::UploadRejectedError] If the server explicitly rejects the upload
    # @raise [Gapic::Common::Error] Any other subclass signals a protocol implementation bug rather than a
    #   caller or server error
    #
    def resume stream:,
               resume_handle: nil,
               content_type: nil,
               upload_size: nil,
               upload_timeout: nil,
               on_progress: nil
      execute_run do
        verify_stream_at_origin stream
        handle = resolve_resume_handle resume_handle
        client_stub = @client_stub_proc.call
        config = ::Gapic::Rest::ResumableUpload::ResumeUploadConfig.new(
          upload_url: handle.upload_url,
          chunk_size: handle.chunk_size,
          **run_config_args(stream: stream, content_type: content_type, upload_size: upload_size,
                            upload_timeout: upload_timeout, on_progress: on_progress)
        )
        build_driver client_stub, config
      end
    end

    ##
    # Returns the handle needed to resume the last run, carrying its upload URL and resolved chunk size.
    #
    # `nil` before the first run, and after any run that left nothing to resume: a completed upload is
    # finalized, and rejected and cancelled uploads are too.
    #
    # Each run replaces this value rather than accumulating handles, so it always describes the most
    # recent one. Starting a second upload therefore discards whatever the previous run left behind —
    # persist the handle first if the earlier upload still matters. A call that fails while building its
    # configuration does not count as a run: it never reaches a driver, so the earlier value survives.
    #
    # @return [Gapic::Rest::ResumableUpload::ResumeHandle, nil]
    def resume_handle
      @mutex.synchronize { @driver&.resume_handle }
    end

    ##
    # Returns whether the last run left an upload that can be resumed.
    #
    # @return [Boolean]
    def resumable?
      !resume_handle.nil?
    end

    ##
    # Returns whether a run is currently executing.
    #
    # @return [Boolean]
    def running?
      @mutex.synchronize { @running }
    end

    private

    ##
    # @private
    # Claims the single run slot, runs the driver built by the block, and releases the slot.
    #
    # The slot is claimed before the block runs, so a second concurrent run is rejected while this one is
    # still building its configuration. It is released in an `ensure`, so every exit — a clean return, a
    # protocol error, an `on_progress` callback raising, a `Thread#kill` — leaves the handle usable and the
    # driver retained. A failure inside the block leaves no driver retained at all, so a configuration
    # `ArgumentError` cannot disturb the resume handle of an earlier run.
    #
    # @yieldreturn [Gapic::Rest::ResumableUpload::Driver] Driver to run
    # @return [Object] Decoded final response
    def execute_run
      claim_run_slot
      begin
        driver = yield
        @mutex.synchronize { @driver = driver }
        run_driver driver
      ensure
        @mutex.synchronize { @running = false }
      end
    end

    ##
    # @private
    # Runs a driver and decodes its result, applying the caller's error handler to a failure.
    #
    # Only the run is wrapped. Argument and configuration errors are raised while the driver is still
    # being built, and reach the caller as themselves: they describe a call that was never made.
    #
    # @param driver [Gapic::Rest::ResumableUpload::Driver] Driver to run
    # @return [Object] Decoded final response
    def run_driver driver
      decode_response driver.run
    rescue ::StandardError => e
      raise wrap_error(e)
    end

    ##
    # @private
    # Marks a run as in flight, rejecting a second concurrent one.
    #
    # @return [void]
    # @raise [Gapic::Rest::ResumableUpload::SessionStateError] If a run is already in progress
    def claim_run_slot
      @mutex.synchronize do
        if @running
          raise ::Gapic::Rest::ResumableUpload::SessionStateError,
                "A run is already in progress for this upload"
        end
        @running = true
      end
    end

    ##
    # @private
    # Builds the driver for a run.
    #
    # @param client_stub [Gapic::Rest::ClientStub] Stub returned by `client_stub_proc`
    # @param config [Gapic::Rest::ResumableUpload::StartUploadConfig,
    #   Gapic::Rest::ResumableUpload::ResumeUploadConfig] Configuration for this run
    # @return [Gapic::Rest::ResumableUpload::Driver]
    def build_driver client_stub, config
      ::Gapic::Rest::ResumableUpload::Driver.new client_stub: client_stub,
                                                 config:      config,
                                                 method_name: @method_name
    end

    ##
    # @private
    # Returns the configuration members both run types share, mirroring
    # {Gapic::Rest::ResumableUpload::COMMON_MEMBERS}.
    #
    # @return [Hash{Symbol=>Object}]
    def run_config_args stream:, content_type:, upload_size:, upload_timeout:, on_progress:
      {
        stream:                     stream,
        upload_size:                upload_size,
        content_type:               content_type,
        timeout:                    upload_timeout,
        control_plane_retry_policy: @control_plane_retry_policy,
        data_plane_retry_policy:    @data_plane_retry_policy,
        on_progress:                on_progress
      }
    end

    ##
    # @private
    # Resolves the upload a resumed run targets.
    #
    # @param resume_handle [Gapic::Rest::ResumableUpload::ResumeHandle, nil] Explicit handle, if given
    # @return [Gapic::Rest::ResumableUpload::ResumeHandle]
    # @raise [ArgumentError] If no handle was given and the last run left none
    def resolve_resume_handle resume_handle
      return resume_handle if resume_handle

      handle = @mutex.synchronize { @driver&.resume_handle }
      if handle.nil?
        raise ArgumentError,
              "No upload to resume: this handle has not run, or its last run left nothing resumable. " \
              "Pass resume_handle: to resume an upload started elsewhere."
      end
      handle
    end

    ##
    # @private
    # Rejects a stream that is not positioned at byte 0. Streams that do not report a position are
    # trusted.
    #
    # @param stream [IO] Stream a resumed run will read
    # @return [void]
    # @raise [ArgumentError] If the stream reports a non-zero position
    def verify_stream_at_origin stream
      return unless stream.respond_to? :pos
      return if stream.pos.zero?

      raise ArgumentError, "Stream must be positioned at byte 0 to resume an upload (got pos #{stream.pos})"
    end

    ##
    # @private
    # Decodes the final response body into the handle's response type.
    #
    # A `nil` response type returns the raw body, exactly as the driver produced it. Generated call sites
    # always pass a message class; the raw form exists so this gem's own tests can assert on what the
    # server sent without decoding through a message type they do not have.
    #
    # @param body [String, nil] Raw body of the finalizing HTTP response
    # @return [Object] Decoded message, or the raw body when there is no response type
    def decode_response body
      return body if @response_type.nil?

      @response_type.decode_json body.to_s, ignore_unknown_fields: true
    end

    ##
    # @private
    # Applies the caller's error handler to a run failure.
    #
    # The handler returns the exception to raise. A replacement that loses the
    # {Gapic::Rest::ResumableUpload::HasResumeHandle} mixin is re-extended with it and given the original's
    # handle, so a library-specific error type cannot erase the fact that the upload is resumable.
    #
    # @param error [StandardError] Failure raised by the run
    # @return [Exception] Exception to raise in its place
    def wrap_error error
      return error unless @error_handler

      wrapped = @error_handler.call error
      return error if wrapped.nil? || wrapped.equal?(error)

      if error.is_a?(::Gapic::Rest::ResumableUpload::HasResumeHandle) &&
         !wrapped.is_a?(::Gapic::Rest::ResumableUpload::HasResumeHandle)
        wrapped.extend ::Gapic::Rest::ResumableUpload::HasResumeHandle
        wrapped.instance_variable_set :@resume_handle, error.resume_handle
      end
      wrapped
    end

    ##
    # @private
    # Stringifies the keys and values of the initiation headers, which generated clients carry as a
    # symbol-keyed metadata hash.
    #
    # @param headers [Hash, nil] Initiation headers
    # @return [Hash{String=>String}]
    def stringify_headers headers
      (headers || {}).to_h { |key, value| [key.to_s, value.to_s] }
    end
  end
end
