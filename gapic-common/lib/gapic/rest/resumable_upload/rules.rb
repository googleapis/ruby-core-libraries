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

require "gapic/common/error"
require "gapic/rest/resumable_upload/errors"
require "gapic/rest/resumable_upload/data_types"
require "gapic/rest/resumable_upload/events"
require "gapic/rest/resumable_upload/instructions"

module Gapic
  module Rest
    module ResumableUpload
      ##
      # @private
      # Pure functional transition engine for the Resumable Upload Protocol.
      # Contains zero side-effects and zero persistent state.
      #
      # rubocop:disable Metrics/ModuleLength
      module Rules
        ##
        # @private
        # Default chunk size in bytes (8 MB).
        # @return [Integer]
        DEFAULT_CHUNK_SIZE = 8_388_608 # 8 MB

        ##
        # @private
        # HTTP status codes eligible for Category 2 (recovery) handling.
        # @return [Array<Integer>]
        CAT2_STATUS_CODES = [400, 408, 409, 412, 416, 429, 499].freeze

        ##
        # @private
        # HTTP status codes that are immediately fatal and non-retriable.
        # @return [Array<Integer>]
        FATAL_STATUS_CODES = [401, 403, 404, 405, 410, 413, 415].freeze

        ##
        # @private
        # Human-readable state descriptions for error reporting.
        # @return [Hash<Symbol, String>]
        STATE_DESCRIPTIONS = {
          initializing:                "initializing upload",
          starting:                    "initiating upload session",
          transmission_reading:        "reading chunk from stream",
          transmission_sending:        "sending a chunk of data",
          finalizing_sending_upload:   "sending final data chunk",
          finalizing_sending_finalize: "sending finalize command",
          recovery:                    "querying upload offset for recovery",
          cancelling:                  "cancelling upload session",
          success:                     "in completed upload state",
          cancelled:                   "in cancelled upload state",
          error:                       "in error state",
          rejected:                    "in rejected upload state"
        }.freeze

        ##
        # @private
        # Canonical list of recipe symbols emitted by {Rules.decide}.
        # @return [Array<Symbol>]
        RECIPES = [
          :start_session,
          :resume_session,
          :begin_transmission,
          :send_chunk,
          :send_upload_finalize,
          :send_finalize,
          :ack_chunk,
          :enter_recovery,
          :retry_recovery,
          :realign_from_recovery,
          :complete_upload_with_data,
          :complete_upload_finalized,
          :cancel_session,
          :complete_cancellation,
          :ignore_duplicate_cancel,
          :fail_with_deadline_exceeded,
          :fail_with_rejected,
          :fail_with_bad_response,
          :fail_with_request_error,
          :fail_with_unmatched_transition
        ].freeze

        ##
        # @private
        # Mapping of notifying recipes to their emitted {Progress} phase.
        # @return [Hash<Symbol, Symbol>]
        RECIPE_PHASES = {
          start_session:             :initiating,
          resume_session:            :initiating,
          begin_transmission:        :uploading,
          ack_chunk:                 :uploading,
          realign_from_recovery:     :uploading,
          enter_recovery:            :recovering,
          send_upload_finalize:      :finalizing,
          send_finalize:             :finalizing,
          complete_upload_with_data: :completed,
          complete_upload_finalized: :completed,
          cancel_session:            :cancelling
        }.freeze

        ##
        # @private
        # Recipes that do not emit {Instruction::NotifyProgress}.
        # @return [Array<Symbol>]
        NON_NOTIFYING_RECIPES = [
          :send_chunk,
          :retry_recovery,
          :complete_cancellation,
          :ignore_duplicate_cancel,
          :fail_with_deadline_exceeded,
          :fail_with_rejected,
          :fail_with_bad_response,
          :fail_with_request_error,
          :fail_with_unmatched_transition
        ].freeze

        ##
        # @private
        # Classifies incoming event into a canonical shape symbol.
        #
        # @param event [Object] Input event
        # @return [Symbol] Canonical event shape
        def self.shape_of event
          case event
          when Event::StartUpload, Event::StartUpload.singleton_class
            :start_upload
          when Event::ResumeUpload, Event::ResumeUpload.singleton_class
            :resume_upload
          when Event::ChunkRead
            classify_chunk_read event
          when Event::Cancel, Event::Cancel.singleton_class
            :user_cancel
          when Event::GlobalDeadlineExceeded, Event::GlobalDeadlineExceeded.singleton_class
            :global_deadline_exceeded
          when Event::RequestFailed
            classify_request_failed event
          when Event::HttpResponse
            classify_http_response event
          when Class
            classify_event_class event
          else
            :unknown
          end
        end

        ##
        # @private
        # Top-level transition decision engine. Matches [state.status, shape].
        #
        # @param state [State] Current state
        # @param event [Object] Input event
        # @param config [CompleteUploadConfig] Static configuration
        # @return [Decision] Decision snapshot
        #
        # rubocop:disable Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity,Metrics/MethodLength
        def self.decide state, event, config
          shape = shape_of event

          recipe = case [state.status, shape]
                   in [:initializing, :start_upload]
                     :start_session
                   in [:initializing, :resume_upload]
                     :resume_session
                   in [:starting, :response_active]
                     :begin_transmission
                   in [:transmission_reading, :chunk_read_full]
                     :send_chunk
                   in [:transmission_reading, :chunk_read_eof_with_data]
                     :send_upload_finalize
                   in [:transmission_reading, :chunk_read_eof_empty]
                     :send_finalize
                   in [:transmission_sending, :response_active]
                     :ack_chunk
                   in [:transmission_sending | :finalizing_sending_upload | :finalizing_sending_finalize,
                       :response_cat2 | :request_connection_failed | :request_timeout]
                     :enter_recovery
                   in [:finalizing_sending_upload, :response_final]
                     :complete_upload_with_data
                   in [:finalizing_sending_finalize | :recovery, :response_final]
                     :complete_upload_finalized
                   in [:recovery, :response_active]
                     :realign_from_recovery
                   in [:recovery, :response_cat2]
                     :retry_recovery
                   in [:cancelling, :response_cancelled]
                     :complete_cancellation
                   in [:cancelling, :user_cancel]
                     :ignore_duplicate_cancel
                   in [_, :global_deadline_exceeded]
                     :fail_with_deadline_exceeded
                   in [_, :user_cancel]
                     :cancel_session
                   in [:starting | :transmission_sending | :finalizing_sending_upload |
                       :finalizing_sending_finalize | :recovery | :cancelling, :response_rejected]
                     :fail_with_rejected
                   in [:starting | :cancelling, :response_cat2] |
                      [:starting | :transmission_sending | :finalizing_sending_upload |
                       :finalizing_sending_finalize | :recovery | :cancelling, :response_fatal_bad_response]
                     :fail_with_bad_response
                   in [:starting | :transmission_sending | :finalizing_sending_upload |
                       :finalizing_sending_finalize | :recovery | :cancelling,
                       :request_retries_exhausted | :request_connection_failed | :request_timeout |
                       :request_failed_unknown]
                     :fail_with_request_error
                   else
                     :fail_with_unmatched_transition
                   end

          raise ArgumentError, "unknown recipe: #{recipe}" unless RECIPES.include? recipe

          next_state, instructions = public_send recipe, state, event, config
          Decision.new(
            from_status:  state.status,
            shape:        shape,
            recipe:       recipe,
            next_state:   next_state,
            instructions: instructions
          )
        end
        # rubocop:enable Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity,Metrics/MethodLength

        ##
        # @private
        # Top-level transition router. Matches [state.status, shape].
        #
        # @param state [State] Current state
        # @param event [Object] Input event
        # @param config [CompleteUploadConfig] Static configuration
        # @return [Array<State, Array<Object>>] Tuple of [next_state, instructions]
        def self.step state, event, config
          decision = decide state, event, config
          [decision.next_state, decision.instructions]
        end

        ##
        # @private
        # Initiates the upload session.
        #
        # @param state [State] Current state
        # @param _event [Object] Dispatched event
        # @param config [CompleteUploadConfig] Session configuration
        # @return [Array<State, Array<Object>>] Tuple of [next_state, instructions]
        def self.start_session state, _event, config
          next_state = state.with status: :starting
          progress = Progress.new phase: :initiating, bytes_uploaded: next_state.offset, total_bytes: config.upload_size
          instructions = [
            Instruction::NotifyProgress.new(progress: progress),
            Instruction::SendStart.new(
              url:     config.initial_url,
              headers: config.initial_headers,
              body:    config.initial_body
            )
          ]
          [next_state, instructions]
        end

        ##
        # @private
        # Resumes an existing upload session by transitioning to recovery and querying backend offset.
        #
        # @param state [State] Current state
        # @param _event [Object] Dispatched event
        # @param config [ResumeUploadConfig] Resume session configuration
        # @return [Array<State, Array<Object>>] Tuple of [next_state, instructions]
        def self.resume_session state, _event, config
          next_state = state.with(
            status:     :recovery,
            upload_url: config.upload_url,
            chunk_size: config.chunk_size,
            offset:     0
          )
          progress = Progress.new(
            phase:          :initiating,
            bytes_uploaded: 0,
            total_bytes:    config.upload_size
          )
          instructions = [
            Instruction::NotifyProgress.new(progress: progress),
            Instruction::SendQuery.new(url: config.upload_url)
          ]
          [next_state, instructions]
        end

        ##
        # @private
        # Processes initiation response and begins data reading.
        #
        # @param state [State] Current state
        # @param event [Event::HttpResponse] Initiation response
        # @param config [CompleteUploadConfig] Session configuration
        # @return [Array<State, Array<Object>>] Tuple of [next_state, instructions]
        def self.begin_transmission state, event, config
          granularity_str = header_value event.headers, "x-goog-upload-chunk-granularity"
          granularity = granularity_str&.to_i
          chunk_size = resolve_chunk_size config.chunk_size, granularity
          upload_url = header_value event.headers, "x-goog-upload-url"
          next_state = state.with(
            status:            :transmission_reading,
            upload_url:        upload_url,
            chunk_granularity: granularity,
            chunk_size:        chunk_size,
            offset:            0,
            in_flight_length:  0
          )
          progress = Progress.new phase: :uploading, bytes_uploaded: next_state.offset, total_bytes: config.upload_size
          instructions = [
            Instruction::NotifyProgress.new(progress: progress),
            Instruction::FillBuffer.new(target_bytesize: chunk_size)
          ]
          [next_state, instructions]
        end

        ##
        # @private
        # Emits instruction to transmit a filled data chunk.
        #
        # @param state [State] Current state
        # @param event [Event::ChunkRead] Chunk read event
        # @param _config [CompleteUploadConfig] Session configuration
        # @return [Array<State, Array<Object>>] Tuple of [next_state, instructions]
        def self.send_chunk state, event, _config
          next_state = state.with(
            status:           :transmission_sending,
            in_flight_length: event.bytes_buffered
          )
          instructions = [
            Instruction::SendChunk.new(
              url:      state.upload_url,
              offset:   state.offset,
              length:   event.bytes_buffered,
              finalize: false
            )
          ]
          [next_state, instructions]
        end

        ##
        # @private
        # Emits instruction to transmit the final data chunk with finalize.
        #
        # @param state [State] Current state
        # @param event [Event::ChunkRead] Chunk read event with EOF
        # @param config [CompleteUploadConfig] Session configuration
        # @return [Array<State, Array<Object>>] Tuple of [next_state, instructions]
        def self.send_upload_finalize state, event, config
          next_state = state.with(
            status:           :finalizing_sending_upload,
            in_flight_length: event.bytes_buffered
          )
          progress = Progress.new phase: :finalizing, bytes_uploaded: next_state.offset, total_bytes: config.upload_size
          instructions = [
            Instruction::NotifyProgress.new(progress: progress),
            Instruction::SendChunk.new(
              url:      state.upload_url,
              offset:   state.offset,
              length:   event.bytes_buffered,
              finalize: true
            )
          ]
          [next_state, instructions]
        end

        ##
        # @private
        # Emits instruction to send a zero-length finalize command.
        #
        # @param state [State] Current state
        # @param _event [Object] Dispatched event
        # @param config [CompleteUploadConfig] Session configuration
        # @return [Array<State, Array<Object>>] Tuple of [next_state, instructions]
        def self.send_finalize state, _event, config
          next_state = state.with(
            status:           :finalizing_sending_finalize,
            in_flight_length: 0
          )
          progress = Progress.new phase: :finalizing, bytes_uploaded: next_state.offset, total_bytes: config.upload_size
          instructions = [
            Instruction::NotifyProgress.new(progress: progress),
            Instruction::SendFinalize.new(url: state.upload_url)
          ]
          [next_state, instructions]
        end

        ##
        # @private
        # Acknowledges transmitted chunk and advances offset.
        #
        # @param state [State] Current state
        # @param _event [Object] Dispatched event
        # @param config [CompleteUploadConfig] Session configuration
        # @return [Array<State, Array<Object>>] Tuple of [next_state, instructions]
        def self.ack_chunk state, _event, config
          new_offset = state.offset + state.in_flight_length
          next_state = state.with(
            status:           :transmission_reading,
            offset:           new_offset,
            in_flight_length: 0
          )
          progress = Progress.new phase: :uploading, bytes_uploaded: new_offset, total_bytes: config.upload_size
          instructions = [
            Instruction::NotifyProgress.new(progress: progress),
            Instruction::RealignBuffer.new(server_offset: new_offset),
            Instruction::FillBuffer.new(target_bytesize: state.chunk_size)
          ]
          [next_state, instructions]
        end

        ##
        # @private
        # Transitions to recovery state to query backend byte offset.
        #
        # @param state [State] Current state
        # @param _event [Object] Dispatched event
        # @param config [CompleteUploadConfig] Session configuration
        # @return [Array<State, Array<Object>>] Tuple of [next_state, instructions]
        def self.enter_recovery state, _event, config
          next_state = state.with(
            status:           :recovery,
            in_flight_length: 0
          )
          progress = Progress.new phase: :recovering, bytes_uploaded: next_state.offset, total_bytes: config.upload_size
          instructions = [
            Instruction::NotifyProgress.new(progress: progress),
            Instruction::SendQuery.new(url: state.upload_url)
          ]
          [next_state, instructions]
        end

        ##
        # @private
        # Retries offset query during recovery.
        #
        # @param state [State] Current state
        # @param _event [Object] Dispatched event
        # @param _config [CompleteUploadConfig] Session configuration
        # @return [Array<State, Array<Object>>] Tuple of [next_state, instructions]
        def self.retry_recovery state, _event, _config
          next_state = state.with(
            status:           :recovery,
            in_flight_length: 0
          )
          [next_state, [Instruction::SendQuery.new(url: state.upload_url)]]
        end

        ##
        # @private
        # Completes upload when final chunk transmission succeeds.
        #
        # @param state [State] Current state
        # @param event [Event::HttpResponse] Final HTTP response
        # @param _config [CompleteUploadConfig] Session configuration
        # @return [Array<State, Array<Object>>] Tuple of [next_state, instructions]
        def self.complete_upload_with_data state, event, _config
          new_offset = state.offset + state.in_flight_length
          next_state = state.with(
            status:           :success,
            offset:           new_offset,
            in_flight_length: 0
          )
          progress = Progress.new phase: :completed, bytes_uploaded: new_offset, total_bytes: new_offset
          instructions = [
            Instruction::NotifyProgress.new(progress: progress),
            Instruction::TerminateSuccess.new(response: event)
          ]
          [next_state, instructions]
        end

        ##
        # @private
        # Completes upload when standalone finalize succeeds.
        #
        # @param state [State] Current state
        # @param event [Event::HttpResponse] Final HTTP response
        # @param _config [CompleteUploadConfig] Session configuration
        # @return [Array<State, Array<Object>>] Tuple of [next_state, instructions]
        def self.complete_upload_finalized state, event, _config
          next_state = state.with(
            status:           :success,
            in_flight_length: 0
          )
          progress = Progress.new phase: :completed, bytes_uploaded: next_state.offset, total_bytes: next_state.offset
          instructions = [
            Instruction::NotifyProgress.new(progress: progress),
            Instruction::TerminateSuccess.new(response: event)
          ]
          [next_state, instructions]
        end

        ##
        # @private
        # Realigns buffer and resumes transmission from recovered offset.
        #
        # @param state [State] Current state
        # @param event [Event::HttpResponse] Query response containing acknowledged offset
        # @param config [CompleteUploadConfig] Session configuration
        # @return [Array<State, Array<Object>>] Tuple of [next_state, instructions]
        def self.realign_from_recovery state, event, config
          server_offset_str = header_value event.headers, "x-goog-upload-size-received"
          server_offset = server_offset_str.to_i
          next_state = state.with(
            status:           :transmission_reading,
            offset:           server_offset,
            in_flight_length: 0
          )
          progress = Progress.new phase: :uploading, bytes_uploaded: server_offset, total_bytes: config.upload_size
          instructions = [
            Instruction::NotifyProgress.new(progress: progress),
            Instruction::RealignBuffer.new(server_offset: server_offset),
            Instruction::FillBuffer.new(target_bytesize: state.chunk_size)
          ]
          [next_state, instructions]
        end

        ##
        # @private
        # Completes session cancellation and emits failure instruction.
        #
        # @param state [State] Current state
        # @param event [Object] Cancellation response event
        # @param _config [CompleteUploadConfig] Session configuration
        # @return [Array<State, Array<Object>>] Tuple of [next_state, instructions]
        def self.complete_cancellation state, event, _config
          err = UploadCancelledError.from event
          next_state = state.with status: :cancelled, in_flight_length: 0, last_error: err
          [next_state, [Instruction::TerminateFailure.new(error: err)]]
        end

        ##
        # @private
        # Ignores redundant cancel signal when cancellation is already in progress.
        #
        # @param state [State] Current state
        # @param _event [Object] Dispatched event
        # @param _config [CompleteUploadConfig] Session configuration
        # @return [Array<State, Array<Object>>] Tuple of [next_state, instructions]
        def self.ignore_duplicate_cancel state, _event, _config
          [state, []]
        end

        ##
        # @private
        # Initiates session cancellation request.
        #
        # @param state [State] Current state
        # @param _event [Object] Dispatched event
        # @param config [CompleteUploadConfig] Session configuration
        # @return [Array<State, Array<Object>>] Tuple of [next_state, instructions]
        def self.cancel_session state, _event, config
          next_state = state.with status: :cancelling
          progress = Progress.new phase: :cancelling, bytes_uploaded: next_state.offset, total_bytes: config.upload_size
          instructions = [
            Instruction::NotifyProgress.new(progress: progress),
            Instruction::SendCancel.new(url: state.upload_url)
          ]
          [next_state, instructions]
        end

        ##
        # @private
        # Extracts a {ResumeHandle} from current protocol state.
        # Completed uploads (`:success`), rejected uploads (`:rejected`), and cancelled uploads
        # (`:cancelled`) are finalized and not resumable, returning `nil`. Completed uploads are not resumable.
        #
        # @param state [State] Protocol state
        # @return [ResumeHandle, nil] Resume handle if upload URL is established and resumable, or nil
        def self.resume_handle_from state
          return nil if state.nil? || state.upload_url.nil? || [:rejected, :cancelled, :success].include?(state.status)

          ResumeHandle.new upload_url: state.upload_url, chunk_size: state.chunk_size
        end

        ##
        # @private
        # Fails upload due to exceeded execution deadline.
        #
        # @param state [State] Current state
        # @param _event [Object] Dispatched event
        # @param _config [CompleteUploadConfig] Session configuration
        # @return [Array<State, Array<Object>>] Tuple of [next_state, instructions]
        def self.fail_with_deadline_exceeded state, _event, _config
          handle = resume_handle_from state
          err = DeadlineExceededError.new resume_handle: handle
          next_state = state.with(
            status:           :error,
            in_flight_length: 0,
            last_error:       err
          )
          [next_state, [Instruction::TerminateFailure.new(error: err)]]
        end

        ##
        # @private
        # Fails upload when backend explicitly rejects session.
        #
        # @param state [State] Current state
        # @param event [Event::HttpResponse] Rejected HTTP response
        # @param _config [CompleteUploadConfig] Session configuration
        # @return [Array<State, Array<Object>>] Tuple of [next_state, instructions]
        def self.fail_with_rejected state, event, _config
          err = UploadRejectedError.from event
          next_state = state.with(
            status:           :rejected,
            in_flight_length: 0,
            last_error:       err
          )
          [next_state, [Instruction::TerminateFailure.new(error: err)]]
        end

        ##
        # @private
        # Fails upload when an unrecoverable HTTP response is encountered.
        #
        # @param state [State] Current state
        # @param event [Event::HttpResponse] Fatal HTTP response
        # @param _config [CompleteUploadConfig] Session configuration
        # @return [Array<State, Array<Object>>] Tuple of [next_state, instructions]
        def self.fail_with_bad_response state, event, _config
          handle = resume_handle_from state
          err = BadResponseError.from event, resume_handle: handle
          next_state = state.with(
            status:           :error,
            in_flight_length: 0,
            last_error:       err
          )
          [next_state, [Instruction::TerminateFailure.new(error: err)]]
        end

        ##
        # @private
        # Fails upload when an unrecoverable network or request error occurs.
        #
        # @param state [State] Current state
        # @param event [Event::RequestFailed] Request failure event
        # @param _config [CompleteUploadConfig] Session configuration
        # @return [Array<State, Array<Object>>] Tuple of [next_state, instructions]
        def self.fail_with_request_error state, event, _config
          handle = resume_handle_from state
          err = RequestFailedError.from event, resume_handle: handle
          next_state = state.with(
            status:           :error,
            in_flight_length: 0,
            last_error:       err
          )
          [next_state, [Instruction::TerminateFailure.new(error: err)]]
        end

        ##
        # @private
        # Raises InvalidTransitionError for unmatched state and event pair.
        #
        # @param state [State] Current state
        # @param event [Object] Dispatched event
        # @param _config [CompleteUploadConfig] Session configuration
        # @raise [InvalidTransitionError]
        def self.fail_with_unmatched_transition state, event, _config
          shape = shape_of event
          action = STATE_DESCRIPTIONS[state.status] || "processing #{state.status}"
          happened = describe_event event, shape
          message = "Resumable upload failed while #{action}: #{happened}."
          response = event.is_a?(Event::HttpResponse) ? event : nil
          handle = resume_handle_from state
          raise InvalidTransitionError.new(
            message,
            state:         state.status,
            event:         event,
            response:      response,
            resume_handle: handle
          )
        end

        ##
        # @private
        # Formats human-readable summary of an event.
        #
        # @param event [Object] Event instance
        # @param shape [Symbol] Event shape symbol
        # @return [String] Formatted description
        def self.describe_event event, shape
          case event
          when Event::HttpResponse
            upload_status = event.headers["x-goog-upload-status"] || event.headers["X-Goog-Upload-Status"]
            status_desc = upload_status ? "'#{upload_status}'" : "missing"
            "received an unexpected HTTP #{event.status} response (X-Goog-Upload-Status: #{status_desc})"
          when Event::ChunkRead
            "received unexpected stream chunk read (#{event.bytes_buffered} bytes, eof: #{event.eof})"
          when Event::RequestFailed
            "encountered unexpected request failure (#{event.kind}: #{event.message})"
          else
            "received unexpected event #{shape} (#{event.class.name})"
          end
        end

        ##
        # @private
        # Resolves effective chunk size given user specification and backend granularity.
        #
        # @param user_chunk_size [Integer, nil] Configured chunk size
        # @param chunk_granularity [Integer, nil] Backend alignment granularity
        # @return [Integer] Effective chunk size in bytes
        def self.resolve_chunk_size user_chunk_size, chunk_granularity
          base_size = user_chunk_size || DEFAULT_CHUNK_SIZE
          return base_size if chunk_granularity.nil? || chunk_granularity <= 0
          return chunk_granularity if base_size <= chunk_granularity

          base_size - (base_size % chunk_granularity)
        end

        ##
        # @private
        # Classifies an HTTP response into a canonical response shape.
        #
        # @param response [Event::HttpResponse] Response event
        # @return [Symbol] Canonical response shape
        def self.classify_http_response response
          status_header = header_value(response.headers, "x-goog-upload-status")&.downcase

          case status_header
          when "active"
            response.status == 200 ? :response_active : :response_cat2
          when "final"
            response.status == 200 ? :response_final : :response_rejected
          when "cancelled"
            response.status == 200 ? :response_cancelled : :response_fatal_bad_response
          when nil, ""
            if FATAL_STATUS_CODES.include? response.status
              :response_fatal_bad_response
            else
              :response_cat2
            end
          else
            :response_fatal_bad_response
          end
        end

        ##
        # @private
        # Case-insensitive header lookup helper.
        #
        # @param headers [Hash, Object] Headers collection
        # @param key [String] Target header key
        # @return [String, nil] Header value
        def self.header_value headers, key
          return nil unless headers.is_a? Hash
          return headers[key] if headers.key? key

          target = key.downcase
          _, val = headers.find { |k, _| k.to_s.downcase == target }
          val
        end

        ##
        # @private
        # Classifies chunk read event by buffer size and EOF flag.
        #
        # @param event [Event::ChunkRead] Chunk read event
        # @return [Symbol] Canonical chunk shape
        def self.classify_chunk_read event
          if !event.eof
            :chunk_read_full
          elsif event.bytes_buffered.positive?
            :chunk_read_eof_with_data
          else
            :chunk_read_eof_empty
          end
        end

        ##
        # @private
        # Classifies request failure event by failure kind.
        #
        # @param event [Event::RequestFailed] Request failed event
        # @return [Symbol] Canonical failure shape
        def self.classify_request_failed event
          case event.kind
          when :timeout then :request_timeout
          when :retries_exhausted then :request_retries_exhausted
          when :connection_failed then :request_connection_failed
          else :request_failed_unknown
          end
        end

        ##
        # @private
        # Classifies raw event class objects.
        #
        # @param event_class [Class] Event class
        # @return [Symbol] Canonical shape
        def self.classify_event_class event_class
          if event_class == Event::StartUpload
            :start_upload
          elsif event_class == Event::ResumeUpload
            :resume_upload
          elsif event_class == Event::Cancel
            :user_cancel
          elsif event_class == Event::GlobalDeadlineExceeded
            :global_deadline_exceeded
          else
            :unknown
          end
        end
      end
      # rubocop:enable Metrics/ModuleLength
    end
  end
end
