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

require "gapic/common/retry_policy"
require "gapic/rest/resumable_upload/rules"

module Gapic
  module Rest
    module ResumableUpload
      ##
      # @private
      # Default retry policy generators for control plane and data plane requests.
      #
      module RetryPolicies
        ##
        # @private
        # Retry predicate determining retriability for session initiation requests.
        # Retries missing status header on non-fatal codes.
        # @return [Proc]
        START_PREDICATE = lambda do |error_or_response|
          status = extract_status_code error_or_response
          return false if Rules::FATAL_STATUS_CODES.include? status

          headers = extract_headers error_or_response
          if headers
            status_hdr = headers["x-goog-upload-status"] || headers["X-Goog-Upload-Status"]
            return true if status_hdr.nil? || status_hdr.empty?
          end
          nil
        end

        ##
        # @private
        # Retry predicate determining retriability for data plane requests.
        # Disallows retry when upload status header is missing.
        # @return [Proc]
        DATA_PLANE_PREDICATE = lambda do |error_or_response|
          headers = extract_headers error_or_response
          if headers
            status_hdr = headers["x-goog-upload-status"] || headers["X-Goog-Upload-Status"]
            return false if status_hdr.nil? || status_hdr.empty?
          end
          nil
        end

        ##
        # @private
        # Default options for start command retry policy.
        # Keep in sync with the "Retry Policies" section of the Gapic::ResumableUpload class doc.
        # @return [Hash]
        START_DEFAULTS = {
          retry_codes:     ["UNAVAILABLE", "DEADLINE_EXCEEDED", "RESOURCE_EXHAUSTED", "INTERNAL"].freeze,
          initial_delay:   1.0,
          max_delay:       15.0,
          multiplier:      1.3,
          retry_predicate: START_PREDICATE
        }.freeze

        ##
        # @private
        # Default options for query and cancel commands retry policy.
        # Keep in sync with the "Retry Policies" section of the Gapic::ResumableUpload class doc.
        # @return [Hash]
        CONTROL_PLANE_DEFAULTS = {
          retry_codes:   ["UNAVAILABLE", "DEADLINE_EXCEEDED", "RESOURCE_EXHAUSTED", "INTERNAL"].freeze,
          initial_delay: 1.0,
          max_delay:     15.0,
          multiplier:    1.3
        }.freeze

        ##
        # @private
        # Default options for upload and finalize commands retry policy.
        # Keep in sync with the "Retry Policies" section of the Gapic::ResumableUpload class doc.
        # @return [Hash]
        DATA_PLANE_DEFAULTS = {
          retry_codes:     ["UNAVAILABLE", "DEADLINE_EXCEEDED", "RESOURCE_EXHAUSTED", "INTERNAL"].freeze,
          initial_delay:   1.0,
          max_delay:       15.0,
          multiplier:      1.3,
          retry_predicate: DATA_PLANE_PREDICATE
        }.freeze

        ##
        # @private
        # Default retry policy for session initiation requests (start).
        # Missing X-Goog-Upload-Status header is retriable across any response code,
        # including 200 (predicate returns true).
        #
        # @return [Gapic::Common::RetryPolicy]
        def self.default_start
          Gapic::Common::RetryPolicy.new(**START_DEFAULTS)
        end

        ##
        # @private
        # Default retry policy for session control requests (query, cancel).
        # Does not retry on missing X-Goog-Upload-Status header.
        #
        # @return [Gapic::Common::RetryPolicy]
        def self.default_control_plane
          Gapic::Common::RetryPolicy.new(**CONTROL_PLANE_DEFAULTS)
        end

        ##
        # @private
        # Default retry policy for data plane requests (upload, finalize).
        # Missing X-Goog-Upload-Status header is unretriable (predicate returns false).
        #
        # @return [Gapic::Common::RetryPolicy]
        def self.default_data_plane
          Gapic::Common::RetryPolicy.new(**DATA_PLANE_DEFAULTS)
        end

        ##
        # @private
        # Extracts headers hash from Faraday response or error object.
        #
        # @param error_or_response [Object] Response, error, or hash object
        # @return [Hash, nil]
        def self.extract_headers error_or_response
          if error_or_response.respond_to? :headers
            error_or_response.headers
          elsif error_or_response.respond_to? :response_headers
            error_or_response.response_headers
          elsif error_or_response.respond_to?(:response) && error_or_response.response.is_a?(Hash)
            error_or_response.response[:headers]
          end
        end

        ##
        # @private
        # Extracts HTTP status code from Faraday response, error, or event object.
        #
        # @param error_or_response [Object] Response, error, or event object
        # @return [Integer, nil]
        def self.extract_status_code error_or_response
          if error_or_response.respond_to?(:status_code) && error_or_response.status_code.is_a?(Integer)
            error_or_response.status_code
          elsif error_or_response.respond_to?(:response) && error_or_response.response.is_a?(Hash) &&
                error_or_response.response[:status].is_a?(Integer)
            error_or_response.response[:status]
          elsif error_or_response.respond_to?(:response_status) && error_or_response.response_status.is_a?(Integer)
            error_or_response.response_status
          elsif error_or_response.respond_to?(:status) && error_or_response.status.is_a?(Integer)
            error_or_response.status
          end
        end
      end
    end
  end
end
