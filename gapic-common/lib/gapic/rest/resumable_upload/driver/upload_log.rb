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

require "google/logging/message"
require "gapic/rest/resumable_upload/driver/abridge"

module Gapic
  module Rest
    module ResumableUpload
      class Driver
        ##
        # @private
        # Structured logging helper for a single Resumable Upload run.
        #
        class UploadLog
          ##
          # @private
          # Recipes omitted from INFO lifecycle logging.
          # @return [Array<Symbol>]
          SILENT_RECIPES = [
            :ack_chunk,                     # per-chunk transition, doesn't belong at INFO
            :fail_with_unmatched_transition # raises before Decision exists, logged by #unmatched_transition
          ].freeze

          ##
          # @private
          # Severity and message mapping for lifecycle transitions.
          # @return [Hash<Symbol, Array>]
          LIFECYCLE = {
            start_session:               [:info, "Initiating resumable upload"],
            resume_session:              [:info, "Resuming upload session"],
            begin_transmission:          [:info, "Upload session established"],
            send_chunk:                  [:debug, "Sending upload chunk"],
            send_upload_finalize:        [:info, "Sending final upload chunk"],
            send_finalize:               [:info, "Sending finalize command"],
            enter_recovery:              [:info, "Entering upload recovery"],
            retry_recovery:              [:info, "Retrying upload recovery query"],
            realign_from_recovery:       [:info, "Resuming upload from server offset"],
            complete_upload_with_data:   [:info, "Resumable upload completed"],
            complete_upload_finalized:   [:info, "Resumable upload completed"],
            cancel_session:              [:info, "Canceling resumable upload"],
            complete_cancellation:       [:info, "Resumable upload canceled"],
            fail_with_cancelled:         [:warn, "Resumable upload canceled on the server"],
            fail_with_deadline_exceeded: [:warn, "Resumable upload failed"],
            fail_with_rejected:          [:warn, "Resumable upload failed"],
            fail_with_bad_response:      [:warn, "Resumable upload failed"],
            fail_with_request_error:     [:warn, "Resumable upload failed"]
          }.freeze

          # @private
          # @return [String]
          attr_reader :upload_id

          ##
          # @private
          # Initializes a new UploadLog logger wrapper.
          #
          # @param stub_logger [Logger, Object] Underlying structured logger
          # @param upload_id [String] Unique session identifier
          #
          def initialize stub_logger, upload_id:
            @stub_logger = stub_logger
            @upload_id = upload_id
          end

          ##
          # @private
          # Logs state machine transition decision at DEBUG level.
          #
          # @param decision [Decision] Decision snapshot
          #
          def decision decision
            msg = "Rules: #{decision.from_status} + #{decision.shape} -> " \
                  "#{decision.recipe} -> #{decision.next_state.status}"
            entry(
              :debug,
              msg,
              fromStatus:     decision.from_status,
              shape:          decision.shape,
              recipe:         decision.recipe,
              toStatus:       decision.next_state.status,
              offset:         decision.next_state.offset,
              inFlightLength: decision.next_state.in_flight_length,
              instructions:   Abridge.instructions(decision.instructions)
            )
          end

          ##
          # @private
          # Logs high-level protocol lifecycle milestone if configured.
          #
          # @param decision [Decision] Decision snapshot
          # @param config [StartUploadConfig, ResumeUploadConfig] Upload configuration
          #
          def lifecycle decision, config
            return if SILENT_RECIPES.include? decision.recipe

            severity, message = LIFECYCLE[decision.recipe]
            return unless severity

            extra_fields = lifecycle_fields decision, config
            entry severity, message, recipe: decision.recipe, **extra_fields
          end

          ##
          # @private
          # Logs an outgoing HTTP request at DEBUG level.
          #
          # @param method [String] HTTP method
          # @param url [String] Request URL
          # @param headers [Hash] Request headers
          # @param start_attempt [Integer] Attempt index for start command
          # @param body_size [Integer, nil] Byte size of request payload
          # @param body [Object, nil] Request payload
          # @param body_is_error [Boolean] Whether body contains an error payload
          #
          def wire_send method:, url:, headers:, start_attempt:, body_size: nil, body: nil, body_is_error: false
            command = Rules.header_value headers, "x-goog-upload-command"
            offset = Rules.header_value headers, "x-goog-upload-offset"
            fields = {
              method:       method,
              url:          Abridge.url(url),
              headers:      Abridge.headers(headers),
              startAttempt: start_attempt
            }
            fields[:command] = command if command
            fields[:offset] = offset.to_i if offset
            fields[:bodySize] = body_size if body_size
            fields[:body] = body_is_error ? Abridge.error_body(body) : Abridge.bytes(body) if body

            entry :debug, "Sending #{method} request", **fields
          end

          ##
          # @private
          # Logs a received HTTP response at DEBUG level.
          #
          # @param event [Event::HttpResponse] Received HTTP event
          #
          def wire_receive event
            upload_status = Rules.header_value event.headers, "x-goog-upload-status"
            size_recv = Rules.header_value event.headers, "x-goog-upload-size-received"
            gran = Rules.header_value event.headers, "x-goog-upload-chunk-granularity"
            err = event.error if event.respond_to? :error
            fields = {
              status:  event.status,
              headers: Abridge.headers(event.headers),
              body:    wire_receive_body(event, err)
            }
            fields[:uploadStatus] = upload_status if upload_status
            fields[:errorStatus] = err.status if err&.status
            fields[:sizeReceived] = size_recv.to_i if size_recv
            fields[:granularity] = gran.to_i if gran

            entry :debug, "Received HTTP #{event.status}", **fields
          end

          ##
          # @private
          # Logs a network or transport failure at DEBUG level.
          #
          # @param event [Event::RequestFailed] Failure event
          #
          def wire_failure event
            entry(
              :debug,
              "Request failed: #{event.kind}",
              kind:  event.kind,
              error: event.message
            )
          end

          ##
          # @private
          # Logs buffer realignment action.
          #
          # @param action [String] Realignment action description
          # @param server_offset [Integer] Target server offset
          # @param current_offset [Integer] Current buffer start offset
          # @param unseekable [Boolean] Whether rewind was attempted on an unseekable stream
          #
          def buffer_realign action, server_offset:, current_offset:, unseekable: false
            if unseekable
              entry(
                :warn,
                "Server offset rewind on unseekable stream",
                action:        action,
                serverOffset:  server_offset,
                currentOffset: current_offset
              )
            end

            entry(
              :debug,
              "Buffer realignment: #{action}",
              action:        action,
              serverOffset:  server_offset,
              currentOffset: current_offset
            )
          end

          ##
          # @private
          # Logs an invalid or unmatched state machine transition at WARN level.
          #
          # @param state [State] Current state
          # @param event [Object] Triggering event
          # @param error [StandardError] Resulting error
          #
          def unmatched_transition state, event, error
            entry(
              :warn,
              "Unmatched transition",
              status: state.status,
              shape:  Rules.shape_of(event),
              error:  error.message
            )
          end

          private

          ##
          # @private
          # Formats response body for wire log entry.
          #
          # @param event [Event::HttpResponse] Response event
          # @param err [Gapic::Rest::Error, nil] Error instance
          # @return [String, nil] Formatted body
          #
          def wire_receive_body event, err
            return Abridge.bytes event.body if event.status < 400

            err&.message ? Abridge.error_body(err.message) : Abridge.error_body(event.body)
          end

          ##
          # @private
          # Extracts relevant state fields for lifecycle logging.
          #
          # @param decision [Decision] Decision snapshot
          # @param config [StartUploadConfig, ResumeUploadConfig] Upload configuration
          # @return [Hash] Metadata fields for log entry
          #
          def lifecycle_fields decision, config
            state = decision.next_state
            case decision.recipe
            when :start_session
              { uploadSize: config.upload_size, requestedChunkSize: config.chunk_size }
            when :resume_session
              {
                uploadUrl: Abridge.url(state.upload_url),
                chunkSize: state.chunk_size
              }
            when :begin_transmission
              {
                effectiveChunkSize: state.chunk_size,
                granularity:        state.chunk_granularity,
                uploadUrl:          Abridge.url(state.upload_url)
              }
            when :send_chunk, :send_upload_finalize
              { offset: state.offset, inFlightLength: state.in_flight_length }
            when :send_finalize, :enter_recovery, :retry_recovery,
                 :realign_from_recovery, :complete_upload_with_data, :complete_upload_finalized
              { offset: state.offset }
            when :cancel_session
              { uploadUrl: Abridge.url(state.upload_url) }
            when :fail_with_deadline_exceeded, :fail_with_rejected, :fail_with_bad_response,
                 :fail_with_request_error
              failure_fields state
            else
              {}
            end
          end

          ##
          # @private
          # Extracts error and response details for failure lifecycle logs.
          #
          # @param state [State] Current protocol state
          # @return [Hash] Failure metadata fields
          #
          def failure_fields state
            err = state.last_error
            fields = { error: err&.message || err.to_s }
            if err.respond_to?(:response_body) && err.response_body
              fields[:responseBody] = Abridge.error_body err.response_body
            end
            fields
          end

          ##
          # @private
          # Dispatches structured log entry to stub logger.
          #
          # @param severity [Symbol] Log severity level
          # @param log_msg [String] Primary log message
          # @param fields [Hash] Structured key-value fields
          #
          def entry severity, log_msg, **fields
            @stub_logger.public_send severity do |builder|
              builder.set_system_name
              builder.set_service
              builder.set "uploadId", @upload_id
              fields.each do |k, v|
                builder.set k.to_s, v
              end
              builder.message = log_msg
            end
          end
        end
      end
    end
  end
end
