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

require "integration_helper"
require "json"
require "securerandom"
require "stringio"

##
# Suite A: Integration tests for non-fatal and fatal errors on session initiation (`start`).
#
class ErrorOnStartTest < ShowcaseIntegrationTest
  PAYLOAD_SIZE = 100

  def build_start_error_config scenario:, scenario_config: {}, start_retry_policy: nil, **overrides
    build_config(
      scenario:                   scenario,
      scenario_config:            scenario_config,
      start_retry_policy:         start_retry_policy,
      control_plane_retry_policy: nil,
      data_plane_retry_policy:    nil,
      stream:                     StringIO.new(payload(PAYLOAD_SIZE)),
      upload_size:                PAYLOAD_SIZE,
      **overrides
    )
  end

  # A1. Verifies non-fatal transient error (503) on start is retried and upload completes.
  def test_non_fatal_error_on_start_503
    config = build_start_error_config(
      scenario:           "non_fatal_error_on_start",
      scenario_config:    { error_code: 503, failure_count: 1 },
      start_retry_policy: FAST_RETRY
    )

    driver = Gapic::Rest::ResumableUpload::Driver.new(
      client_stub: showcase_client_stub,
      config:      config
    )

    result = driver.run
    parsed = JSON.parse result

    assert_equal PAYLOAD_SIZE, parsed["size"]
    assert_equal 1, phases.count(:initiating)
    assert_equal :completed, phases.last
  end

  # A2. Verifies missing status header / 400 on start is retried and upload completes.
  def test_missing_header_retriable_on_start_400
    config = build_start_error_config(
      scenario:           "non_fatal_error_on_start",
      scenario_config:    { error_code: 400, failure_count: 1 },
      start_retry_policy: FAST_RETRY
    )

    driver = Gapic::Rest::ResumableUpload::Driver.new(
      client_stub: showcase_client_stub,
      config:      config
    )

    result = driver.run
    parsed = JSON.parse result

    assert_equal PAYLOAD_SIZE, parsed["size"]
    assert_equal 1, phases.count(:initiating)
    assert_equal :completed, phases.last
  end

  # A3. Verifies retry exhaustion on start with high failure count times out within ~3s without uploading.
  def test_retry_exhaustion_on_start_times_out
    config = build_start_error_config(
      scenario:        "non_fatal_error_on_start",
      scenario_config: { error_code: 503, failure_count: 10_000 },
      timeout:         3
    )

    driver = Gapic::Rest::ResumableUpload::Driver.new(
      client_stub: showcase_client_stub,
      config:      config
    )

    t0 = Process.clock_gettime Process::CLOCK_MONOTONIC
    err = assert_raises Gapic::Common::Error do
      driver.run
    end
    t1 = Process.clock_gettime Process::CLOCK_MONOTONIC

    elapsed = t1 - t0
    assert_operator elapsed, :>=, 2.5
    assert_operator elapsed, :<=, 6.0
    is_expected_error = err.is_a?(Gapic::Rest::ResumableUpload::BadResponseError) ||
                        err.is_a?(Gapic::Rest::ResumableUpload::DeadlineExceededError)
    assert is_expected_error, "Expected BadResponseError or DeadlineExceededError, got #{err.class}"
    refute_includes phases, :uploading
  end

  # A4. Verifies fatal errors on start (403 and 404) immediately raise BadResponseError in < 0.5s without retrying.
  def test_fatal_error_on_start_raises_bad_response_immediately
    [403, 404].each do |code|
      config = build_start_error_config(
        scenario:        "fatal_error_on_start",
        scenario_config: { error_code: code }
      )

      driver = Gapic::Rest::ResumableUpload::Driver.new(
        client_stub: showcase_client_stub,
        config:      config
      )

      t0 = Process.clock_gettime Process::CLOCK_MONOTONIC
      err = assert_raises Gapic::Rest::ResumableUpload::BadResponseError do
        driver.run
      end
      t1 = Process.clock_gettime Process::CLOCK_MONOTONIC

      elapsed = t1 - t0
      assert_operator elapsed, :<, 0.5, "Expected failure in < 0.5s for HTTP #{code}, took #{elapsed}s"
      assert_match(/#{code}/, err.message)
      refute_includes phases, :uploading
    end
  end

  # A5. Verifies sequential executions with fresh client UUIDs remain isolated.
  def test_sequential_runs_session_isolation
    2.times do
      config = build_start_error_config(
        scenario:           "non_fatal_error_on_start",
        scenario_config:    { error_code: 503, failure_count: 1 },
        start_retry_policy: FAST_RETRY
      )

      driver = Gapic::Rest::ResumableUpload::Driver.new(
        client_stub: showcase_client_stub,
        config:      config
      )

      result = driver.run
      parsed = JSON.parse result

      assert_equal PAYLOAD_SIZE, parsed["size"]
      assert_equal 1, phases.count(:initiating)
      assert_equal :completed, phases.last
    end
  end
end
