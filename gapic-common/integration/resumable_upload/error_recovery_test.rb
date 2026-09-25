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
require "stringio"

##
# Suite B: Integration tests for Category 1 transient retries and Category 2 error recovery against
# Showcase, driven through ::Gapic::ResumableUpload. The short data- and control-plane policies come from
# the coordinator's `@private` constructor arguments, so these run on the production code path.
#
class ErrorRecoveryTest < ShowcaseIntegrationTest
  SCENARIO = "non_fatal_error_on_chunk_upload"

  # B1. Verifies Category 1 transient error (503) is retried transparently by FAST_RETRY without entering recovery.
  def test_cat1_error_retried_transparently
    upload = build_upload(
      scenario:        SCENARIO,
      scenario_config: { error_code: 503, failure_count: 1, after_offset: 0 }
    )

    result = upload.start(**start_args)
    parsed = JSON.parse result

    assert_equal DEFAULT_PAYLOAD_SIZE, parsed["size"]
    refute_includes phases, :recovering
    assert_equal [:initiating, :uploading, :uploading, :uploading, :uploading, :finalizing, :completed], phases
    assert_equal [0, 0, 262_144, 524_288, 786_432, 786_432, 786_432], offsets
  end

  # B2. Verifies simple Category 2 error (409) at offset 0 triggers recovery query and resumes upload to completion.
  def test_simple_cat2_error_recovery
    upload = build_upload(
      scenario:        SCENARIO,
      scenario_config: { error_code: 409, failure_count: 1, after_offset: 0 }
    )

    result = upload.start(**start_args)
    parsed = JSON.parse result

    assert_equal DEFAULT_PAYLOAD_SIZE, parsed["size"]
    assert_equal(
      [:initiating, :uploading, :recovering, :uploading, :uploading, :uploading, :uploading, :finalizing, :completed],
      phases
    )
    assert_equal [0, 0, 0, 0, 262_144, 524_288, 786_432, 786_432, 786_432], offsets
  end

  # B3. Verifies two consecutive Category 2 recoveries (409) on chunk 2 at offset 262_144.
  def test_two_consecutive_cat2_recoveries_on_chunk_2
    upload = build_upload(
      scenario:        SCENARIO,
      scenario_config: { error_code: 409, failure_count: 2, after_offset: 262_144 }
    )

    result = upload.start(**start_args)
    parsed = JSON.parse result

    assert_equal DEFAULT_PAYLOAD_SIZE, parsed["size"]
    assert_equal(
      [
        :initiating, :uploading, :uploading,
        :recovering, :uploading,
        :recovering, :uploading,
        :uploading, :uploading, :finalizing, :completed
      ],
      phases
    )
    assert_equal [0, 0, 262_144, 262_144, 262_144, 262_144, 262_144, 524_288, 786_432, 786_432, 786_432], offsets
  end

  # B4. Verifies Category 2 error (409) on the finalizing chunk (upload, finalize) recovers and completes.
  def test_cat2_failure_on_finalizing_chunk
    size = (DEFAULT_CHUNK_SIZE * 3) - 100
    upload = build_upload(
      scenario:        SCENARIO,
      scenario_config: { error_code: 409, failure_count: 1, after_offset: DEFAULT_CHUNK_SIZE * 2 }
    )

    result = upload.start(**start_args(stream: StringIO.new(payload(size)), upload_size: size))
    parsed = JSON.parse result

    assert_equal size, parsed["size"]
    assert_equal(
      [:initiating, :uploading, :uploading, :uploading, :finalizing, :recovering, :uploading, :finalizing, :completed],
      phases
    )
    assert_equal [0, 0, 262_144, 524_288, 524_288, 524_288, 524_288, 524_288, size], offsets
  end

  # B5. Verifies unrecoverable 500 without status header triggers repeated recovery until DeadlineExceededError.
  # A 500 is a default retry code on every plane, so the Driver re-sends each request until its plane budget
  # runs out; the budgets are kept well inside the upload timeout so the exhausted outcomes reach Rules.
  def test_no_headers_failure_recovers_until_deadline_exceeded
    short_budget = FAST_RETRY.merge timeout: 0.1
    upload = build_upload(
      scenario:                   SCENARIO,
      scenario_config:            { failure_count: 0, action_after_failures: "terminate" },
      control_plane_retry_policy: short_budget,
      data_plane_retry_policy:    short_budget
    )

    assert_raises Gapic::Rest::ResumableUpload::DeadlineExceededError do
      upload.start(**start_args(upload_timeout: 1))
    end

    assert_operator phases.count(:recovering), :>=, 2
  end

  # B6. Verifies an unrecoverable headerless 500 on the data plane is re-sent in place, without entering
  # recovery, while the data plane budget lasts.
  def test_no_headers_failure_is_resent_within_the_data_plane_budget
    upload = build_upload(
      scenario:        SCENARIO,
      scenario_config: { failure_count: 0, action_after_failures: "terminate" }
    )

    assert_raises Gapic::Rest::ResumableUpload::DeadlineExceededError do
      upload.start(**start_args(upload_timeout: 1))
    end

    refute_includes phases, :recovering
    assert_operator @log_output.string.scan('"command":"upload"').size, :>=, 2
  end
end
