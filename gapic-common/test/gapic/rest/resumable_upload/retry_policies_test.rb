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
require "ostruct"
require "faraday"

##
# Tests for ResumableUpload RetryPolicies and header extraction.
#
class RetryPoliciesTest < Minitest::Test
  include Gapic::Rest::ResumableUpload

  # ============================================================================
  # SUT: extract_headers
  # ============================================================================

  def test_extract_headers_from_headers_method
    obj = OpenStruct.new headers: { "X-Test-Header" => "value1" }
    assert_equal({ "X-Test-Header" => "value1" }, RetryPolicies.extract_headers(obj))
  end

  def test_extract_headers_from_response_headers_method
    obj = OpenStruct.new response_headers: { "X-Test-Header" => "value2" }
    assert_equal({ "X-Test-Header" => "value2" }, RetryPolicies.extract_headers(obj))
  end

  def test_extract_headers_from_faraday_response_hash
    err = Faraday::ClientError.new "error message", { headers: { "X-Test-Header" => "value3" } }
    assert_equal({ "X-Test-Header" => "value3" }, RetryPolicies.extract_headers(err))
  end

  def test_extract_headers_returns_nil_when_no_headers_present
    assert_nil RetryPolicies.extract_headers(StandardError.new("error"))
    assert_nil RetryPolicies.extract_headers(nil)
    assert_nil RetryPolicies.extract_headers(Object.new)
    assert_nil RetryPolicies.extract_headers("string")
    assert_nil RetryPolicies.extract_headers({})
  end

  # ============================================================================
  # SUT: RetryPolicies.default_start
  # ============================================================================

  def test_default_start_missing_status_header_retries_unconditionally
    policy = RetryPolicies.default_start

    # Retriable code (503) without status header
    err_503 = OpenStruct.new response_status: 503, headers: { "Content-Type" => "text/plain" }
    assert policy.retry_error?(err_503)

    # Non-retriable code (400) without status header (still retries because missing status header is retriable)
    err_400 = OpenStruct.new response_status: 400, headers: { "Content-Type" => "text/plain" }
    assert policy.retry_error?(err_400)

    # Status 200 OK without status header
    resp_200 = OpenStruct.new response_status: 200, headers: { "Content-Type" => "text/plain" }
    assert policy.retry_error?(resp_200)

    # No status code without status header
    err_no_code = OpenStruct.new headers: { "Content-Type" => "text/plain" }
    assert policy.retry_error?(err_no_code)

    # Empty status header string
    err_empty_status = OpenStruct.new response_status: 400, headers: { "X-Goog-Upload-Status" => "" }
    assert policy.retry_error?(err_empty_status)
  end

  def test_default_start_with_status_header_falls_back_to_codes
    policy = RetryPolicies.default_start

    # Retriable code (503) with status header
    err_503 = OpenStruct.new response_status: 503, headers: { "X-Goog-Upload-Status" => "active" }
    assert policy.retry_error?(err_503)

    # Non-retriable code (400) with status header
    err_400 = OpenStruct.new response_status: 400, headers: { "X-Goog-Upload-Status" => "active" }
    refute policy.retry_error?(err_400)

    # Without status code with status header
    err_no_code = OpenStruct.new headers: { "X-Goog-Upload-Status" => "active" }
    refute policy.retry_error?(err_no_code)
  end

  def test_default_start_no_headers_falls_back_to_codes
    policy = RetryPolicies.default_start

    # Retriable code (503) without headers
    err_503 = OpenStruct.new response_status: 503
    assert policy.retry_error?(err_503)

    # Non-retriable code (400) without headers
    err_400 = OpenStruct.new response_status: 400
    refute policy.retry_error?(err_400)

    # Without status code and without headers
    err_no_code = RuntimeError.new "generic network error"
    refute policy.retry_error?(err_no_code)
  end

  # ============================================================================
  # SUT: RetryPolicies.default_control_plane
  # ============================================================================

  def test_default_control_plane_missing_status_header_falls_back_to_codes
    policy = RetryPolicies.default_control_plane

    # Retriable code (503) without status header
    err_503 = OpenStruct.new response_status: 503, headers: { "Content-Type" => "text/plain" }
    assert policy.retry_error?(err_503)

    # Non-retriable code (400) without status header
    err_400 = OpenStruct.new response_status: 400, headers: { "Content-Type" => "text/plain" }
    refute policy.retry_error?(err_400)

    # Without status code without status header
    err_no_code = OpenStruct.new headers: { "Content-Type" => "text/plain" }
    refute policy.retry_error?(err_no_code)
  end

  def test_default_control_plane_with_status_header_falls_back_to_codes
    policy = RetryPolicies.default_control_plane

    # Retriable code (503) with status header
    err_503 = OpenStruct.new response_status: 503, headers: { "X-Goog-Upload-Status" => "active" }
    assert policy.retry_error?(err_503)

    # Non-retriable code (400) with status header
    err_400 = OpenStruct.new response_status: 400, headers: { "X-Goog-Upload-Status" => "active" }
    refute policy.retry_error?(err_400)

    # Without status code with status header
    err_no_code = OpenStruct.new headers: { "X-Goog-Upload-Status" => "active" }
    refute policy.retry_error?(err_no_code)
  end

  def test_default_control_plane_no_headers_falls_back_to_codes
    policy = RetryPolicies.default_control_plane

    # Retriable code (503) without headers
    err_503 = OpenStruct.new response_status: 503
    assert policy.retry_error?(err_503)

    # Non-retriable code (400) without headers
    err_400 = OpenStruct.new response_status: 400
    refute policy.retry_error?(err_400)

    # Without status code and without headers
    err_no_code = RuntimeError.new "generic network error"
    refute policy.retry_error?(err_no_code)
  end

  # ============================================================================
  # SUT: RetryPolicies.default_data_plane
  # ============================================================================

  def test_default_data_plane_missing_status_header_unretriable
    policy = RetryPolicies.default_data_plane

    # Retriable code (503) without status header (predicate returns false -> unretriable)
    err_503 = OpenStruct.new response_status: 503, headers: { "Content-Type" => "text/plain" }
    refute policy.retry_error?(err_503)

    # Non-retriable code (400) without status header
    err_400 = OpenStruct.new response_status: 400, headers: { "Content-Type" => "text/plain" }
    refute policy.retry_error?(err_400)

    # Without status code without status header
    err_no_code = OpenStruct.new headers: { "Content-Type" => "text/plain" }
    refute policy.retry_error?(err_no_code)

    # Empty status header string
    err_empty_status = OpenStruct.new response_status: 503, headers: { "X-Goog-Upload-Status" => "" }
    refute policy.retry_error?(err_empty_status)
  end

  def test_default_data_plane_with_status_header_falls_back_to_codes
    policy = RetryPolicies.default_data_plane

    # Retriable code (503) with status header
    err_503 = OpenStruct.new response_status: 503, headers: { "X-Goog-Upload-Status" => "active" }
    assert policy.retry_error?(err_503)

    # Non-retriable code (400) with status header
    err_400 = OpenStruct.new response_status: 400, headers: { "X-Goog-Upload-Status" => "active" }
    refute policy.retry_error?(err_400)

    # Without status code with status header
    err_no_code = OpenStruct.new headers: { "X-Goog-Upload-Status" => "active" }
    refute policy.retry_error?(err_no_code)
  end

  def test_default_data_plane_no_headers_falls_back_to_codes
    policy = RetryPolicies.default_data_plane

    # Retriable code (503) without headers
    err_503 = OpenStruct.new response_status: 503
    assert policy.retry_error?(err_503)

    # Non-retriable code (400) without headers
    err_400 = OpenStruct.new response_status: 400
    refute policy.retry_error?(err_400)

    # Without status code and without headers
    err_no_code = RuntimeError.new "generic network error"
    refute policy.retry_error?(err_no_code)
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

  # Applying the overrides to the initiation defaults must leave the missing-status-header predicate in
  # place: that is the whole reason the conversion returns a Hash rather than a policy object.
  def test_start_retry_policy_for_overrides_leave_the_start_predicate_in_place
    options = Gapic::CallOptions.new timeout: 5, retry_policy: { initial_delay: 0.5 }
    overrides = Gapic::Rest::ResumableUpload.start_retry_policy_for options

    policy = Gapic::Common::RetryPolicy.new(**overrides).apply_defaults RetryPolicies::START_DEFAULTS

    assert_equal 0.5, policy.initial_delay
    assert_equal 5, policy.timeout
    assert_same RetryPolicies::START_PREDICATE, policy.retry_predicate
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

    # The caller's predicate replaces the initiation one wholesale; the two are not composed.
    assert_same predicate, policy.retry_predicate
  end

  def test_start_retry_policy_for_call_timeout_displaces_a_policy_timeout
    options = Gapic::CallOptions.new timeout: 5, retry_policy: Gapic::Common::RetryPolicy.new(timeout: 900)

    assert_equal 5, Gapic::Rest::ResumableUpload.start_retry_policy_for(options)[:timeout]
  end
end
