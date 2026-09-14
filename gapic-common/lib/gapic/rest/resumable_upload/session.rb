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

require "gapic/rest/resumable_upload/data_types"
require "gapic/rest/resumable_upload/driver"
require "gapic/rest/resumable_upload/errors"

module Gapic
  module Rest
    module ResumableUpload
      ##
      # Coordinates a resumable upload across its lifecycle.
      #
      # A Session performs exactly one run (`start` or `resume`), never both, never twice.
      #
      # ### Two-State Model
      # 1. **Unbound** (`!bound?`): Fresh session prior to execution. Permitted operations: `start`
      #    or `resume(...)`.
      # 2. **Bound** (`bound?`): Session has executed or bound to an upload URL. Permitted operations:
      #    none (`start` and `resume` both raise {SessionStateError}).
      #
      # Calling {resumable?} reports whether a new session can resume the upload (`!resume_handle.nil?`).
      # Completed uploads (`:success`), rejected uploads, and cancelled uploads are finalized and not
      # resumable (`resumable?` returns `false`, `resume_handle` returns `nil`).
      #
      class Session
        # @return [Gapic::Rest::ClientStub] Underlying REST client stub
        attr_reader :client_stub

        ##
        # Binary input stream to upload. The stream is assumed to be positioned at byte 0
        # (it is not rewound prior to reading) and is not closed after use.
        #
        # @return [IO]
        attr_reader :stream

        # @return [String] Initial endpoint URI for session initiation
        attr_reader :initial_url

        # @return [String, nil] Request payload for session initiation
        attr_reader :initial_body

        # @return [Hash<String, String>] Additional headers for initiation
        attr_reader :initial_headers

        # @return [Integer, nil] Total upload bytes if known upfront
        attr_reader :upload_size

        ##
        # Explicit chunk size in bytes. If `nil`, the protocol implementation assigns a default value.
        # The effective chunk size may be adjusted if the server specifies a required data granularity.
        #
        # @return [Integer, nil]
        attr_reader :chunk_size

        # @return [String, nil] MIME type of uploaded media
        attr_reader :content_type

        ##
        # Total upload timeout in seconds. If `nil`, the protocol implementation assigns a default value.
        #
        # @return [Numeric, nil]
        attr_reader :timeout

        # @return [Gapic::Common::RetryPolicy, Hash, nil] Retry policy for session initiation
        attr_reader :start_retry_policy

        # @return [Gapic::Common::RetryPolicy, Hash, nil] Retry policy for control commands
        attr_reader :control_plane_retry_policy

        # @return [Gapic::Common::RetryPolicy, Hash, nil] Retry policy for data commands
        attr_reader :data_plane_retry_policy

        ##
        # Callback invoked with {Progress} snapshots during upload execution.
        # Executed synchronously on the thread running the upload protocol; it must not block.
        # Exceptions raised inside the callback immediately abort the upload session and
        # propagate out of {#start} or {#resume}.
        #
        # @return [Proc, nil]
        attr_reader :on_progress

        # @return [Logger, nil] Logger instance
        attr_reader :logger

        ##
        # Initializes a new Resumable Upload Session.
        #
        # @param client_stub [Gapic::Rest::ClientStub] Underlying REST client stub
        # @param stream [IO] Binary input stream to upload. Precondition: assumed to be positioned at byte 0
        #   (not rewound prior to reading) and not closed after use.
        # @param initial_url [String] Initial endpoint URI for session initiation
        # @param initial_body [String, nil] Request payload for session initiation (defaults to nil)
        # @param initial_headers [Hash<String, String>] Additional headers for initiation
        # @param upload_size [Integer, nil] Total upload bytes if known upfront
        # @param chunk_size [Integer, nil] Explicit chunk size in bytes. If `nil`, the protocol implementation
        #   assigns a default value. The effective chunk size may be modified if the server specifies a required
        #   data granularity.
        # @param content_type [String, nil] MIME type of uploaded media
        # @param timeout [Numeric, nil] Total upload timeout in seconds. If `nil`, the protocol implementation
        #   assigns a default value.
        # @param start_retry_policy [Gapic::Common::RetryPolicy, Hash, nil] Initiation retry policy
        # @param control_plane_retry_policy [Gapic::Common::RetryPolicy, Hash, nil] Control retry policy
        # @param data_plane_retry_policy [Gapic::Common::RetryPolicy, Hash, nil] Data retry policy
        # @param on_progress [Proc, nil] Progress callback invoked as `->(progress)` with a {Progress} instance.
        #   Executed synchronously on the upload protocol thread; it must not block.
        #   Exceptions raised inside the callback abort the session and propagate out of {#start} or {#resume}.
        # @param logger [Logger, nil] Logger instance
        #
        def initialize client_stub:,
                       stream:,
                       initial_url:,
                       initial_body: nil,
                       initial_headers: {},
                       upload_size: nil,
                       chunk_size: nil,
                       content_type: nil,
                       timeout: nil,
                       start_retry_policy: nil,
                       control_plane_retry_policy: nil,
                       data_plane_retry_policy: nil,
                       on_progress: nil,
                       logger: nil
          @client_stub = client_stub
          @stream = stream
          @initial_url = initial_url
          @initial_body = initial_body
          @initial_headers = initial_headers || {}
          @upload_size = upload_size
          @chunk_size = chunk_size
          @content_type = content_type
          @timeout = timeout
          @start_retry_policy = start_retry_policy
          @control_plane_retry_policy = control_plane_retry_policy
          @data_plane_retry_policy = data_plane_retry_policy
          @on_progress = on_progress
          @logger = logger

          @mutex = Mutex.new
          @running = false
          @executed = false
          @upload_url = nil
          @last_driver = nil
        end

        ##
        # Returns the raw upload session URL if established.
        #
        # @return [String, nil]
        def upload_url
          @mutex.synchronize { upload_url_internal }
        end

        ##
        # Returns whether the session is bound to a server-side upload.
        #
        # @return [Boolean]
        def bound?
          @mutex.synchronize { bound_internal? }
        end

        ##
        # Returns the current {ResumeHandle} if the session is alive and resumable.
        # Completed uploads are not resumable (returns nil). Rejected uploads and
        # cancelled uploads are also finalized and not resumable, returning nil.
        #
        # @return [ResumeHandle, nil]
        def resume_handle
          @mutex.synchronize { resume_handle_internal }
        end

        ##
        # Returns whether a new session can resume the upload.
        # Completed uploads are not resumable (returns false). Rejected uploads and
        # cancelled uploads are also finalized and not resumable (returns false).
        #
        # @return [Boolean]
        def resumable?
          @mutex.synchronize { !resume_handle_internal.nil? }
        end

        ##
        # Returns whether a run is currently executing.
        #
        # @return [Boolean]
        def running?
          @mutex.synchronize { @running }
        end

        ##
        # Starts a new upload session on the server.
        #
        # A session performs exactly one run (`start` or `resume`). Calling `start` on an already-bound
        # or executed session raises {SessionStateError}. Precondition: the stream is assumed to be
        # positioned at byte 0 (the session does not rewind it before reading) and is not closed after use.
        #
        # @return [String, Object] Final response body upon completion
        # @raise [SessionStateError] If already bound/executed or if a run is currently in progress
        # @raise [RequestFailedError] If a transport error, timeout, or retry exhaustion occurs
        # @raise [DeadlineExceededError] If the global upload timeout is exceeded
        # @raise [BadResponseError] If an unexpected or malformed HTTP response is received
        # @raise [UnseekableStreamError] If stream rewinding is required during recovery on an unseekable stream
        # @raise [StreamMismatchError] If stream content or length does not match protocol expectations
        # @raise [InvalidTransitionError] If an unmatched event occurs for the current protocol state
        # @raise [UploadRejectedError] If the server explicitly rejects the upload session
        def start
          driver = nil
          @mutex.synchronize do
            raise SessionStateError, "A run is already in progress for this session" if @running
            raise SessionStateError, "Session has already executed a run" if bound_internal?

            @executed = true
            @running = true
            config = build_start_config
            driver = Driver.new client_stub: @client_stub, config: config, logger: @logger
          end

          execute_run driver
        end

        ##
        # Resumes an upload session using one of two explicit keyword forms:
        # 1. `resume(upload_url:, chunk_size:)`: Resumes with explicit URL and chunk size.
        # 2. `resume(resume_handle:)`: Resumes via {ResumeHandle}.
        #
        # A session performs exactly one run (`start` or `resume`). Resuming must be executed on a
        # fresh, unexecuted session. Precondition: the stream must be positioned at byte 0 (it is not
        # rewound prior to reading) and is not closed after use.
        # The Driver fast-forwards to the server's acknowledged offset (by seeking on seekable streams
        # or reading and discarding on unseekable streams).
        #
        # Completed uploads are not resumable; attempting to resume a completed session raises {SessionStateError}.
        #
        # @param upload_url [String, nil] Explicit upload URL
        # @param chunk_size [Integer, nil] Explicit chunk size
        # @param resume_handle [ResumeHandle, nil] Explicit resume handle
        # @return [String, Object] Final response body upon completion
        # @raise [ArgumentError] If argument shape is invalid, target upload is missing, or stream.pos != 0
        # @raise [SessionStateError] If already bound/executed or if a run is currently in progress
        # @raise [RequestFailedError] If a transport error, timeout, or retry exhaustion occurs
        # @raise [DeadlineExceededError] If the global upload timeout is exceeded
        # @raise [BadResponseError] If an unexpected or malformed HTTP response is received
        # @raise [UnseekableStreamError] If stream rewinding is required during recovery on an unseekable stream
        # @raise [StreamMismatchError] If stream content or length does not match the resumed upload
        # @raise [InvalidTransitionError] If an unmatched event occurs for the current protocol state
        # @raise [UploadRejectedError] If the server explicitly rejects the upload session
        def resume upload_url: nil,
                   chunk_size: nil,
                   resume_handle: nil
          target_url, target_chunk_size = resolve_resume_args(
            upload_url:    upload_url,
            chunk_size:    chunk_size,
            resume_handle: resume_handle
          )

          driver = nil
          @mutex.synchronize do
            raise SessionStateError, "A run is already in progress for this session" if @running
            raise SessionStateError, "Session has already executed a run" if bound_internal?

            if @stream.respond_to?(:pos) && !@stream.pos.zero?
              raise ArgumentError, "Stream must be positioned at byte 0 to resume an upload (got pos #{@stream.pos})"
            end

            @executed = true
            @running = true
            @upload_url = target_url
            config = build_resume_config target_url, target_chunk_size
            driver = Driver.new client_stub: @client_stub, config: config, logger: @logger
          end

          execute_run driver
        end

        private

        ##
        # @private
        # Returns the established upload URL without locking.
        #
        # @return [String, nil]
        def upload_url_internal
          @upload_url || @last_driver&.upload_url
        end

        ##
        # @private
        # Returns whether the session is bound without locking.
        #
        # @return [Boolean]
        def bound_internal?
          @executed || !upload_url_internal.nil?
        end

        ##
        # @private
        # Returns the current resume handle from the driver without locking.
        #
        # @return [ResumeHandle, nil]
        def resume_handle_internal
          @last_driver&.resume_handle
        end

        ##
        # @private
        # Builds configuration for a new upload session.
        #
        # @return [CompleteUploadConfig]
        def build_start_config
          CompleteUploadConfig.new(
            initial_url:                @initial_url,
            initial_body:               @initial_body,
            initial_headers:            @initial_headers,
            stream:                     @stream,
            upload_size:                @upload_size,
            chunk_size:                 @chunk_size,
            content_type:               @content_type,
            timeout:                    @timeout,
            start_retry_policy:         @start_retry_policy,
            control_plane_retry_policy: @control_plane_retry_policy,
            data_plane_retry_policy:    @data_plane_retry_policy,
            on_progress:                @on_progress
          )
        end

        ##
        # @private
        # Builds configuration for resuming an upload session.
        #
        # @param target_url [String] Target upload session URL
        # @param target_chunk_size [Integer] Effective chunk size in bytes
        # @return [ResumeUploadConfig]
        def build_resume_config target_url, target_chunk_size
          ResumeUploadConfig.new(
            upload_url:                 target_url,
            chunk_size:                 target_chunk_size,
            stream:                     @stream,
            upload_size:                @upload_size,
            content_type:               @content_type,
            timeout:                    @timeout,
            start_retry_policy:         @start_retry_policy,
            control_plane_retry_policy: @control_plane_retry_policy,
            data_plane_retry_policy:    @data_plane_retry_policy,
            on_progress:                @on_progress
          )
        end

        ##
        # @private
        # Validates and extracts target upload URL and chunk size from resume keyword arguments.
        #
        # @param upload_url [String, nil] Explicit upload URL
        # @param chunk_size [Integer, nil] Explicit chunk size
        # @param resume_handle [ResumeHandle, nil] Explicit resume handle
        # @return [Array<String, Integer>] Tuple of [upload_url, chunk_size]
        # @raise [ArgumentError] If arguments are missing or mutually exclusive
        def resolve_resume_args upload_url:, chunk_size:, resume_handle:
          if resume_handle
            raise ArgumentError, "Cannot pass both resume_handle and upload_url/chunk_size" if upload_url || chunk_size
            [resume_handle.upload_url, resume_handle.chunk_size]
          elsif upload_url
            raise ArgumentError, "Must provide chunk_size with upload_url" if chunk_size.nil?
            [upload_url, chunk_size]
          elsif chunk_size
            raise ArgumentError, "Cannot pass chunk_size without upload_url"
          else
            raise ArgumentError, "Must provide either resume_handle or upload_url and chunk_size"
          end
        end

        ##
        # @private
        # Executes the driver run and records the final upload URL and state.
        #
        # @param driver [Driver] Driver instance to run
        # @return [String, Object] Final response body upon completion
        def execute_run driver
          @mutex.synchronize { @last_driver = driver }
          result = driver.run
          @mutex.synchronize do
            @upload_url ||= driver.upload_url
            @running = false
          end
          result
        rescue StandardError
          @mutex.synchronize do
            @upload_url ||= driver.upload_url
            @running = false
          end
          raise
        end
      end
    end
  end
end
