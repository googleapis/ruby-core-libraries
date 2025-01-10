# Copyright 2024 Google LLC
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
  module Common
    ##
    # Provides a generic mechanism for periodic polling an operation.
    #
    # Polling intervals are calculated from the provided retry policy.
    #
    # Supports exponential backoff via `multiplier`, and automatically
    # retries gRPC errors listed in `retry_codes`.
    #
    class PollingHarness
      # @return [Gapic::Common::RetryPolicy] The retry policy associated with this instance.
      attr_reader :retry_policy

      ##
      # Create new Gapic::Common::PollingHarness instance.
      #
      # @param retry_policy [Gapic::Common::RetryPolicy] The retry policy to
      #     use. If not provided, a new retry policy is constructed from the
      #     given kwargs.
      # @param kwargs [keywords] Keyword arguments used to create a new retry
      #     policy. See {RetryPolicy#initialize}.
      #
      def initialize retry_policy: nil, **kwargs
        @retry_policy = retry_policy ? retry_policy.dup : RetryPolicy.new(**kwargs)
      end

      ##
      # Perform polling with exponential backoff. Repeatedly calls the given
      # block until it returns a result other than the given sentinel value
      # (normally `nil`), then returns that final result.
      #
      # Uses the retry policy regulate retries, including delays between tries,
      # retriable errors, and final timeout. If an error code other than those
      # listed in {RetryPolicy#retry_codes} is raised, it is propagated out. If
      # the timeout expires, the given timeout result (normally `nil`) is
      # returned.
      #
      # @param wait_sentinel [Object] The return value that should signal the
      #     polling harness to continue waiting. Any other value is treated as
      #     a real result and returned. Defaults to `nil`.
      # @param timeout_result [Object] The result to return if timeout occurs.
      #     Defaults to `nil`.
      #
      # @yieldreturn [Object] The result of the polling logic, either a result
      #     to return, or the `wait_sentinel` value.
      #
      def wait wait_sentinel: nil, timeout_result: nil, mock_delay: false
        unless block_given?
          raise ArgumentError, "No callback provided to wait method."
        end
        retry_policy.start! mock_delay: mock_delay
        loop do
          begin
            response = yield
            return response unless response == wait_sentinel
          rescue StandardError => e # Currently retry_error only accounts for ::GRPC::BadStatus.
            raise unless retry_policy.retry_error? e
          end
          retry_policy.perform_delay!
          return timeout_result unless retry_policy.retry_with_deadline?
        end
      end
    end
  end
end
