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
      # Calling {#resumable?} reports whether a new session can resume the upload (`!resume_handle.nil?`).
      # Completed uploads (`:success`) and rejected uploads are finalized and not resumable
      # (`resumable?` returns `false`, `resume_handle` returns `nil`).
      #
      # ### Execution Model
      #
      # {#start} and {#resume} are synchronous: they block the calling thread for the entire duration of the
      # upload and return only on completion or failure. The `on_progress` callback runs on that same thread.
      #
      # The remaining readers ({#upload_url}, {#bound?}, {#resume_handle}, {#resumable?}, {#running?}) are
      # guarded by an internal mutex and may be called from another thread while a run is in progress. Values
      # read mid-run are a best-effort snapshot of a state the upload thread is still advancing.
      #
      # ### Where Arguments Live
      #
      # The constructor takes what both run types share: the client stub, the stream, `upload_size`,
      # `content_type`, `timeout`, the control- and data-plane retry policies, `on_progress` and `logger`.
      # Arguments that belong to one run live on the method performing it — `initial_url`, `initial_body`,
      # `initial_headers`, `chunk_size` and `start_retry_policy` on {#start}; `upload_url` and `chunk_size`,
      # or a {ResumeHandle}, on {#resume}.
      #
      # ### Recovering From a Failure
      #
      # A bound session never runs again, so recovery means constructing a new Session. Errors that carry a
      # resume handle include the {HasResumeHandle} mixin, which can be rescued directly to catch all of them:
      #
      # @example Resuming after a recoverable failure
      #   begin
      #     session.start initial_url: url
      #   rescue Gapic::Rest::ResumableUpload::HasResumeHandle => e
      #     raise unless e.resume_handle
      #     Session.new(client_stub: client_stub, stream: File.open(path, "rb"))
      #            .resume(resume_handle: e.resume_handle)
      #   end
      #
      # The replacement session needs a stream positioned at byte 0 of the whole object, not at the server's
      # acknowledged offset; {#resume} fast-forwards on its own. For an unseekable stream that means opening a
      # fresh one, since it cannot be rewound.
      #
      # ### Defaults
      #
      # * `chunk_size` defaults to 8 MB, then rounds down to a multiple of any chunk granularity the server
      #   requires.
      # * `timeout` defaults to `upload_size / 1 MB per second` when `upload_size` is known, floored at one
      #   hour, and to one hour flat when it is not.
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

        # @return [Integer, nil] Total upload bytes if known upfront
        attr_reader :upload_size

        # @return [String, nil] MIME type of uploaded media
        attr_reader :content_type

        ##
        # Total upload timeout in seconds, covering the whole run rather than any single request. When `nil`,
        # it resolves to `upload_size / 1 MB per second` floored at one hour if `upload_size` is known, and to
        # one hour flat otherwise. Zero and negative values are treated as `nil`.
        #
        # @return [Numeric, nil]
        attr_reader :timeout

        ##
        # Retry policy for control commands (query, cancel). A {Gapic::Common::RetryPolicy} replaces the
        # default policy outright; a Hash overrides only the settings it names.
        #
        # @return [Gapic::Common::RetryPolicy, Hash, nil]
        attr_reader :control_plane_retry_policy

        ##
        # Retry policy for data commands (upload, finalize). A {Gapic::Common::RetryPolicy} replaces the
        # default policy outright; a Hash overrides only the settings it names.
        #
        # @return [Gapic::Common::RetryPolicy, Hash, nil]
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
        # The constructor takes only what both run types share. Arguments specific to a single run live on
        # the method that performs it: initiation details on {#start}, the upload URL and chunk size on
        # {#resume}.
        #
        # @param client_stub [Gapic::Rest::ClientStub] Underlying REST client stub
        # @param stream [IO] Binary input stream to upload. Precondition: assumed to be positioned at byte 0
        #   (not rewound prior to reading) and not closed after use.
        # @param upload_size [Integer, nil] Total upload bytes if known upfront
        # @param content_type [String, nil] MIME type of uploaded media
        # @param timeout [Numeric, nil] Total upload timeout in seconds covering the whole run. When `nil`,
        #   resolves to `upload_size / 1 MB per second` floored at one hour if `upload_size` is known, and to
        #   one hour flat otherwise.
        # @param control_plane_retry_policy [Gapic::Common::RetryPolicy, Hash, nil] Control retry policy
        # @param data_plane_retry_policy [Gapic::Common::RetryPolicy, Hash, nil] Data retry policy
        # @param on_progress [Proc, nil] Progress callback invoked as `->(progress)` with a {Progress} instance.
        #   Executed synchronously on the upload protocol thread; it must not block.
        #   Exceptions raised inside the callback abort the session and propagate out of {#start} or {#resume}.
        # @param logger [Logger, nil] Logger instance
        #
        def initialize client_stub:,
                       stream:,
                       upload_size: nil,
                       content_type: nil,
                       timeout: nil,
                       control_plane_retry_policy: nil,
                       data_plane_retry_policy: nil,
                       on_progress: nil,
                       logger: nil
          @client_stub = client_stub
          @stream = stream
          @upload_size = upload_size
          @content_type = content_type
          @timeout = timeout
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
        # Blocks the calling thread until the upload completes or fails.
        #
        # @example Uploading a file with progress reporting
        #   session = Gapic::Rest::ResumableUpload::Session.new(
        #     client_stub:  client_stub,
        #     stream:       File.open("movie.mp4", "rb"),
        #     upload_size:  File.size("movie.mp4"),
        #     content_type: "video/mp4",
        #     on_progress:  ->(progress) { puts "#{progress.phase}: #{progress.bytes_uploaded} bytes" }
        #   )
        #   response = session.start initial_url: "https://example.googleapis.com/upload/v1/media"
        #
        # @param initial_url [String] Initial endpoint URI for session initiation
        # @param initial_body [String, nil] Request payload for session initiation
        # @param initial_headers [Hash<String, String>] Additional headers for the initiation request. Merged
        #   last, so a key given here overrides the protocol header the session would otherwise send,
        #   regardless of its casing.
        # @param chunk_size [Integer, nil] Requested chunk size in bytes, defaulting to 8 MB. The effective
        #   size is rounded down to a multiple of any chunk granularity the server requires, or raised to that
        #   granularity if it exceeds the requested size.
        # @param start_retry_policy [Gapic::Common::RetryPolicy, Hash, nil] Retry policy for the initiation
        #   request. A {Gapic::Common::RetryPolicy} replaces the default policy outright; a Hash overrides only
        #   the settings it names and leaves the remaining defaults, including retry codes and predicates, in
        #   place.
        # @return [String, Object] Final response body upon completion
        # @raise [ArgumentError] If `initial_url` is missing or blank, or a retry policy argument is neither a
        #   {Gapic::Common::RetryPolicy}, a Hash, nor `nil`
        # @raise [SessionStateError] If already bound/executed or if a run is currently in progress
        # @raise [RequestFailedError] If a transport error, timeout, or retry exhaustion occurs
        # @raise [DeadlineExceededError] If the global upload timeout is exceeded
        # @raise [BadResponseError] If an unexpected or malformed HTTP response is received
        # @raise [UnseekableStreamError] If stream rewinding is required during recovery on an unseekable stream
        # @raise [StreamMismatchError] If stream content or length does not match protocol expectations
        # @raise [InvalidTransitionError] If an unmatched event occurs for the current protocol state
        # @raise [UploadRejectedError] If the server explicitly rejects the upload session
        def start initial_url:,
                  initial_body: nil,
                  initial_headers: {},
                  chunk_size: nil,
                  start_retry_policy: nil
          config = build_start_config initial_url:        initial_url,
                                      initial_body:       initial_body,
                                      initial_headers:    initial_headers,
                                      chunk_size:         chunk_size,
                                      start_retry_policy: start_retry_policy

          driver = nil
          @mutex.synchronize do
            raise SessionStateError, "A run is already in progress for this session" if @running
            raise SessionStateError, "Session has already executed a run" if bound_internal?

            driver = Driver.new client_stub: @client_stub, config: config, logger: @logger
            @executed = true
            @running = true
          end

          execute_run driver
        end

        ##
        # Resumes an upload session using one of two explicit keyword forms:
        # 1. `resume(upload_url:, chunk_size:)`: Resumes with explicit URL and chunk size.
        # 2. `resume(resume_handle:)`: Resumes via {ResumeHandle}.
        #
        # A session performs exactly one run (`start` or `resume`). Resuming must be executed on a
        # fresh, unexecuted session. Blocks the calling thread until the upload completes or fails.
        #
        # A resumed run targets an upload the server has already created, so it takes no initiation
        # arguments; everything it needs beyond the constructor is on this method.
        #
        # ### Chunk size
        #
        # A chunk size must be given explicitly because the server reports chunk granularity during
        # initiation, which a resumed run skips. {ResumeHandle} carries the effective value from the original
        # run for exactly this reason.
        #
        # ### Stream position
        #
        # The stream must be positioned at byte 0 of the whole object, not at the server's acknowledged
        # offset, and is not closed after use. The Driver fast-forwards on its own, by seeking on seekable
        # streams or by reading and discarding on unseekable ones. An unseekable stream therefore has to be
        # freshly opened rather than rewound.
        #
        # Completed uploads are not resumable; attempting to resume a completed session raises {SessionStateError}.
        #
        # @example Resuming from a handle persisted by an earlier process
        #   handle = Gapic::Rest::ResumableUpload::ResumeHandle.new(
        #     upload_url: row[:upload_url],
        #     chunk_size: row[:chunk_size]
        #   )
        #   session = Gapic::Rest::ResumableUpload::Session.new(
        #     client_stub: client_stub,
        #     stream:      File.open("movie.mp4", "rb"),
        #     upload_size: File.size("movie.mp4")
        #   )
        #   response = session.resume resume_handle: handle
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

            config = build_resume_config target_url, target_chunk_size
            driver = Driver.new client_stub: @client_stub, config: config, logger: @logger
            @executed = true
            @running = true
            @upload_url = target_url
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
        # Returns the configuration members shared by both run types, mirroring
        # {ResumableUpload::COMMON_MEMBERS}.
        #
        # @return [Hash{Symbol=>Object}]
        def common_config_args
          {
            stream:                     @stream,
            upload_size:                @upload_size,
            content_type:               @content_type,
            timeout:                    @timeout,
            control_plane_retry_policy: @control_plane_retry_policy,
            data_plane_retry_policy:    @data_plane_retry_policy,
            on_progress:                @on_progress
          }
        end

        ##
        # @private
        # Builds configuration for a new upload session.
        #
        # @param initial_url [String] Initial endpoint URI for session initiation
        # @param initial_body [String, nil] Request payload for session initiation
        # @param initial_headers [Hash<String, String>, nil] Additional headers for initiation
        # @param chunk_size [Integer, nil] Requested chunk size in bytes
        # @param start_retry_policy [Gapic::Common::RetryPolicy, Hash, nil] Initiation retry policy
        # @return [StartUploadConfig]
        def build_start_config initial_url:, initial_body:, initial_headers:, chunk_size:, start_retry_policy:
          StartUploadConfig.new(
            initial_url:        initial_url,
            initial_body:       initial_body,
            initial_headers:    initial_headers || {},
            chunk_size:         chunk_size,
            start_retry_policy: start_retry_policy,
            **common_config_args
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
            upload_url: target_url,
            chunk_size: target_chunk_size,
            **common_config_args
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
