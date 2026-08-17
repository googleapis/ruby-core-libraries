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
    module ResumableUpload
      ##
      # @private
      # Event vocabulary emitted by the Driver and dispatched to Core/Rules.
      # Events are `outside-in` signaling. Something happened, e.g. a chunk of data
      # was successfully read, and the Driver is reporting that to Core/Rules.
      #
      module Event
        ##
        # @private
        # Signals the start of the upload session.
        #
        StartUpload = Data.define

        ##
        # @private
        # Signals the resumption of an existing upload session.
        #
        ResumeUpload = Data.define

        ##
        # @private
        # Signals that binary data was read from the stream into the Driver's buffer.
        #
        # @!attribute [r] bytes_buffered
        #   @return [Integer] Number of bytes currently held in the Driver buffer
        # @!attribute [r] eof
        #   @return [Boolean] Whether stream EOF was encountered during the read
        #
        ChunkRead = Data.define :bytes_buffered, :eof do
          ##
          # @private
          # Initializes a ChunkRead event.
          #
          # @param bytes_buffered [Integer] Number of bytes currently held in buffer
          # @param eof [Boolean] Whether stream EOF was encountered
          #
          def initialize bytes_buffered: 0, eof: false
            super bytes_buffered: bytes_buffered, eof: eof
          end
        end

        ##
        # @private
        # Signals a completed HTTP exchange over the wire (status, headers, body, error).
        #
        # @!attribute [r] status
        #   @return [Integer] HTTP status code
        # @!attribute [r] headers
        #   @return [Hash<String, String>] Response headers
        # @!attribute [r] body
        #   @return [String, nil] Response body
        # @!attribute [r] error
        #   @return [Gapic::Rest::Error, nil] Wrapped REST error if status >= 400
        #
        HttpResponse = Data.define :status, :headers, :body, :error do
          ##
          # @private
          # Initializes an HttpResponse event.
          #
          # @param status [Integer] HTTP status code
          # @param headers [Hash<String, String>] Response headers
          # @param body [String, nil] Response body
          # @param error [Gapic::Rest::Error, nil] Wrapped REST error
          #
          def initialize status:, headers: {}, body: nil, error: nil
            super status: status, headers: headers || {}, body: body, error: error
          end
        end

        ##
        # @private
        # Signals an HTTP request failure (e.g. request timeout, transport connection failure, or retries exhausted).
        #
        # @!attribute [r] kind
        #   @return [Symbol] Failure kind: `:timeout`, `:connection_failed`, or `:retries_exhausted`
        # @!attribute [r] message
        #   @return [String, nil] Human-readable failure summary
        # @!attribute [r] source_error
        #   @return [StandardError, nil] Original underlying exception
        #
        RequestFailed = Data.define :kind, :message, :source_error do
          ##
          # @private
          # Initializes a RequestFailed event.
          #
          # @param kind [Symbol] Failure kind (`:timeout`, `:connection_failed`, `:retries_exhausted`)
          # @param message [String, nil] Human-readable failure summary
          # @param source_error [StandardError, nil] Original underlying exception
          #
          def initialize kind:, message: nil, source_error: nil
            super kind: kind, message: message, source_error: source_error
          end
        end

        ##
        # @private
        # Signals a caller-requested session cancellation.
        #
        Cancel = Data.define

        ##
        # @private
        # Signals that the global monotonic clock exceeded the configured deadline.
        #
        GlobalDeadlineExceeded = Data.define
      end
    end
  end
end
