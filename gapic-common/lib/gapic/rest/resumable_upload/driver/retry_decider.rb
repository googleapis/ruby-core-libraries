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

require "faraday"
require "gapic/rest/error"
require "gapic/rest/resumable_upload/rules"

module Gapic
  module Rest
    module ResumableUpload
      class Driver
        ##
        # @private
        # Single owner of every retry decision for one resumable upload command.
        #
        # `ClientStub` is handed a never-retry policy, so each `ClientStub` call is exactly one attempt and
        # every outcome comes back to the Driver. The Driver asks this object whether to send the same request
        # again. It only ever chooses between re-sending and surfacing: an outcome it declines, and whatever
        # is left when the budget runs out, is converted to an event unchanged and handed to {Rules}, which
        # alone decides between recovery and a terminal outcome.
        #
        # The decision table (first match wins):
        #
        # | # | Outcome                                             | start / control        | data                   |
        # |---|-----------------------------------------------------|------------------------|------------------------|
        # | 1 | non-transport error (e.g. auth refresh)             | ask policy             | ask policy             |
        # | 2 | `Faraday::TimeoutError`, or no response and no kind | ask policy             | surface                |
        # | 3 | `Faraday::ConnectionFailed`, `Faraday::SSLError`    | retry within budget    | surface                |
        # | 4 | `200` without `X-Goog-Upload-Status`                | retry within budget    | surface                |
        # | 5 | non-200 with `X-Goog-Upload-Status: final`          | surface                | surface                |
        # | 6 | any 4xx                                             | (falls through)        | surface                |
        # | 7 | any other non-200                                   | ask policy             | ask policy             |
        # | - | any other `2xx`, or `200` with the header           | surface                | surface                |
        #
        # * **Retry within budget** is the no-argument `RetryPolicy#call`: it checks the policy deadline and
        #   applies backoff, and hands nothing to a caller predicate.
        # * **Ask policy** is `retry_with_deadline? && call(error)`: the caller's `retry_predicate`, then its
        #   `retry_codes`. `RetryPolicy#call(error)` does not check the deadline itself, hence the guard.
        # * The data plane never re-sends after an outcome that leaves the server offset unknown (rows 2, 3, 4,
        #   6); recovery owns those. A non-transport error (row 1) fails before anything reaches the wire, so
        #   re-sending cannot duplicate bytes.
        # * Rows 5 and 6 are fixed ahead of the policy, so no caller setting can retry a rejection or make the
        #   data plane re-send on a 4xx.
        #
        # Row 2 is inert for timeouts until attempts get their own timeouts: each attempt currently receives the
        # whole remaining command budget, so a timed-out attempt leaves none to retry with.
        #
        # See `design/resumable_upload/transport-error-retry.md`.
        #
        class RetryDecider
          ##
          # @private
          # Classifies a raised request error by what reached the wire.
          #
          # Shared with {Driver#rescue_request_error}, so the kind an error is retried as and the kind it is
          # surfaced as cannot drift apart.
          #
          # @param error [StandardError] Error raised by, or through, `ClientStub#make_post_request`
          # @return [Symbol] `:status` (an HTTP response arrived), `:timeout`, `:connection_failed`,
          #   `:no_response` (a transport error of no more specific kind), or `:non_transport`
          def self.failure_kind error
            case error
            when Gapic::Rest::DeadlineExceededError then :timeout
            when Gapic::Rest::Error then error.status_code ? :status : :connection_failed
            when Faraday::Error then faraday_failure_kind error
            else :non_transport
            end
          end

          ##
          # @private
          # @param error [Faraday::Error]
          # @return [Symbol] See {.failure_kind}
          def self.faraday_failure_kind error
            if error.response.is_a?(Hash) && error.response[:status]
              :status
            elsif error.is_a? Faraday::TimeoutError
              :timeout
            elsif error.is_a?(Faraday::ConnectionFailed) || error.is_a?(Faraday::SSLError)
              :connection_failed
            else
              :no_response
            end
          end

          ##
          # @private
          # @param policy [Gapic::Common::RetryPolicy] Started policy for this command
          # @param data_plane [Boolean] Whether the command transmits upload bytes (`upload`, `finalize`)
          def initialize policy, data_plane:
            @policy = policy
            @data_plane = data_plane
          end

          ##
          # @private
          # Decides whether to send the same request again, performing the backoff delay if so.
          #
          # @param outcome [Object, StandardError] The response returned by `ClientStub#make_post_request`, or
          #   the error it raised
          # @return [Boolean] `true` if the request should be sent again (the delay has been performed)
          def retry? outcome
            return retry_response? outcome unless outcome.is_a? Exception

            error = unwrap outcome
            case self.class.failure_kind error
            when :status then retry_status? error
            when :connection_failed then !@data_plane && @policy.call
            when :timeout, :no_response then !@data_plane && ask_policy(error)
            else ask_policy error
            end
          end

          private

          ##
          # @private
          # Under `raise_faraday_errors: false`, `ClientStub` raises a {Gapic::Rest::Error} from inside its own
          # `rescue`, so `cause` is the original Faraday error. `retry_codes` can read a status only from the
          # latter.
          #
          # @param error [StandardError]
          # @return [StandardError]
          def unwrap error
            return error.cause if error.is_a?(Gapic::Rest::Error) && error.cause.is_a?(Faraday::Error)
            error
          end

          ##
          # @private
          # Faraday raises on every `4xx`/`5xx`, so a returned response is a `1xx`-`3xx`. Only a headerless
          # `200` is worth re-sending.
          #
          # @param response [Object] Response exposing `status` and `headers`
          # @return [Boolean]
          def retry_response? response
            return false unless response.status == 200
            return false unless upload_status(response.headers).nil?
            !@data_plane && @policy.call
          end

          ##
          # @private
          # @param error [Faraday::Error, Gapic::Rest::Error] Error carrying an HTTP status
          # @return [Boolean]
          def retry_status? error
            status, headers = if error.is_a? Gapic::Rest::Error
                                [error.status_code, error.headers]
                              else
                                [error.response[:status], error.response[:headers]]
                              end
            return false if upload_status(headers) == "final"
            return false if @data_plane && (400..499).cover?(status)
            ask_policy error
          end

          ##
          # @private
          # @param error [StandardError]
          # @return [Boolean]
          def ask_policy error
            @policy.retry_with_deadline? && @policy.call(error)
          end

          ##
          # @private
          # @param headers [Hash, nil]
          # @return [String, nil] Downcased `X-Goog-Upload-Status`, or `nil` when missing or empty
          def upload_status headers
            value = Rules.header_value headers, "x-goog-upload-status"
            value.nil? || value.empty? ? nil : value.downcase
          end
        end
      end
    end
  end
end
