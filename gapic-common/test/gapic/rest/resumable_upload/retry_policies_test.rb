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

require "test_helper"
require "gapic/rest/resumable_upload"
require "faraday"

##
# Tests for ResumableUpload RetryPolicies defaults and start_retry_policy_for.
#
class RetryPoliciesTest < Minitest::Test
  include Gapic::Rest::ResumableUpload

  # ============================================================================
  # SUT: default policies
  # ============================================================================

  def test_start_and_control_plane_retry_codes_cover_the_retriable_4xx_and_5xx_statuses
    # 409, 429, 499, 500, 503, 504 in that order.
    assert_equal [6, 8, 1, 13, 14, 4], RetryPolicies::START_AND_CONTROL_PLANE_RETRY_CODES
  end

  def test_data_plane_retry_codes_cover_only_the_retriable_5xx_statuses
    # 500, 503, 504 in that order.
    assert_equal [13, 14, 4], RetryPolicies::DATA_PLANE_RETRY_CODES
  end

  def test_retry_codes_are_derived_from_the_rules_status_sets
    expected = (Rules::RETRIABLE_4XX_STATUS_CODES + Rules::RETRIABLE_5XX_STATUS_CODES).map do |status|
      Gapic::Common::ErrorCodes.grpc_error_for status
    end
    assert_equal expected, RetryPolicies::START_AND_CONTROL_PLANE_RETRY_CODES
  end

  def test_408_and_502_are_not_retried_by_default
    unknown = Gapic::Common::ErrorCodes.grpc_error_for 408
    assert_equal Gapic::Common::ErrorCodes.grpc_error_for(502), unknown
    refute_includes RetryPolicies::START_AND_CONTROL_PLANE_RETRY_CODES, unknown
    refute_includes RetryPolicies::DATA_PLANE_RETRY_CODES, unknown
  end

  def test_default_policies_carry_the_per_plane_codes_and_no_predicate
    {
      RetryPolicies.default_start         => RetryPolicies::START_AND_CONTROL_PLANE_RETRY_CODES,
      RetryPolicies.default_control_plane => RetryPolicies::START_AND_CONTROL_PLANE_RETRY_CODES,
      RetryPolicies.default_data_plane    => RetryPolicies::DATA_PLANE_RETRY_CODES
    }.each do |policy, codes|
      assert_equal codes, policy.retry_codes
      assert_nil policy.retry_predicate
      assert_in_delta 1.0, policy.initial_delay
      assert_in_delta 15.0, policy.max_delay
      assert_in_delta 1.3, policy.multiplier
    end
  end

  def test_default_start_retries_a_retriable_4xx_but_the_data_plane_does_not
    err429 = Faraday::ClientError.new "Too Many Requests", { status: 429, headers: {} }

    assert RetryPolicies.default_start.retry_error?(err429)
    assert RetryPolicies.default_control_plane.retry_error?(err429)
    refute RetryPolicies.default_data_plane.retry_error?(err429)
  end

  def test_default_policies_retry_a_retriable_5xx
    err503 = Faraday::ServerError.new "Service Unavailable", { status: 503, headers: {} }

    assert RetryPolicies.default_start.retry_error?(err503)
    assert RetryPolicies.default_control_plane.retry_error?(err503)
    assert RetryPolicies.default_data_plane.retry_error?(err503)
  end

  def test_default_policies_do_not_retry_an_error_without_a_status
    err = RuntimeError.new "generic error"

    refute RetryPolicies.default_start.retry_error?(err)
    refute RetryPolicies.default_control_plane.retry_error?(err)
    refute RetryPolicies.default_data_plane.retry_error?(err)
  end

  # ============================================================================
  # SUT: start_retry_policy_for
  # ============================================================================

  def test_start_retry_policy_for_always_carries_the_call_timeout
    options = Gapic::CallOptions.new timeout: 17

    assert_equal({ timeout: 17 }, Gapic::Rest::ResumableUpload.start_retry_policy_for(options))
  end

  def test_start_retry_policy_for_carries_a_nil_timeout
    assert_equal({ timeout: nil }, Gapic::Rest::ResumableUpload.start_retry_policy_for(Gapic::CallOptions.new))
  end

  def test_start_retry_policy_for_tolerates_nil_options
    assert_equal({ timeout: nil }, Gapic::Rest::ResumableUpload.start_retry_policy_for(nil))
  end

  def test_start_retry_policy_for_copies_only_customized_backoff_settings
    options = Gapic::CallOptions.new timeout: 5, retry_policy: { initial_delay: 0.5 }

    overrides = Gapic::Rest::ResumableUpload.start_retry_policy_for options

    assert_equal 0.5, overrides[:initial_delay]
    refute overrides.key?(:max_delay)
    refute overrides.key?(:multiplier)
  end

  def test_start_retry_policy_for_treats_empty_retry_codes_as_unset
    options = Gapic::CallOptions.new retry_policy: { initial_delay: 0.5 }

    refute Gapic::Rest::ResumableUpload.start_retry_policy_for(options).key?(:retry_codes)
  end

  def test_start_retry_policy_for_copies_retry_codes_when_given
    options = Gapic::CallOptions.new retry_policy: { retry_codes: ["UNAVAILABLE"] }

    overrides = Gapic::Rest::ResumableUpload.start_retry_policy_for options

    assert_equal [Gapic::Common::ErrorCodes::ERROR_STRING_MAPPING["UNAVAILABLE"]], overrides[:retry_codes]
  end

  def test_start_retry_policy_for_overrides_keep_the_initiation_retry_codes
    options = Gapic::CallOptions.new timeout: 5, retry_policy: { initial_delay: 0.5 }
    overrides = Gapic::Rest::ResumableUpload.start_retry_policy_for options

    policy = Gapic::Common::RetryPolicy.new(**overrides).apply_defaults RetryPolicies::START_DEFAULTS

    assert_equal 0.5, policy.initial_delay
    assert_equal 5, policy.timeout
    assert_equal RetryPolicies::START_AND_CONTROL_PLANE_RETRY_CODES, policy.retry_codes
    assert_nil policy.retry_predicate
  end

  def test_start_retry_policy_for_rejects_a_proc_retry_policy
    options = Gapic::CallOptions.new retry_policy: ->(_error) { true }

    error = assert_raises ArgumentError do
      Gapic::Rest::ResumableUpload.start_retry_policy_for options
    end
    assert_match(/cannot derive an initiation retry policy/, error.message)
  end

  # A setting the caller chose deliberately carries across even when it happens to equal the library
  # default. Asking the policy what it holds, rather than comparing its readers against a default
  # policy, is what makes that possible.
  def test_start_retry_policy_for_carries_settings_that_equal_the_library_defaults
    options = Gapic::CallOptions.new retry_policy: {
      initial_delay: Gapic::Common::RetryPolicy::DEFAULT_INITIAL_DELAY,
      max_delay:     Gapic::Common::RetryPolicy::DEFAULT_MAX_DELAY,
      multiplier:    Gapic::Common::RetryPolicy::DEFAULT_MULTIPLIER
    }

    overrides = Gapic::Rest::ResumableUpload.start_retry_policy_for options

    assert_equal Gapic::Common::RetryPolicy::DEFAULT_INITIAL_DELAY, overrides[:initial_delay]
    assert_equal Gapic::Common::RetryPolicy::DEFAULT_MAX_DELAY, overrides[:max_delay]
    assert_equal Gapic::Common::RetryPolicy::DEFAULT_MULTIPLIER, overrides[:multiplier]
  end

  # `retry_predicate` and `timeout` cannot be expressed through a Hash: Gapic::CallOptions converts one
  # into a Gapic::CallOptions::RetryPolicy, whose initializer takes neither. A policy object passed
  # straight in is left alone, and is the only route by which either setting arrives here.
  def test_start_retry_policy_for_carries_a_caller_retry_predicate
    predicate = ->(_error) { true }
    options = Gapic::CallOptions.new retry_policy: Gapic::Common::RetryPolicy.new(retry_predicate: predicate)

    overrides = Gapic::Rest::ResumableUpload.start_retry_policy_for options
    policy = Gapic::Common::RetryPolicy.new(**overrides).apply_defaults RetryPolicies::START_DEFAULTS

    # The initiation defaults carry no predicate, so the caller's is used as-is.
    assert_same predicate, policy.retry_predicate
  end

  def test_start_retry_policy_for_call_timeout_displaces_a_policy_timeout
    options = Gapic::CallOptions.new timeout: 5, retry_policy: Gapic::Common::RetryPolicy.new(timeout: 900)

    assert_equal 5, Gapic::Rest::ResumableUpload.start_retry_policy_for(options)[:timeout]
  end
end
