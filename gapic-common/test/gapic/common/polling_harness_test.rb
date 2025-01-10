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

require "test_helper"

require "gapic/common/polling_harness"
require "gapic/common/retry_policy"

# Test class for Gapic::Common::PollingHarness
class PollingHarnessTest < Minitest::Test
  def test_init
    retry_policy = Gapic::Common::RetryPolicy.new initial_delay: 20
    polling_harness = Gapic::Common::PollingHarness.new initial_delay: 20
    assert_equal retry_policy, polling_harness.retry_policy
  end

  def test_wait_perform_delay_once
    wait_count = 0
    polling_harness = Gapic::Common::PollingHarness.new
    result = polling_harness.wait mock_delay: true do
      wait_count += 1
      wait_count <= 1 ? nil : :done
    end
    assert_equal 1, polling_harness.retry_policy.perform_delay_count
    assert_equal 2, wait_count
    assert_equal :done, result
  end

  def test_wait_perform_delay_many
    wait_count = 0
    polling_harness = Gapic::Common::PollingHarness.new
    result = polling_harness.wait mock_delay: true do
      wait_count += 1
      wait_count <= 4 ? nil : :done
    end
    assert_equal 4, polling_harness.retry_policy.perform_delay_count
    assert_equal 5, wait_count
    assert_equal :done, result
  end

  def test_wait_with_retriable_code
    wait_count = 0
    polling_harness = Gapic::Common::PollingHarness.new retry_codes: [GRPC::Core::StatusCodes::UNAVAILABLE]
    result = polling_harness.wait mock_delay: true do
      wait_count += 1
      raise ::GRPC::Unavailable if wait_count <= 1
      :done
    end
    assert_equal 1, polling_harness.retry_policy.perform_delay_count
    assert_equal 2, wait_count
    assert_equal :done, result
  end

  def test_wait_non_retriable_code
    wait_count = 0
    polling_harness = Gapic::Common::PollingHarness.new retry_codes: [GRPC::Core::StatusCodes::RESOURCE_EXHAUSTED]
    assert_raises ::GRPC::Aborted do
      polling_harness.wait mock_delay: true do
        wait_count += 1
        raise ::GRPC::Aborted if wait_count <= 1
        :done
      end
    end
    assert_equal 0, polling_harness.retry_policy.perform_delay_count
    assert_equal 1, wait_count
  end

  def test_wait_argument_error
    polling_harness = Gapic::Common::PollingHarness.new
    assert_raises ArgumentError do
      polling_harness.wait
    end
  end

  def test_wait_with_timeout
    wait_count = 0
    polling_harness = Gapic::Common::PollingHarness.new initial_delay: 2, multiplier: 1, timeout: 3
    polling_harness.wait mock_delay: true do
      wait_count += 1
      nil
    end
    assert_equal 2, wait_count
    assert_equal 2, polling_harness.retry_policy.perform_delay_count
  end
end
