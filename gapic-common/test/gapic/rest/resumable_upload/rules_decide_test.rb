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
# Tests for ResumableUpload Rules.decide transitions per router row.
#
class RulesDecideTest < Minitest::Test
  include Gapic::Rest::ResumableUpload

  def setup
    @config = StartUploadConfig.new(
      initial_url:     "https://example.com/upload",
      initial_headers: { "X-Custom" => "value" },
      initial_body:    '{"name":"obj"}',
      stream:          StringIO.new("data"),
      upload_size:     1024,
      chunk_size:      512
    )
  end

  def test_recipe_phases_partition
    notifying = Rules::RECIPE_PHASES.keys
    non_notifying = Rules::NON_NOTIFYING_RECIPES
    all_classified = notifying + non_notifying

    assert_empty Rules::RECIPES - all_classified,
                 "Recipes missing from RECIPE_PHASES or NON_NOTIFYING_RECIPES"
    assert_empty all_classified - Rules::RECIPES,
                 "Phantom recipes in RECIPE_PHASES or NON_NOTIFYING_RECIPES"
    assert_empty notifying & non_notifying,
                 "Recipes present in both RECIPE_PHASES and NON_NOTIFYING_RECIPES"
  end

  def test_row_initializing_start_upload
    decision = Rules.decide State.new(status: :initializing), Event::StartUpload.new, @config
    assert_equal :initializing, decision.from_status
    assert_equal :start_upload, decision.shape
    assert_equal :start_session, decision.recipe
    assert_equal :starting, decision.next_state.status
    assert_recipe_progress_notification decision
    assert_instance_of Instruction::SendStart, decision.instructions[1]
  end

  def test_row_initializing_resume_upload
    resume_config = ResumeUploadConfig.new(
      upload_url:  "https://example.com/upload/session1",
      chunk_size:  512,
      stream:      StringIO.new("data"),
      upload_size: 1024
    )
    decision = Rules.decide State.new(status: :initializing), Event::ResumeUpload.new, resume_config
    assert_equal :initializing, decision.from_status
    assert_equal :resume_upload, decision.shape
    assert_equal :resume_session, decision.recipe
    assert_equal :recovery, decision.next_state.status
    assert_equal "https://example.com/upload/session1", decision.next_state.upload_url
    assert_equal 512, decision.next_state.chunk_size
    assert_equal 0, decision.next_state.offset
    assert_recipe_progress_notification decision
    assert_instance_of Instruction::SendQuery, decision.instructions[1]
    assert_equal "https://example.com/upload/session1", decision.instructions[1].url
  end

  def test_row_starting_response_active
    active_resp = Event::HttpResponse.new(
      status:  200,
      headers: { "x-goog-upload-status" => "active", "x-goog-upload-url" => "https://example.com/session" }
    )
    decision = Rules.decide State.new(status: :starting), active_resp, @config
    assert_equal :starting, decision.from_status
    assert_equal :response_active, decision.shape
    assert_equal :begin_transmission, decision.recipe
    assert_equal :transmission_reading, decision.next_state.status
    assert_recipe_progress_notification decision
    assert_instance_of Instruction::FillBuffer, decision.instructions[1]
  end

  def test_row_transmission_reading_chunk_read_full
    decision = Rules.decide(
      State.new(status: :transmission_reading, upload_url: "https://example.com/session"),
      Event::ChunkRead.new(bytes_buffered: 512, eof: false),
      @config
    )
    assert_equal :transmission_reading, decision.from_status
    assert_equal :chunk_read_full, decision.shape
    assert_equal :send_chunk, decision.recipe
    assert_equal :transmission_sending, decision.next_state.status
    assert_recipe_progress_notification decision
    assert_instance_of Instruction::SendChunk, decision.instructions.first
    refute decision.instructions.first.finalize
  end

  def test_row_transmission_reading_chunk_read_eof_with_data
    decision = Rules.decide(
      State.new(status: :transmission_reading, upload_url: "https://example.com/session"),
      Event::ChunkRead.new(bytes_buffered: 256, eof: true),
      @config
    )
    assert_equal :transmission_reading, decision.from_status
    assert_equal :chunk_read_eof_with_data, decision.shape
    assert_equal :send_upload_finalize, decision.recipe
    assert_equal :finalizing_sending_upload, decision.next_state.status
    assert_recipe_progress_notification decision
    assert_instance_of Instruction::SendChunk, decision.instructions[1]
    assert decision.instructions[1].finalize
  end

  def test_row_transmission_reading_chunk_read_eof_empty
    decision = Rules.decide(
      State.new(status: :transmission_reading, upload_url: "https://example.com/session"),
      Event::ChunkRead.new(bytes_buffered: 0, eof: true),
      @config
    )
    assert_equal :transmission_reading, decision.from_status
    assert_equal :chunk_read_eof_empty, decision.shape
    assert_equal :send_finalize, decision.recipe
    assert_equal :finalizing_sending_finalize, decision.next_state.status
    assert_recipe_progress_notification decision
    assert_instance_of Instruction::SendFinalize, decision.instructions[1]
  end

  def test_row_transmission_sending_response_active
    active_resp = Event::HttpResponse.new(
      status:  200,
      headers: { "x-goog-upload-status" => "active", "x-goog-upload-url" => "https://example.com/session" }
    )
    decision = Rules.decide(
      State.new(status: :transmission_sending, upload_url: "https://example.com/session", offset: 0, in_flight_length: 512),
      active_resp,
      @config
    )
    assert_equal :transmission_sending, decision.from_status
    assert_equal :response_active, decision.shape
    assert_equal :ack_chunk, decision.recipe
    assert_equal :transmission_reading, decision.next_state.status
    assert_recipe_progress_notification decision
    assert_equal 3, decision.instructions.size
  end

  def test_row_transmission_sending_enter_recovery
    cat2_resp = Event::HttpResponse.new status: 503, headers: {}
    decision = Rules.decide(
      State.new(status: :transmission_sending, upload_url: "https://example.com/session"),
      cat2_resp,
      @config
    )
    assert_equal :transmission_sending, decision.from_status
    assert_equal :response_cat2, decision.shape
    assert_equal :enter_recovery, decision.recipe
    assert_equal :recovery, decision.next_state.status
    assert_recipe_progress_notification decision
    assert_instance_of Instruction::SendQuery, decision.instructions[1]
  end

  def test_row_finalizing_sending_upload_response_final
    final_resp = Event::HttpResponse.new status: 200, headers: { "x-goog-upload-status" => "final" }
    decision = Rules.decide(
      State.new(status: :finalizing_sending_upload, offset: 512, in_flight_length: 512),
      final_resp,
      @config
    )
    assert_equal :finalizing_sending_upload, decision.from_status
    assert_equal :response_final, decision.shape
    assert_equal :complete_upload_with_data, decision.recipe
    assert_equal :success, decision.next_state.status
    assert_recipe_progress_notification decision
    assert_equal 2, decision.instructions.size
  end

  def test_row_finalizing_sending_finalize_response_final
    final_resp = Event::HttpResponse.new status: 200, headers: { "x-goog-upload-status" => "final" }
    decision = Rules.decide State.new(status: :finalizing_sending_finalize), final_resp, @config
    assert_equal :finalizing_sending_finalize, decision.from_status
    assert_equal :response_final, decision.shape
    assert_equal :complete_upload_finalized, decision.recipe
    assert_equal :success, decision.next_state.status
    assert_recipe_progress_notification decision
    assert_instance_of Instruction::TerminateSuccess, decision.instructions[1]
  end

  def test_row_recovery_response_active
    recovery_active_resp = Event::HttpResponse.new(
      status:  200,
      headers: { "x-goog-upload-status" => "active", "x-goog-upload-size-received" => "256" }
    )
    decision = Rules.decide State.new(status: :recovery), recovery_active_resp, @config
    assert_equal :recovery, decision.from_status
    assert_equal :response_active, decision.shape
    assert_equal :realign_from_recovery, decision.recipe
    assert_equal :transmission_reading, decision.next_state.status
    assert_recipe_progress_notification decision
    assert_instance_of Instruction::RealignBuffer, decision.instructions[1]
  end

  def test_row_recovery_response_cat2
    cat2_resp = Event::HttpResponse.new status: 503, headers: {}
    decision = Rules.decide State.new(status: :recovery), cat2_resp, @config
    assert_equal :recovery, decision.from_status
    assert_equal :response_cat2, decision.shape
    assert_equal :retry_recovery, decision.recipe
    assert_equal :recovery, decision.next_state.status
    assert_recipe_progress_notification decision
    assert_instance_of Instruction::SendQuery, decision.instructions.first
  end

  def test_row_cancelling_response_cancelled
    cancelled_resp = Event::HttpResponse.new status: 200, headers: { "x-goog-upload-status" => "cancelled" }
    decision = Rules.decide State.new(status: :cancelling), cancelled_resp, @config
    assert_equal :cancelling, decision.from_status
    assert_equal :response_cancelled, decision.shape
    assert_equal :complete_cancellation, decision.recipe
    assert_equal :cancelled, decision.next_state.status
    assert_recipe_progress_notification decision
    assert_instance_of Instruction::TerminateFailure, decision.instructions.first
  end

  def test_row_cancelling_user_cancel_falls_through_to_wildcard
    decision = Rules.decide State.new(status: :cancelling), Event::Cancel.new, @config
    assert_equal :cancelling, decision.from_status
    assert_equal :user_cancel, decision.shape
    assert_equal :cancel_session, decision.recipe
    assert_equal :cancelling, decision.next_state.status
    assert_recipe_progress_notification decision
    assert_instance_of Instruction::SendCancel, decision.instructions[1]
  end

  def test_row_global_deadline_exceeded
    decision = Rules.decide State.new(status: :transmission_sending), Event::GlobalDeadlineExceeded.new, @config
    assert_equal :transmission_sending, decision.from_status
    assert_equal :global_deadline_exceeded, decision.shape
    assert_equal :fail_with_deadline_exceeded, decision.recipe
    assert_equal :error, decision.next_state.status
    assert_recipe_progress_notification decision
    assert_instance_of DeadlineExceededError, decision.next_state.last_error
  end

  def test_row_user_cancel
    decision = Rules.decide State.new(status: :transmission_sending), Event::Cancel.new, @config
    assert_equal :transmission_sending, decision.from_status
    assert_equal :user_cancel, decision.shape
    assert_equal :cancel_session, decision.recipe
    assert_equal :cancelling, decision.next_state.status
    assert_recipe_progress_notification decision
    assert_instance_of Instruction::SendCancel, decision.instructions[1]
  end

  def test_row_response_rejected
    rejected_resp = Event::HttpResponse.new status: 403, headers: { "x-goog-upload-status" => "final" }, body: "Rejected"
    decision = Rules.decide State.new(status: :starting), rejected_resp, @config
    assert_equal :starting, decision.from_status
    assert_equal :response_rejected, decision.shape
    assert_equal :fail_with_rejected, decision.recipe
    assert_equal :rejected, decision.next_state.status
    assert_recipe_progress_notification decision
    assert_instance_of UploadRejectedError, decision.next_state.last_error
  end

  def test_row_fail_with_bad_response
    cat2_resp = Event::HttpResponse.new status: 503, headers: {}
    decision = Rules.decide State.new(status: :starting), cat2_resp, @config
    assert_equal :starting, decision.from_status
    assert_equal :response_cat2, decision.shape
    assert_equal :fail_with_bad_response, decision.recipe
    assert_equal :error, decision.next_state.status
    assert_recipe_progress_notification decision
    assert_instance_of BadResponseError, decision.next_state.last_error
  end

  def test_row_fail_with_request_error
    req_failed = Event::RequestFailed.new kind: :retries_exhausted, message: "Exhausted"
    decision = Rules.decide State.new(status: :starting), req_failed, @config
    assert_equal :starting, decision.from_status
    assert_equal :request_retries_exhausted, decision.shape
    assert_equal :fail_with_request_error, decision.recipe
    assert_equal :error, decision.next_state.status
    assert_recipe_progress_notification decision
    assert_instance_of Instruction::TerminateFailure, decision.instructions.first
  end

  private

  def assert_recipe_progress_notification decision
    if Rules::RECIPE_PHASES.key? decision.recipe
      expected_phase = Rules::RECIPE_PHASES[decision.recipe]
      first_inst = decision.instructions.first
      assert_instance_of Instruction::NotifyProgress, first_inst,
                         "Expected #{decision.recipe} to emit NotifyProgress as first instruction"
      assert_equal expected_phase, first_inst.progress.phase,
                   "Expected #{decision.recipe} to emit phase #{expected_phase}"
    else
      assert_includes Rules::NON_NOTIFYING_RECIPES, decision.recipe
      refute decision.instructions.any? { |i| i.is_a? Instruction::NotifyProgress },
             "Expected non-notifying recipe #{decision.recipe} to emit no NotifyProgress"
    end
  end
end
