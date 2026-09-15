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
      # Instruction vocabulary emitted by Rules/Core to be executed by Driver.
      # The vocabulary is partitioned three ways ({CONTINUATION}, {TERMINAL}, {SIDE_EFFECT}),
      # and every instruction class must join exactly one list.
      #
      module Instruction
        ##
        # @private
        # Execute initiation request to establish upload session.
        #
        # @!attribute [r] url
        #   @return [String] Initial endpoint URI
        # @!attribute [r] headers
        #   @return [Hash<String, String>] Additional headers for initiation request
        # @!attribute [r] body
        #   @return [String, nil] Request payload for session initiation
        #
        SendStart = Data.define :url, :headers, :body do
          ##
          # @private
          # Initializes a SendStart instruction.
          #
          # @param url [String] Initial endpoint URI
          # @param headers [Hash<String, String>] Additional headers
          # @param body [String, nil] Request payload
          #
          def initialize url:, headers: {}, body: nil
            super url: url, headers: headers || {}, body: body
          end
        end

        ##
        # @private
        # Transmit buffered chunk starting at offset for length bytes.
        #
        # @!attribute [r] url
        #   @return [String] Session upload URL
        # @!attribute [r] offset
        #   @return [Integer] Byte offset within the full upload stream
        # @!attribute [r] length
        #   @return [Integer] Number of bytes to transmit from buffer
        # @!attribute [r] finalize
        #   @return [Boolean] Whether to append finalize command to upload request
        #
        SendChunk = Data.define :url, :offset, :length, :finalize do
          ##
          # @private
          # Initializes a SendChunk instruction.
          #
          # @param url [String] Session upload URL
          # @param offset [Integer] Byte offset within upload stream
          # @param length [Integer] Number of bytes to transmit
          # @param finalize [Boolean] Whether to combine upload and finalize commands
          #
          def initialize url:, offset:, length:, finalize: false
            super url: url, offset: offset, length: length, finalize: finalize
          end
        end

        ##
        # @private
        # Send standalone finalize command when all data bytes were already uploaded.
        #
        # @!attribute [r] url
        #   @return [String] Session upload URL
        #
        SendFinalize = Data.define :url do
          ##
          # @private
          # Initializes a SendFinalize instruction.
          #
          # @param url [String] Session upload URL
          #
          def initialize url:
            super url: url
          end
        end

        ##
        # @private
        # Query backend for current acknowledged offset.
        #
        # @!attribute [r] url
        #   @return [String] Session upload URL
        #
        SendQuery = Data.define :url do
          ##
          # @private
          # Initializes a SendQuery instruction.
          #
          # @param url [String] Session upload URL
          #
          def initialize url:
            super url: url
          end
        end

        ##
        # @private
        # Cancel upload session on backend.
        #
        # @!attribute [r] url
        #   @return [String] Session upload URL
        #
        SendCancel = Data.define :url do
          ##
          # @private
          # Initializes a SendCancel instruction.
          #
          # @param url [String] Session upload URL
          #
          def initialize url:
            super url: url
          end
        end

        ##
        # @private
        # Realign Driver in-memory buffer and stream position to match server_offset.
        #
        # @!attribute [r] server_offset
        #   @return [Integer] Acknowledged byte offset reported by server
        #
        RealignBuffer = Data.define :server_offset do
          ##
          # @private
          # Initializes a RealignBuffer instruction.
          #
          # @param server_offset [Integer] Target server byte offset
          #
          def initialize server_offset:
            super server_offset: server_offset
          end
        end

        ##
        # @private
        # Read from stream until in-memory buffer reaches target_bytesize or stream hits EOF.
        #
        # @!attribute [r] target_bytesize
        #   @return [Integer] Target buffer size in bytes
        #
        FillBuffer = Data.define :target_bytesize do
          ##
          # @private
          # Initializes a FillBuffer instruction.
          #
          # @param target_bytesize [Integer] Target buffer size in bytes
          #
          def initialize target_bytesize:
            super target_bytesize: target_bytesize
          end
        end

        ##
        # @private
        # Invoke user progress callback with a Progress instance.
        #
        # @!attribute [r] progress
        #   @return [Gapic::Rest::ResumableUpload::Progress] Progress notification snapshot
        #
        NotifyProgress = Data.define :progress do
          ##
          # @private
          # Initializes a NotifyProgress instruction.
          #
          # @param progress [Gapic::Rest::ResumableUpload::Progress] Progress notification snapshot
          #
          def initialize progress:
            super progress: progress
          end
        end

        ##
        # @private
        # Upload finalized cleanly; return response.
        #
        # @!attribute [r] response
        #   @return [Gapic::Rest::ResumableUpload::Event::HttpResponse] Final response object
        #
        TerminateSuccess = Data.define :response do
          ##
          # @private
          # Initializes a TerminateSuccess instruction.
          #
          # @param response [Gapic::Rest::ResumableUpload::Event::HttpResponse] Final response object
          #
          def initialize response:
            super response: response
          end
        end

        ##
        # @private
        # Terminate upload with error.
        #
        # @!attribute [r] error
        #   @return [StandardError] Terminal exception to raise
        #
        TerminateFailure = Data.define :error do
          ##
          # @private
          # Initializes a TerminateFailure instruction.
          #
          # @param error [StandardError] Terminal exception to raise
          #
          def initialize error:
            super error: error
          end
        end

        ##
        # @private
        # Instruction classes that produce a continuation event for the next step of the trampoline loop.
        # @return [Array<Class>]
        CONTINUATION = [
          FillBuffer,
          SendStart,
          SendChunk,
          SendFinalize,
          SendQuery,
          SendCancel
        ].freeze

        ##
        # @private
        # Instruction classes that terminate the upload run.
        # @return [Array<Class>]
        TERMINAL = [
          TerminateSuccess,
          TerminateFailure
        ].freeze

        ##
        # @private
        # Instruction classes that perform side effects without producing continuation events or terminating.
        # @return [Array<Class>]
        SIDE_EFFECT = [
          NotifyProgress,
          RealignBuffer
        ].freeze
      end
    end
  end
end
