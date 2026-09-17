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

require "uri"
require "gapic/logging_concerns"
require "gapic/rest/error"
require "gapic/rest/resumable_upload/core"
require "gapic/rest/resumable_upload/data_types"
require "gapic/rest/resumable_upload/errors"
require "gapic/rest/resumable_upload/events"
require "gapic/rest/resumable_upload/instructions"
require "gapic/rest/resumable_upload/retry_policies"
require "gapic/rest/resumable_upload/driver/upload_log"

module Gapic
  module Rest
    module ResumableUpload
      ##
      # @private
      # Synchronous execution engine for the Resumable Upload Protocol.
      # Coordinates HTTP network operations, stream buffering, monotonic deadlines,
      # and delegates state transitions to Core.
      #
      # The outer tier of the three-tier design. All side effects live here; all protocol decisions live in
      # {Rules}, which carries the state graph and the error category taxonomy. Category 1 transient retries
      # are absorbed here by `Gapic::Common::RetryPolicy` and never reach {Core}. See
      # `design/resumable_upload/implementation-guide.md` section 2.5 for the buffer and stream position
      # invariants, and section 6.3 for the deadline model.
      #
      # rubocop:disable Metrics/ClassLength
      class Driver
        include Gapic::LoggingConcerns

        ##
        # @private
        # Minimum assumed upload throughput in bytes per second (1 MB/s).
        # @return [Integer]
        MIN_ASSUMED_THROUGHPUT = 1_048_576

        ##
        # @private
        # Default base timeout in seconds (1 hour).
        # @return [Integer]
        BASE_TIMEOUT = 3_600

        # @private
        # @return [Core]
        attr_reader :core

        ##
        # @private
        # Returns a {ResumeHandle} representing the current upload session parameters.
        # Reading this property mid-run provides a best-effort snapshot of the current session state.
        # Completed uploads (`:success`), rejected uploads (`:rejected`), and cancelled uploads
        # (`:cancelled`) are finalized and not resumable, returning `nil`.
        #
        # @return [ResumeHandle, nil] Resume handle if upload URL is established and resumable, or nil
        def resume_handle
          Rules.resume_handle_from @core.state
        end

        ##
        # @private
        # Returns the raw upload session URL from protocol state, regardless of lifecycle status.
        #
        # @return [String, nil] Session upload URL if established, or nil
        def upload_url
          @core.state.upload_url
        end

        ##
        # @private
        # Initializes a new Resumable Upload Driver.
        #
        # @param client_stub [Gapic::Rest::ClientStub] Underlying REST client stub
        # @param config [StartUploadConfig, ResumeUploadConfig] Configuration for this upload session
        # @param core [Core, nil] Optional Core state machine (defaults to new Core with config)
        # @param logger [Logger, nil] Optional logger override
        # @param method_name [String, nil] RPC name this upload was started from, prefixed onto the
        #   per-request logging names (`"create_media_upload.start"`, `"create_media_upload.upload"`, and
        #   so on). Defaults to `"ResumableUpload"`.
        def initialize client_stub:, config:, core: nil, logger: nil, method_name: nil
          @client_stub = client_stub
          @config = config
          @core = core || Core.new(config)
          @buffer = "".b
          @buffer_start_offset = 0
          @method_name_prefix = method_name || "ResumableUpload"

          endpoint = client_stub.respond_to?(:endpoint) ? client_stub.endpoint : nil
          setup_logging logger: logger || (client_stub.respond_to?(:logger) ? client_stub.logger : nil),
                        system_name: "gapic-common",
                        service: "ResumableUpload",
                        endpoint: endpoint,
                        client_id: client_stub.object_id
          @upload_log = UploadLog.new stub_logger, upload_id: "unstarted"

          # Only an initiating run carries a start policy; a resumed run issues no initiation request.
          configured_start_policy = config.is_a?(StartUploadConfig) ? config.start_retry_policy : nil
          @start_retry_policy = resolve_retry_policy configured_start_policy, RetryPolicies::START_DEFAULTS

          @control_plane_retry_policy = resolve_retry_policy config.control_plane_retry_policy,
                                                             RetryPolicies::CONTROL_PLANE_DEFAULTS
          @data_plane_retry_policy = resolve_retry_policy config.data_plane_retry_policy,
                                                          RetryPolicies::DATA_PLANE_DEFAULTS
        end

        ##
        # @private
        # Default retry policy for session initiation requests (start).
        #
        # @return [Gapic::Common::RetryPolicy]
        def self.default_start_retry_policy
          RetryPolicies.default_start
        end

        ##
        # @private
        # Default retry policy for control plane requests (query, cancel).
        #
        # @return [Gapic::Common::RetryPolicy]
        def self.default_control_plane_retry_policy
          RetryPolicies.default_control_plane
        end

        ##
        # @private
        # Default retry policy for data plane requests (upload, finalize).
        #
        # @return [Gapic::Common::RetryPolicy]
        def self.default_data_plane_retry_policy
          RetryPolicies.default_data_plane
        end

        ##
        # @private
        # Executes event loop until terminal state.
        # Establishes a guaranteed monotonic deadline at the start of execution
        # so the upload cannot stall indefinitely.
        #
        # Enforces the trampoline loop invariant: each dispatched instruction batch
        # is validated by {#validate_batch} before any instruction executes, ensuring it
        # produces either a single continuation event or terminates the session
        # (via {Instruction::TerminateSuccess} or {Instruction::TerminateFailure}).
        # Side-effect instructions ({Instruction::NotifyProgress},
        # {Instruction::RealignBuffer}) explicitly return `nil` by construction,
        # so only {Instruction::FillBuffer} and `Send*` instructions produce
        # continuation events.
        #
        # @return [String, nil] Final response body
        def run
          @upload_log = UploadLog.new stub_logger, upload_id: LoggingConcerns.random_uuid4
          @deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + resolve_timeout
          pending_event = initial_event

          loop do
            instructions = dispatch_event pending_event

            if deadline_exceeded? && !terminal_instructions?(instructions)
              instructions = dispatch_event Event::GlobalDeadlineExceeded.new
            end

            pending_event, terminal_result = execute_batch instructions
            return terminal_result if pending_event.nil?
          end
        end

        private

        ##
        # @private
        # Executes an instruction batch and enforces the single-continuation-event invariant.
        #
        # @param instructions [Array<Object>] Emitted instructions
        # @return [Array<Object, nil>] Tuple of [pending_event, terminal_result]
        #
        def execute_batch instructions
          recipe = @core.last_decision&.recipe
          validate_batch instructions, recipe

          pending_event = nil
          instructions.each do |instruction|
            result = dispatch_instruction instruction
            return [nil, result] if instruction.is_a? Instruction::TerminateSuccess
            pending_event = result if Instruction::CONTINUATION.any? { |klass| instruction.is_a? klass }
          end

          unless pending_event_type? pending_event
            raise InternalError,
                  "Resumable upload internal error: recipe :#{recipe} continuation instruction " \
                  "returned #{pending_event.class} instead of an event"
          end
          [pending_event, nil]
        end

        ##
        # @private
        # Validates that an instruction batch satisfies the trampoline invariant before execution.
        #
        # @param instructions [Array<Object>] Emitted instructions
        # @param recipe [Symbol, nil] Recipe symbol from last decision
        # @return [void]
        # @raise [InternalError] If the batch is malformed or contains an unclassified instruction
        #
        def validate_batch instructions, recipe
          continuation = 0
          terminal = 0
          instructions.each do |instruction|
            case instruction
            when *Instruction::CONTINUATION then continuation += 1
            when *Instruction::TERMINAL     then terminal += 1
            when *Instruction::SIDE_EFFECT  then nil
            else
              raise InternalError,
                    "Resumable upload internal error: recipe :#{recipe} emitted " \
                    "unclassified instruction #{instruction.class}"
            end
          end
          return if continuation + terminal == 1

          raise InternalError, batch_shape_message(recipe, continuation, terminal)
        end

        ##
        # @private
        # Formats diagnostic error message for a malformed instruction batch.
        #
        # @param recipe [Symbol, nil] Recipe symbol from last decision
        # @param continuation [Integer] Number of continuation instructions
        # @param terminal [Integer] Number of terminal instructions
        # @return [String] Error message
        #
        def batch_shape_message recipe, continuation, terminal
          reason = if continuation.zero? && terminal.zero?
                     "produced no continuation event and did not terminate"
                   elsif continuation > 1 && terminal.zero?
                     "produced multiple continuation events"
                   elsif continuation.zero? && terminal > 1
                     "produced multiple terminal instructions"
                   else
                     "produced both a continuation event and a terminal instruction"
                   end
          "Resumable upload internal error: recipe :#{recipe} #{reason}"
        end

        ##
        # @private
        # Dispatches an event to Core, logging decisions and transitions.
        #
        # @param event [Object] Input event
        # @return [Array<Object>] Emitted instructions
        #
        def dispatch_event event
          instructions = begin
            @core.dispatch event
          rescue InvalidTransitionError => e
            @upload_log.unmatched_transition @core.state, event, e
            raise
          end
          @upload_log.decision @core.last_decision
          @upload_log.lifecycle @core.last_decision, @config
          instructions
        end

        ##
        # @private
        # Checks whether an instruction execution result represents a pending event.
        #
        # @param obj [Object] Execution result
        # @return [Boolean]
        #
        def pending_event_type? obj
          obj.is_a?(Event::ChunkRead) || obj.is_a?(Event::HttpResponse) ||
            obj.is_a?(Event::RequestFailed) || obj.is_a?(Event::GlobalDeadlineExceeded)
        end

        ##
        # @private
        # Executes an instruction emitted by the state machine.
        #
        # @param instruction [Object] Instruction to execute
        # @return [Object, nil] Resulting event or terminal response
        #
        def dispatch_instruction instruction
          case instruction
          when Instruction::NotifyProgress then execute_notify_progress instruction
          when Instruction::RealignBuffer then execute_realign_buffer instruction
          when Instruction::FillBuffer then execute_fill_buffer instruction
          when Instruction::SendStart then execute_send_start instruction
          when Instruction::SendChunk then execute_send_chunk instruction
          when Instruction::SendFinalize then execute_send_finalize instruction
          when Instruction::SendQuery then execute_send_query instruction
          when Instruction::SendCancel then execute_send_cancel instruction
          when Instruction::TerminateSuccess
            instruction.response.body
          when Instruction::TerminateFailure then raise instruction.error
          end
        end

        ##
        # @private
        # Resolves a configured retry policy or applies defaults.
        #
        # @param value [Gapic::Common::RetryPolicy, Hash, nil] Configured policy or overrides
        # @param defaults [Hash] Default policy configuration
        # @return [Gapic::Common::RetryPolicy]
        #
        def resolve_retry_policy value, defaults
          case value
          when Gapic::Common::RetryPolicy
            value
          when Hash
            Gapic::Common::RetryPolicy.new(**value).apply_defaults(defaults)
          when nil
            Gapic::Common::RetryPolicy.new(**defaults)
          else
            raise ArgumentError, "Expected RetryPolicy, Hash, or nil, got #{value.class}"
          end
        end

        ##
        # @private
        # Determines the initial event to dispatch based on configuration class.
        #
        # @return [Event::StartUpload, Event::ResumeUpload]
        def initial_event
          if @config.is_a? ResumeUploadConfig
            Event::ResumeUpload.new
          else
            Event::StartUpload.new
          end
        end

        ##
        # @private
        # Resolves the total upload deadline timeout in seconds.
        #
        # @return [Numeric] Timeout in seconds
        #
        def resolve_timeout
          return @config.timeout if @config.timeout&.positive?

          # When timeout is unset, BASE_TIMEOUT (1 hour) acts as a floor so small uploads still get
          # a full hour while large uploads scale past it at MIN_ASSUMED_THROUGHPUT (1 MiB/s).
          if @config.upload_size
            [@config.upload_size.fdiv(MIN_ASSUMED_THROUGHPUT), BASE_TIMEOUT].max
          else
            BASE_TIMEOUT
          end
        end

        ##
        # @private
        # Computes the per-request timeout bounded by the global monotonic deadline.
        #
        # @param retry_policy [Gapic::Common::RetryPolicy, nil] Target command retry policy
        # @return [Numeric] Effective per-request timeout
        #
        def request_timeout retry_policy
          remaining = if @deadline
                        [@deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC), 0].max
                      else
                        resolve_timeout
                      end
          return [remaining, retry_policy.timeout].min if retry_policy&.timeout

          remaining
        end

        ##
        # @private
        # Checks whether the monotonic clock has exceeded the session deadline.
        #
        # @return [Boolean]
        #
        def deadline_exceeded?
          return false unless @deadline
          Process.clock_gettime(Process::CLOCK_MONOTONIC) > @deadline
        end

        ##
        # @private
        # Determines whether the instruction list contains a terminal instruction.
        #
        # @param instructions [Array<Object>] Instruction list
        # @return [Boolean]
        #
        def terminal_instructions? instructions
          instructions.any? do |i|
            i.is_a?(Instruction::TerminateSuccess) || i.is_a?(Instruction::TerminateFailure)
          end
        end

        ##
        # @private
        # Invokes caller progress callback with snapshot.
        #
        # @param instruction [Instruction::NotifyProgress] Progress instruction
        #
        def execute_notify_progress instruction
          @config.on_progress&.call instruction.progress
          nil
        end

        ##
        # @private
        # Realigns in-memory buffer and underlying stream to match server offset.
        #
        # @param instruction [Instruction::RealignBuffer] Realign instruction
        #
        def execute_realign_buffer instruction
          server_offset = instruction.server_offset
          if @config.upload_size && server_offset > @config.upload_size
            raise StreamMismatchError.new(
              "Server reported offset #{server_offset} exceeds total upload size #{@config.upload_size}",
              resume_handle: resume_handle
            )
          end

          buffer_start = @buffer_start_offset
          buffer_end = @buffer_start_offset + @buffer.bytesize

          realign_case = if server_offset >= buffer_start && server_offset <= buffer_end
                           "within_buffer"
                         elsif server_offset < buffer_start
                           "rewind"
                         else
                           "fast_forward"
                         end

          unseekable = realign_case == "rewind" && !@config.stream.respond_to?(:seek)
          @upload_log.buffer_realign realign_case, server_offset: server_offset,
                                                   current_offset: buffer_start,
                                                   unseekable: unseekable

          if server_offset >= buffer_start && server_offset <= buffer_end
            realign_within_buffer server_offset
          elsif server_offset < buffer_start
            realign_rewind_stream server_offset
          else
            realign_fast_forward_stream server_offset, buffer_end
          end

          nil
        end

        ##
        # @private
        # Slices the in-memory buffer when server offset falls within current buffer range.
        #
        # @param server_offset [Integer] Target server offset
        #
        def realign_within_buffer server_offset
          slice_index = server_offset - @buffer_start_offset
          @buffer = @buffer.byteslice(slice_index..-1) || "".b
          @buffer_start_offset = server_offset
        end

        ##
        # @private
        # Rewinds seekable stream when server offset is before current buffer window.
        #
        # @param server_offset [Integer] Target server offset
        # @raise [UnseekableStreamError] If stream does not respond to #seek
        #
        def realign_rewind_stream server_offset
          unless @config.stream.respond_to? :seek
            raise UnseekableStreamError.new(
              "Cannot rewind unseekable stream to offset #{server_offset} (buffered from #{@buffer_start_offset})",
              resume_handle: resume_handle
            )
          end

          if @config.upload_size.nil? && @config.stream.respond_to?(:size) && server_offset > @config.stream.size
            raise StreamMismatchError.new(
              "Server reported offset #{server_offset} exceeds stream size #{@config.stream.size}",
              resume_handle: resume_handle
            )
          end

          @config.stream.seek server_offset
          @buffer = "".b
          @buffer_start_offset = server_offset
        end

        ##
        # @private
        # Fast-forwards stream by seeking or discarding bytes.
        #
        # @param server_offset [Integer] Target server offset
        # @param buffer_end [Integer] Current end offset of buffered data
        #
        def realign_fast_forward_stream server_offset, buffer_end
          @buffer = "".b
          if @config.stream.respond_to? :seek
            if @config.upload_size.nil? && @config.stream.respond_to?(:size) && server_offset > @config.stream.size
              raise StreamMismatchError.new(
                "Server reported offset #{server_offset} exceeds stream size #{@config.stream.size}",
                resume_handle: resume_handle
              )
            end
            @config.stream.seek server_offset
          else
            needed_discard = server_offset - buffer_end
            while needed_discard.positive?
              chunk = @config.stream.read [needed_discard, 65_536].min
              if chunk.nil? || chunk.empty?
                raise StreamMismatchError.new(
                  "Stream encountered unexpected EOF during fast-forward to offset #{server_offset} " \
                  "(expected at least #{needed_discard} more bytes)",
                  resume_handle: resume_handle
                )
              end

              needed_discard -= chunk.bytesize
            end
          end
          @buffer_start_offset = server_offset
        end

        ##
        # @private
        # Fills internal buffer from stream up to target byte size or EOF.
        #
        # @param instruction [Instruction::FillBuffer] FillBuffer instruction
        # @return [Event::ChunkRead] Chunk read event
        #
        def execute_fill_buffer instruction
          target = instruction.target_bytesize
          eof = false

          while @buffer.bytesize < target
            bytes_needed = target - @buffer.bytesize
            chunk = @config.stream.read bytes_needed
            if chunk.nil? || chunk.empty?
              eof = true
              break
            end
            @buffer << chunk.b
          end

          Event::ChunkRead.new bytes_buffered: @buffer.bytesize, eof: eof
        end

        ##
        # @private
        # Executes session initiation HTTP request.
        #
        # @param instruction [Instruction::SendStart] SendStart instruction
        # @return [Event::HttpResponse, Event::RequestFailed, Event::GlobalDeadlineExceeded]
        #
        def execute_send_start instruction
          policy = @start_retry_policy.dup.start!
          headers = start_headers instruction
          attempt = 1

          loop do
            return Event::GlobalDeadlineExceeded.new if deadline_exceeded?

            event = make_post_request instruction.url, headers: headers, body: instruction.body,
                                      retry_policy: policy, method_name: "#{@method_name_prefix}.start",
                                      start_attempt: attempt
            return event unless event.is_a? Event::HttpResponse

            status_hdr = Rules.header_value event.headers, "x-goog-upload-status"
            return event unless status_hdr.nil? || status_hdr.empty?
            return event if Rules::FATAL_STATUS_CODES.include? event.status

            err = BadResponseError.new "Missing X-Goog-Upload-Status header in start response",
                                       event.status,
                                       headers: event.headers
            # `retry_with_deadline?` is public; its `@private` tag hides it from docs, not from callers.
            can_retry = policy.retry_with_deadline? && policy.call(event)
            unless can_retry
              if event.status == 200
                failed_event = Event::RequestFailed.new(
                  kind: :retries_exhausted, message: err.message, source_error: err
                )
                @upload_log.wire_failure failed_event
                return failed_event
              end
              return event
            end
            attempt += 1
          end
        end

        ##
        # @private
        # Builds initiation HTTP headers from instruction and config.
        #
        # Every header derived here is listed in {RESERVED_INITIAL_HEADERS}, and caller headers in
        # that list are rejected when the config is built. The two sets are disjoint, so a plain merge
        # cannot drop a driver header or duplicate one under a different casing.
        #
        # @param instruction [Instruction::SendStart] Start instruction
        # @return [Hash<String, String>] HTTP request headers
        #
        def start_headers instruction
          headers = { "X-Goog-Upload-Protocol" => "resumable", "X-Goog-Upload-Command" => "start" }
          headers["X-Goog-Upload-Header-Content-Type"] = @config.content_type if @config.content_type
          headers["X-Goog-Upload-Header-Content-Length"] = @config.upload_size.to_s if @config.upload_size
          headers.merge instruction.headers || {}
        end

        ##
        # @private
        # Transmits a buffered chunk over HTTP.
        #
        # @param instruction [Instruction::SendChunk] SendChunk instruction
        # @return [Event::HttpResponse, Event::RequestFailed, Event::GlobalDeadlineExceeded]
        #
        def execute_send_chunk instruction
          headers = {
            "X-Goog-Upload-Command" => instruction.finalize ? "upload, finalize" : "upload",
            "X-Goog-Upload-Offset"  => instruction.offset.to_s,
            "Content-Type"          => @config.content_type || "application/octet-stream",
            "Content-Length"        => instruction.length.to_s
          }
          slice_index = instruction.offset - @buffer_start_offset
          body = @buffer.byteslice slice_index, instruction.length

          make_post_request instruction.url, headers: headers, body: body,
                            retry_policy: @data_plane_retry_policy.dup.start!,
                            method_name: "#{@method_name_prefix}.upload"
        end

        ##
        # @private
        # Sends a standalone finalize command over HTTP.
        #
        # @param instruction [Instruction::SendFinalize] SendFinalize instruction
        # @return [Event::HttpResponse, Event::RequestFailed, Event::GlobalDeadlineExceeded]
        #
        def execute_send_finalize instruction
          headers = {
            "X-Goog-Upload-Command" => "finalize",
            "X-Goog-Upload-Offset"  => @core.state.offset.to_s,
            "Content-Length"        => "0"
          }
          make_post_request instruction.url, headers: headers, body: "",
                            retry_policy: @data_plane_retry_policy.dup.start!,
                            method_name: "#{@method_name_prefix}.finalize"
        end

        ##
        # @private
        # Sends an offset query command over HTTP.
        #
        # @param instruction [Instruction::SendQuery] SendQuery instruction
        # @return [Event::HttpResponse, Event::RequestFailed, Event::GlobalDeadlineExceeded]
        #
        def execute_send_query instruction
          headers = { "X-Goog-Upload-Command" => "query", "Content-Length" => "0" }
          make_post_request instruction.url, headers: headers, body: "",
                            retry_policy: @control_plane_retry_policy.dup.start!,
                            method_name: "#{@method_name_prefix}.query"
        end

        ##
        # @private
        # Sends a cancellation command over HTTP.
        #
        # @param instruction [Instruction::SendCancel] SendCancel instruction
        # @return [Event::HttpResponse, Event::RequestFailed, Event::GlobalDeadlineExceeded]
        #
        def execute_send_cancel instruction
          headers = { "X-Goog-Upload-Command" => "cancel", "Content-Length" => "0" }
          make_post_request instruction.url, headers: headers, body: "",
                            retry_policy: @control_plane_retry_policy.dup.start!,
                            method_name: "#{@method_name_prefix}.cancel"
        end

        ##
        # @private
        # Dispatches an HTTP POST request through client stub.
        #
        # @param url [String] Target URL
        # @param headers [Hash] Request headers
        # @param body [String] Request body
        # @param retry_policy [Gapic::Common::RetryPolicy] Command retry policy
        # @param method_name [String, nil] RPC method name for logging
        # @param start_attempt [Integer] Attempt counter
        # @return [Event::HttpResponse, Event::RequestFailed, Event::GlobalDeadlineExceeded]
        #
        def make_post_request url, headers:, body:, retry_policy:, method_name: nil, start_attempt: 1
          return Event::GlobalDeadlineExceeded.new if deadline_exceeded?

          options = {
            metadata:     headers,
            retry_policy: retry_policy,
            timeout:      request_timeout(retry_policy)
          }
          @upload_log.wire_send method: "POST", url: url, headers: headers,
                                start_attempt: start_attempt, body_size: body.to_s.bytesize, body: body

          response = @client_stub.make_post_request uri: url, body: body, params: {},
                                                    options: options, method_name: method_name
          event = Event::HttpResponse.new status: response.status, headers: response.headers || {}, body: response.body
          @upload_log.wire_receive event
          event
        rescue StandardError => e
          # If the global deadline expired during the HTTP call (e.g. Net::HTTP connection or read timeout
          # triggered by request_timeout reaching 0 at @deadline), emit GlobalDeadlineExceeded rather than
          # Event::RequestFailed. Otherwise, in states like Recovery where Event::RequestFailed is immediately
          # terminal, the state machine would raise the underlying transport error instead of DeadlineExceededError.
          return Event::GlobalDeadlineExceeded.new if deadline_exceeded?

          event = rescue_request_error e
          if event.is_a? Event::HttpResponse
            @upload_log.wire_receive event
          else
            @upload_log.wire_failure event
          end
          event
        end

        ##
        # @private
        # Converts client stub transport exceptions into canonical events.
        #
        # @param err [StandardError] Rescued transport error
        # @return [Event::HttpResponse, Event::RequestFailed]
        #
        def rescue_request_error err
          case err
          when Gapic::Rest::DeadlineExceededError
            Event::RequestFailed.new kind: :timeout, message: err.message, source_error: err
          when Gapic::Rest::Error
            if err.status_code
              Event::HttpResponse.new status: err.status_code, headers: err.headers || {}, body: err.message,
                                      error: err
            else
              Event::RequestFailed.new kind: :connection_failed, message: err.message, source_error: err
            end
          when Faraday::Error
            rescue_faraday_error err
          else
            Event::RequestFailed.new kind: :connection_failed, message: err.message, source_error: err
          end
        end

        ##
        # @private
        # Converts Faraday client exceptions into canonical events.
        #
        # @param err [Faraday::Error] Rescued Faraday error
        # @return [Event::HttpResponse, Event::RequestFailed]
        #
        def rescue_faraday_error err
          if err.response && err.response[:status]
            rest_err = Gapic::Rest::Error.wrap_faraday_error err
            Event::HttpResponse.new(
              status:  err.response[:status],
              headers: err.response[:headers] || {},
              body:    err.response[:body],
              error:   rest_err
            )
          elsif err.is_a? Faraday::TimeoutError
            Event::RequestFailed.new kind: :timeout, message: err.message, source_error: err
          elsif err.is_a? Faraday::ConnectionFailed
            Event::RequestFailed.new kind: :connection_failed, message: err.message, source_error: err
          else
            Event::RequestFailed.new kind: :retries_exhausted, message: err.message, source_error: err
          end
        end
      end
      # rubocop:enable Metrics/ClassLength
    end
  end
end
