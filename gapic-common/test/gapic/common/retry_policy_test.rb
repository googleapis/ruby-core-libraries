# Copyright 2025 Google LLC
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

require "gapic/common/retry_policy"

# Test class for Gapic::Common::RetryPolicy
class RetryPolicyTest < Minitest::Test
  def test_init_with_values
    retry_policy = Gapic::Common::RetryPolicy.new(
      initial_delay: 2, max_delay: 20, multiplier: 1.7,
      retry_codes: [GRPC::Core::StatusCodes::UNAVAILABLE], timeout: 600, jitter: 0
    )
    assert_equal 2, retry_policy.initial_delay
    assert_equal 20, retry_policy.max_delay
    assert_equal 1.7, retry_policy.multiplier
    assert_equal [GRPC::Core::StatusCodes::UNAVAILABLE], retry_policy.retry_codes
    assert_equal 600, retry_policy.timeout
    assert_equal 0, retry_policy.jitter
  end

  def test_perform_delay_increment_delay
    retry_policy = Gapic::Common::RetryPolicy.new initial_delay: 1, max_delay: 5, multiplier: 1.3, jitter: 0
    retry_policy.start! mock_delay: true
    retry_policy.perform_delay!
    refute_equal retry_policy.initial_delay, retry_policy.delay
    assert_equal 1.3, retry_policy.delay
  end

  def test_perform_delay_retry_common_logic
    retry_policy = Gapic::Common::RetryPolicy.new initial_delay: 3, max_delay: 10, multiplier: 2, jitter: 0
    retry_policy.define_singleton_method :retry? do
      true
    end
    retry_policy.start! mock_delay: true
    retry_policy.perform_delay
    assert_equal 6, retry_policy.delay
  end

  def test_perform_delay_retry_error_logic
    retry_policy = Gapic::Common::RetryPolicy.new initial_delay: 5, max_delay: 30, multiplier: 3, jitter: 0
    retry_policy.define_singleton_method :retry_error? do |_error|
      true
    end
    retry_policy.start! mock_delay: true
    retry_policy.perform_delay
    assert_equal 15, retry_policy.delay
  end

  def test_max_delay_limit
    retry_policy = Gapic::Common::RetryPolicy.new initial_delay: 10, max_delay: 12, multiplier: 1.5, jitter: 0
    retry_policy.start! mock_delay: true
    retry_policy.perform_delay!
    assert_equal 12, retry_policy.delay
  end

  def test_retry_policy_deadline_init
    Process.stub :clock_gettime, 123_456_789.0 do
      retry_policy = Gapic::Common::RetryPolicy.new timeout: 10, jitter: 0
      assert_equal 123_456_799.0, retry_policy.send(:deadline)
    end
  end

  def test_negative_jitter_raises_error
    assert_raises ArgumentError do
      Gapic::Common::RetryPolicy.new jitter: -1.0
    end
  end

  def test_jitter_is_added
    retry_policy = Gapic::Common::RetryPolicy.new initial_delay: 5, max_delay: 10, multiplier: 2, jitter: 2.0

    delays_performed = []
    retry_policy.start! mock_delay: ->(d) { delays_performed << d }

    Kernel.stub :rand, 1.5 do
      retry_policy.perform_delay!
    end

    # base delay = 5, rand = 1.5, actual = 6.5
    assert_equal 6.5, delays_performed.first
    # internal state should remain deterministic
    assert_equal 10, retry_policy.delay
  end

  def test_jitter_bounds
    retry_policy = Gapic::Common::RetryPolicy.new initial_delay: 5, max_delay: 6, multiplier: 2, jitter: 2.0

    delays_performed = []
    retry_policy.start! mock_delay: ->(d) { delays_performed << d }

    Kernel.stub :rand, 2.0 do
      retry_policy.perform_delay!
    end

    # base delay is 5, rand is 2.0 = 7.0, capped at max_delay of 6
    assert_equal 6, delays_performed.first

    Kernel.stub :rand, 2.0 do
      retry_policy.perform_delay!
    end

    # internal state is now 10, rand is 2.0 = 12.0, capped at max_delay of 6
    assert_equal 6, delays_performed.last
  end
end
