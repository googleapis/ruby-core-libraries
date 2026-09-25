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

require "gapic/common/error_codes"
require "gapic/common/retry_policy"
require "gapic/rest/resumable_upload/rules"

module Gapic
  module Rest
    module ResumableUpload
      ##
      # @private
      # Default retry policy generators for control plane and data plane requests.
      #
      # The defaults carry no `retry_predicate`: every protocol-specific retry decision lives in
      # {Driver::RetryDecider}, which consults a policy only for its budget and backoff, and for the
      # caller-facing `retry_predicate` and `retry_codes`. The `retry_codes` below are derived from the HTTP
      # status sets on {Rules}, so HTTP status is the single source of truth.
      #
      # Keep in sync with the "Retry Policies" section of the {Gapic::ResumableUpload} class doc.
      #
      module RetryPolicies
        ##
        # @private
        # Default `retry_codes` for initiation, `query` and `cancel`: 409, 429, 499, 500, 503 and 504.
        # @return [Array<Integer>]
        START_AND_CONTROL_PLANE_RETRY_CODES =
          (Rules::RETRIABLE_4XX_STATUS_CODES + Rules::RETRIABLE_5XX_STATUS_CODES).map do |status|
            Gapic::Common::ErrorCodes.grpc_error_for status
          end.freeze

        ##
        # @private
        # Default `retry_codes` for `upload` and `finalize`: 500, 503 and 504. The data plane never
        # retries a 4xx, so none is listed.
        # @return [Array<Integer>]
        DATA_PLANE_RETRY_CODES = Rules::RETRIABLE_5XX_STATUS_CODES.map do |status|
          Gapic::Common::ErrorCodes.grpc_error_for status
        end.freeze

        ##
        # @private
        # Default options for start command retry policy.
        # @return [Hash]
        START_DEFAULTS = {
          retry_codes:   START_AND_CONTROL_PLANE_RETRY_CODES,
          initial_delay: 1.0,
          max_delay:     15.0,
          multiplier:    1.3
        }.freeze

        ##
        # @private
        # Default options for query and cancel commands retry policy.
        # @return [Hash]
        CONTROL_PLANE_DEFAULTS = {
          retry_codes:   START_AND_CONTROL_PLANE_RETRY_CODES,
          initial_delay: 1.0,
          max_delay:     15.0,
          multiplier:    1.3
        }.freeze

        ##
        # @private
        # Default options for upload and finalize commands retry policy.
        # @return [Hash]
        DATA_PLANE_DEFAULTS = {
          retry_codes:   DATA_PLANE_RETRY_CODES,
          initial_delay: 1.0,
          max_delay:     15.0,
          multiplier:    1.3
        }.freeze

        ##
        # @private
        # Default retry policy for session initiation requests (start).
        #
        # @return [Gapic::Common::RetryPolicy]
        def self.default_start
          Gapic::Common::RetryPolicy.new(**START_DEFAULTS)
        end

        ##
        # @private
        # Default retry policy for session control requests (query, cancel).
        #
        # @return [Gapic::Common::RetryPolicy]
        def self.default_control_plane
          Gapic::Common::RetryPolicy.new(**CONTROL_PLANE_DEFAULTS)
        end

        ##
        # @private
        # Default retry policy for data plane requests (upload, finalize).
        #
        # @return [Gapic::Common::RetryPolicy]
        def self.default_data_plane
          Gapic::Common::RetryPolicy.new(**DATA_PLANE_DEFAULTS)
        end
      end
    end
  end
end
