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

module Gapic
  module Rest
    # rubocop:disable Metrics/ModuleLength
    module ResumableUpload
      ##
      # @private
      # Immutable configuration for initiating and executing a resumable upload session.
      #
      # @!attribute [r] initial_url
      #   @return [String] Initial endpoint URI for session initiation
      # @!attribute [r] initial_body
      #   @return [String, nil] Request payload for session initiation
      # @!attribute [r] initial_headers
      #   @return [Hash<String, String>] Additional headers for initiation
      # @!attribute [r] stream
      #   @return [IO] Binary input stream to upload
      # @!attribute [r] upload_size
      #   @return [Integer, nil] Total upload bytes if known upfront
      # @!attribute [r] chunk_size
      #   @return [Integer, nil] Explicit chunk size in bytes
      # @!attribute [r] content_type
      #   @return [String, nil] MIME type of uploaded media
      # @!attribute [r] timeout
      #   @return [Numeric, nil] Total upload timeout in seconds (zero/negative values treated as nil)
      # @!attribute [r] start_retry_policy
      #   @return [Gapic::Common::RetryPolicy, Hash, nil] Retry policy for session initiation (start).
      #     Passing a {Gapic::Common::RetryPolicy} replaces the default policy.
      #     Passing a Hash overrides specified settings while preserving unspecified defaults
      #     (such as retry codes and predicates).
      # @!attribute [r] control_plane_retry_policy
      #   @return [Gapic::Common::RetryPolicy, Hash, nil] Retry policy for session control commands (query/cancel).
      #     Passing a {Gapic::Common::RetryPolicy} replaces the default policy.
      #     Passing a Hash overrides specified settings while preserving unspecified defaults.
      # @!attribute [r] data_plane_retry_policy
      #   @return [Gapic::Common::RetryPolicy, Hash, nil] Retry policy for data transmission commands (upload/finalize).
      #     Passing a {Gapic::Common::RetryPolicy} replaces the default policy.
      #     Passing a Hash overrides specified settings while preserving unspecified defaults
      #     (such as retry codes and predicates).
      # @!attribute [r] on_progress
      #   @return [Proc, nil] Callback invoked as `->(progress)` with a {Progress} instance
      #
      CompleteUploadConfig = Data.define(
        :initial_url,
        :initial_body,
        :initial_headers,
        :stream,
        :upload_size,
        :chunk_size,
        :content_type,
        :timeout,
        :start_retry_policy,
        :control_plane_retry_policy,
        :data_plane_retry_policy,
        :on_progress
      ) do
        ##
        # @private
        # Initializes a new upload configuration.
        #
        # @param initial_url [String] Initial endpoint URI for session initiation
        # @param stream [IO] Binary input stream to upload
        # @param initial_body [String, nil] Request payload for session initiation
        # @param initial_headers [Hash<String, String>] Additional headers for initiation
        # @param upload_size [Integer, nil] Total upload bytes if known upfront
        # @param chunk_size [Integer, nil] Explicit chunk size in bytes
        # @param content_type [String, nil] MIME type of uploaded media
        # @param timeout [Numeric, nil] Total upload timeout in seconds (zero/negative values treated as nil)
        # @param start_retry_policy [Gapic::Common::RetryPolicy, Hash, nil] Retry policy for session initiation
        # @param control_plane_retry_policy [Gapic::Common::RetryPolicy, Hash, nil] Retry policy for control commands
        # @param data_plane_retry_policy [Gapic::Common::RetryPolicy, Hash, nil] Retry policy for data commands
        # @param on_progress [Proc, nil] Callback invoked as `->(progress)` with a {Progress} instance
        #
        def initialize initial_url:,
                       stream:,
                       initial_body: nil,
                       initial_headers: {},
                       upload_size: nil,
                       chunk_size: nil,
                       content_type: nil,
                       timeout: nil,
                       start_retry_policy: nil,
                       control_plane_retry_policy: nil,
                       data_plane_retry_policy: nil,
                       on_progress: nil
          super(
            initial_url:                initial_url,
            initial_body:               initial_body,
            initial_headers:            initial_headers || {},
            stream:                     stream,
            upload_size:                upload_size,
            chunk_size:                 chunk_size,
            content_type:               content_type,
            timeout:                    timeout,
            start_retry_policy:         start_retry_policy,
            control_plane_retry_policy: control_plane_retry_policy,
            data_plane_retry_policy:    data_plane_retry_policy,
            on_progress:                on_progress
          )
        end
      end

      ##
      # @private
      # Immutable configuration for resuming an existing upload session.
      #
      # @!attribute [r] upload_url
      #   @return [String] Session upload URL returned by Scotty backend
      # @!attribute [r] chunk_size
      #   @return [Integer] Explicit chunk size in bytes (must be a positive integer)
      # @!attribute [r] stream
      #   @return [IO] Binary input stream to upload
      # @!attribute [r] upload_size
      #   @return [Integer, nil] Total upload bytes if known upfront
      # @!attribute [r] content_type
      #   @return [String, nil] MIME type of uploaded media
      # @!attribute [r] timeout
      #   @return [Numeric, nil] Total upload timeout in seconds (zero/negative values treated as nil)
      # @!attribute [r] start_retry_policy
      #   @return [Gapic::Common::RetryPolicy, Hash, nil] Unused; preserved for interface parity with
      #     {CompleteUploadConfig}.
      # @!attribute [r] control_plane_retry_policy
      #   @return [Gapic::Common::RetryPolicy, Hash, nil] Retry policy for session control commands (query/cancel).
      #     Passing a {Gapic::Common::RetryPolicy} replaces the default policy.
      #     Passing a Hash overrides specified settings while preserving unspecified defaults.
      # @!attribute [r] data_plane_retry_policy
      #   @return [Gapic::Common::RetryPolicy, Hash, nil] Retry policy for data transmission commands (upload/finalize).
      #     Passing a {Gapic::Common::RetryPolicy} replaces the default policy.
      #     Passing a Hash overrides specified settings while preserving unspecified defaults
      #     (such as retry codes and predicates).
      # @!attribute [r] on_progress
      #   @return [Proc, nil] Callback invoked as `->(progress)` with a {Progress} instance
      #
      ResumeUploadConfig = Data.define(
        :upload_url,
        :chunk_size,
        :stream,
        :upload_size,
        :content_type,
        :timeout,
        :start_retry_policy,
        :control_plane_retry_policy,
        :data_plane_retry_policy,
        :on_progress
      ) do
        ##
        # @private
        # Initializes a new upload resume configuration.
        #
        # @param upload_url [String] Session upload URL
        # @param chunk_size [Integer] Explicit chunk size in bytes (must be a positive integer)
        # @param stream [IO] Binary input stream to upload
        # @param upload_size [Integer, nil] Total upload bytes if known upfront
        # @param content_type [String, nil] MIME type of uploaded media
        # @param timeout [Numeric, nil] Total upload timeout in seconds (zero/negative values treated as nil)
        # @param start_retry_policy [Gapic::Common::RetryPolicy, Hash, nil] Unused; preserved for parity
        # @param control_plane_retry_policy [Gapic::Common::RetryPolicy, Hash, nil] Retry policy for control commands
        # @param data_plane_retry_policy [Gapic::Common::RetryPolicy, Hash, nil] Retry policy for data commands
        # @param on_progress [Proc, nil] Callback invoked as `->(progress)` with a {Progress} instance
        # @raise [ArgumentError] If required arguments are missing or invalid
        #
        def initialize upload_url:,
                       chunk_size:,
                       stream:,
                       upload_size: nil,
                       content_type: nil,
                       timeout: nil,
                       start_retry_policy: nil,
                       control_plane_retry_policy: nil,
                       data_plane_retry_policy: nil,
                       on_progress: nil
          raise ArgumentError, "upload_url is required" if upload_url.nil? || upload_url.to_s.strip.empty?
          unless chunk_size.is_a?(Integer) && chunk_size.positive?
            raise ArgumentError, "chunk_size must be a positive integer"
          end
          raise ArgumentError, "stream is required" if stream.nil?

          super(
            upload_url:                 upload_url,
            chunk_size:                 chunk_size,
            stream:                     stream,
            upload_size:                upload_size,
            content_type:               content_type,
            timeout:                    timeout,
            start_retry_policy:         start_retry_policy,
            control_plane_retry_policy: control_plane_retry_policy,
            data_plane_retry_policy:    data_plane_retry_policy,
            on_progress:                on_progress
          )
        end
      end

      ##
      # Immutable progress snapshot passed to the `on_progress` callback.
      #
      # The `on_progress` callback runs synchronously on the same thread as the upload protocol
      # and must not block. Any exception raised inside the callback aborts the upload session
      # and propagates out of {Session#start} or {Session#resume}.
      #
      # @!attribute [r] phase
      #   @return [Symbol] Current upload phase, one of {Progress::PHASES}
      # @!attribute [r] bytes_uploaded
      #   @return [Integer] Cumulative bytes acknowledged by the server. Note that this is the
      #     server-confirmed offset and is not guaranteed to be monotonic — a server rewind during
      #     recovery can decrease this value.
      # @!attribute [r] total_bytes
      #   @return [Integer, nil] Total upload size in bytes if known, or nil
      #
      Progress = Data.define(
        :phase,
        :bytes_uploaded,
        :total_bytes
      ) do
        ##
        # Initializes a new progress snapshot.
        #
        # @param phase [Symbol] Current upload phase, one of {Progress::PHASES}
        # @param bytes_uploaded [Integer] Cumulative bytes acknowledged by the server
        # @param total_bytes [Integer, nil] Total upload size in bytes if known, or nil
        # @raise [ArgumentError] If the phase is not one of {Progress::PHASES}
        #
        def initialize phase:, bytes_uploaded:, total_bytes: nil
          # Must use `self.class::` to access constants from the class scope
          unless self.class::PHASES.include? phase
            raise ArgumentError, "Invalid phase: #{phase.inspect}. Expected one of #{self.class::PHASES.inspect}"
          end

          super(
            phase:          phase,
            bytes_uploaded: bytes_uploaded,
            total_bytes:    total_bytes
          )
        end
      end

      ##
      # Allowed lifecycle phases for an upload session.
      # @return [Array<Symbol>]
      Progress::PHASES = [:initiating, :uploading, :recovering, :finalizing, :cancelling, :completed].freeze

      ##
      # Immutable handle containing parameters necessary to resume an in-progress upload session.
      # These parameters are provided by the server and can be persisted to resume the upload
      # at a later time.
      #
      # @!attribute [r] upload_url
      #   @return [String] Upload session URL provided by the server
      # @!attribute [r] chunk_size
      #   @return [Integer] Effective chunk size in bytes
      #
      ResumeHandle = Data.define(
        :upload_url,
        :chunk_size
      ) do
        ##
        # Initializes a new resume handle.
        #
        # @param upload_url [String] Upload session URL provided by the server
        # @param chunk_size [Integer] Effective chunk size in bytes
        #
        def initialize upload_url:, chunk_size:
          super(
            upload_url: upload_url,
            chunk_size: chunk_size
          )
        end
      end

      ##
      # @private
      # Immutable state snapshot representing the current protocol progression.
      #
      # @!attribute [r] status
      #   @return [Symbol] Protocol lifecycle status symbol
      # @!attribute [r] upload_url
      #   @return [String, nil] Session upload URL returned by Scotty backend
      # @!attribute [r] offset
      #   @return [Integer] Contiguous bytes acknowledged by server
      # @!attribute [r] chunk_size
      #   @return [Integer] Resolved effective chunk size in bytes
      # @!attribute [r] chunk_granularity
      #   @return [Integer, nil] Alignment modulus returned by server
      # @!attribute [r] in_flight_length
      #   @return [Integer] Byte length of in-flight chunk currently being transmitted
      # @!attribute [r] last_error
      #   @return [StandardError, nil] Terminal exception if in an error or rejected status
      #
      State = Data.define(
        :status,
        :upload_url,
        :offset,
        :chunk_size,
        :chunk_granularity,
        :in_flight_length,
        :last_error
      ) do
        ##
        # @private
        # Initializes a protocol state snapshot.
        #
        # @param status [Symbol] Protocol lifecycle status symbol
        # @param upload_url [String, nil] Session upload URL
        # @param offset [Integer] Contiguous bytes acknowledged by server
        # @param chunk_size [Integer] Resolved effective chunk size in bytes
        # @param chunk_granularity [Integer, nil] Alignment modulus returned by server
        # @param in_flight_length [Integer] Byte length of in-flight chunk
        # @param last_error [StandardError, nil] Terminal exception
        #
        def initialize status: :initializing,
                       upload_url: nil,
                       offset: 0,
                       chunk_size: Rules::DEFAULT_CHUNK_SIZE,
                       chunk_granularity: nil,
                       in_flight_length: 0,
                       last_error: nil
          super(
            status:            status,
            upload_url:        upload_url,
            offset:            offset,
            chunk_size:        chunk_size,
            chunk_granularity: chunk_granularity,
            in_flight_length:  in_flight_length,
            last_error:        last_error
          )
        end
      end

      ##
      # @private
      # Immutable decision snapshot emitted by Rules.decide.
      #
      # @!attribute [r] from_status
      #   @return [Symbol] The protocol status before the transition
      # @!attribute [r] shape
      #   @return [Symbol] The canonical event shape
      # @!attribute [r] recipe
      #   @return [Symbol] Selected transition recipe method name
      # @!attribute [r] next_state
      #   @return [State] The new protocol state snapshot after transition
      # @!attribute [r] instructions
      #   @return [Array<Object>] Emitted instructions for the Driver
      #
      Decision = Data.define(
        :from_status,
        :shape,
        :recipe,
        :next_state,
        :instructions
      ) do
        ##
        # @private
        # Initializes a decision snapshot.
        #
        # @param from_status [Symbol] The protocol status before the transition
        # @param shape [Symbol] The canonical event shape
        # @param recipe [Symbol] Selected transition recipe method name
        # @param next_state [State] Resulting protocol state snapshot
        # @param instructions [Array<Object>] Emitted instructions for the Driver
        #
        def initialize from_status:, shape:, recipe:, next_state:, instructions: []
          super(
            from_status:  from_status,
            shape:        shape,
            recipe:       recipe,
            next_state:   next_state,
            instructions: instructions
          )
        end
      end
    end
    # rubocop:enable Metrics/ModuleLength
  end
end
