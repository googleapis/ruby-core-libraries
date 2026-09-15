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
require "stringio"

##
# Tests for ResumableUpload Driver retry policy resolution and configuration overrides.
#
class DriverRetryPolicyTest < Minitest::Test
  include Gapic::Rest::ResumableUpload

  def setup
    @config = StartUploadConfig.new(
      initial_url: "https://example.com/upload",
      stream:      StringIO.new("0123")
    )
    @driver = Driver.new client_stub: Object.new, config: @config
  end

  def test_resolve_retry_policy_with_nil_returns_default_policy
    policy = @driver.send :resolve_retry_policy, nil, RetryPolicies::START_DEFAULTS

    assert_kind_of Gapic::Common::RetryPolicy, policy
    assert_equal RetryPolicies.default_start.retry_codes, policy.retry_codes
    assert_in_delta 1.0, policy.initial_delay
    assert_in_delta 15.0, policy.max_delay
    assert_in_delta 1.3, policy.multiplier
    assert_same RetryPolicies::START_PREDICATE, policy.retry_predicate
  end

  def test_resolve_retry_policy_with_policy_instance_returns_as_is
    custom_policy = Gapic::Common::RetryPolicy.new initial_delay: 5.0
    resolved = @driver.send :resolve_retry_policy, custom_policy, RetryPolicies::START_DEFAULTS

    assert_same custom_policy, resolved
    assert_nil resolved.retry_predicate
    assert_empty resolved.retry_codes
  end

  def test_resolve_retry_policy_with_hash_applies_defaults_and_preserves_codes_and_predicate
    hash_override = { initial_delay: 0.25, max_delay: 2.0 }
    resolved = @driver.send :resolve_retry_policy, hash_override, RetryPolicies::START_DEFAULTS

    assert_kind_of Gapic::Common::RetryPolicy, resolved
    assert_in_delta 0.25, resolved.initial_delay
    assert_in_delta 2.0, resolved.max_delay
    assert_in_delta 1.3, resolved.multiplier
    assert_equal RetryPolicies.default_start.retry_codes, resolved.retry_codes
    assert_same RetryPolicies::START_PREDICATE, resolved.retry_predicate
  end

  def test_resolve_retry_policy_with_data_plane_hash_preserves_data_plane_predicate
    hash_override = { timeout: 60.0 }
    resolved = @driver.send :resolve_retry_policy, hash_override, RetryPolicies::DATA_PLANE_DEFAULTS

    assert_kind_of Gapic::Common::RetryPolicy, resolved
    assert_in_delta 60.0, resolved.timeout
    assert_equal RetryPolicies.default_data_plane.retry_codes, resolved.retry_codes
    assert_same RetryPolicies::DATA_PLANE_PREDICATE, resolved.retry_predicate
  end

  def test_resolve_retry_policy_with_empty_retry_codes_array_honors_empty_array
    hash_override = { retry_codes: [] }
    resolved = @driver.send :resolve_retry_policy, hash_override, RetryPolicies::START_DEFAULTS

    assert_kind_of Gapic::Common::RetryPolicy, resolved
    assert_empty resolved.retry_codes
    assert_same RetryPolicies::START_PREDICATE, resolved.retry_predicate
  end

  def test_resolve_retry_policy_with_unknown_hash_key_raises_argument_error
    err = assert_raises ArgumentError do
      @driver.send :resolve_retry_policy, { unknown_key: 123 }, RetryPolicies::START_DEFAULTS
    end
    assert_match(/unknown keyword: :unknown_key/, err.message)
  end

  def test_resolve_retry_policy_with_invalid_type_raises_argument_error
    err = assert_raises ArgumentError do
      @driver.send :resolve_retry_policy, "invalid", RetryPolicies::START_DEFAULTS
    end
    assert_match(/Expected RetryPolicy, Hash, or nil/, err.message)
  end

  def test_driver_initialize_resolves_hash_overrides_from_config
    config = StartUploadConfig.new(
      initial_url:                "https://example.com/upload",
      stream:                     StringIO.new("0123"),
      start_retry_policy:         { initial_delay: 0.1 },
      control_plane_retry_policy: { max_delay: 5.0 },
      data_plane_retry_policy:    { multiplier: 2.0 }
    )
    driver = Driver.new client_stub: Object.new, config: config

    start_policy = driver.instance_variable_get :@start_retry_policy
    control_policy = driver.instance_variable_get :@control_plane_retry_policy
    data_policy = driver.instance_variable_get :@data_plane_retry_policy

    assert_in_delta 0.1, start_policy.initial_delay
    assert_same RetryPolicies::START_PREDICATE, start_policy.retry_predicate

    assert_in_delta 5.0, control_policy.max_delay
    assert_nil control_policy.retry_predicate

    assert_in_delta 2.0, data_policy.multiplier
    assert_same RetryPolicies::DATA_PLANE_PREDICATE, data_policy.retry_predicate
  end

  def test_start_predicate_refutes_fatal_status_codes
    [401, 403, 404, 405, 410, 413, 415].each do |code|
      response_double = OpenStruct.new status: code, headers: {}
      refute RetryPolicies::START_PREDICATE.call(response_double),
             "Expected START_PREDICATE to return false for fatal status #{code}"

      gapic_err = Gapic::Rest::Error.new "Error", code, status: "FATAL_ERROR", headers: {}
      refute RetryPolicies::START_PREDICATE.call(gapic_err),
             "Expected START_PREDICATE to return false for Gapic::Rest::Error with fatal status #{code}"
    end
  end

  def test_start_predicate_retries_missing_header_for_non_fatal_codes
    [200, 400, 500, 503].each do |code|
      response_double = OpenStruct.new status: code, headers: {}
      assert RetryPolicies::START_PREDICATE.call(response_double),
             "Expected START_PREDICATE to return true for non-fatal status #{code} with missing status header"
    end
  end
end
