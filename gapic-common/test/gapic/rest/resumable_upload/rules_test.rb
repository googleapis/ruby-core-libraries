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
# Tests for ResumableUpload Rules normal progression and session lifecycle state transitions.
#
class RulesTest < Minitest::Test
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

  def test_transition_initializing_to_starting
    state = State.new status: :initializing
    next_state, instructions = Rules.step state, Event::StartUpload.new, @config

    assert_equal :starting, next_state.status
    assert_equal 2, instructions.size
    assert_instance_of Instruction::NotifyProgress, instructions[0]
    assert_equal Progress.new(phase: :initiating, bytes_uploaded: 0, total_bytes: 1024), instructions[0].progress
    assert_instance_of Instruction::SendStart, instructions[1]
    assert_equal "https://example.com/upload", instructions[1].url
    assert_equal({ "X-Custom" => "value" }, instructions[1].headers)
    assert_equal '{"name":"obj"}', instructions[1].body
  end

  def test_transition_starting_to_transmission_reading
    state = State.new status: :starting
    headers = {
      "x-goog-upload-status"            => "active",
      "x-goog-upload-url"               => "https://example.com/session",
      "x-goog-upload-chunk-granularity" => "256"
    }
    resp = Event::HttpResponse.new status: 200, headers: headers
    next_state, instructions = Rules.step state, resp, @config

    assert_equal :transmission_reading, next_state.status
    assert_equal "https://example.com/session", next_state.upload_url
    assert_equal 256, next_state.chunk_granularity
    assert_equal 512, next_state.chunk_size
    assert_equal 0, next_state.offset
    assert_equal 0, next_state.in_flight_length
    assert_equal 2, instructions.size
    assert_instance_of Instruction::NotifyProgress, instructions[0]
    assert_equal Progress.new(phase: :uploading, bytes_uploaded: 0, total_bytes: 1024), instructions[0].progress
    assert_instance_of Instruction::FillBuffer, instructions[1]
    assert_equal 512, instructions[1].target_bytesize
  end

  def test_transition_transmission_reading_full_chunk
    state = State.new status: :transmission_reading, upload_url: "https://example.com/session", offset: 0,
                      chunk_size: 512
    event = Event::ChunkRead.new bytes_buffered: 512, eof: false
    next_state, instructions = Rules.step state, event, @config

    assert_equal :transmission_sending, next_state.status
    assert_equal 512, next_state.in_flight_length
    assert_equal 1, instructions.size
    assert_instance_of Instruction::SendChunk, instructions.first
    assert_equal 0, instructions.first.offset
    assert_equal 512, instructions.first.length
    refute instructions.first.finalize
  end

  def test_transition_transmission_reading_eof_with_data
    state = State.new status: :transmission_reading, upload_url: "https://example.com/session", offset: 512,
                      chunk_size: 512
    event = Event::ChunkRead.new bytes_buffered: 200, eof: true
    next_state, instructions = Rules.step state, event, @config

    assert_equal :finalizing_sending_upload, next_state.status
    assert_equal 200, next_state.in_flight_length
    assert_equal 2, instructions.size
    assert_instance_of Instruction::NotifyProgress, instructions[0]
    assert_equal Progress.new(phase: :finalizing, bytes_uploaded: 512, total_bytes: 1024), instructions[0].progress
    assert_instance_of Instruction::SendChunk, instructions[1]
    assert_equal 512, instructions[1].offset
    assert_equal 200, instructions[1].length
    assert instructions[1].finalize
  end

  def test_transition_transmission_reading_eof_empty
    state = State.new status: :transmission_reading, upload_url: "https://example.com/session", offset: 1024,
                      chunk_size: 512
    event = Event::ChunkRead.new bytes_buffered: 0, eof: true
    next_state, instructions = Rules.step state, event, @config

    assert_equal :finalizing_sending_finalize, next_state.status
    assert_equal 0, next_state.in_flight_length
    assert_equal 2, instructions.size
    assert_instance_of Instruction::NotifyProgress, instructions[0]
    assert_equal Progress.new(phase: :finalizing, bytes_uploaded: 1024, total_bytes: 1024), instructions[0].progress
    assert_instance_of Instruction::SendFinalize, instructions[1]
    assert_equal "https://example.com/session", instructions[1].url
  end

  def test_transition_transmission_sending_ack_chunk
    state = State.new status: :transmission_sending, upload_url: "https://example.com/session", offset: 0,
                      in_flight_length: 512, chunk_size: 512
    resp = Event::HttpResponse.new status: 200, headers: { "x-goog-upload-status" => "active" }
    next_state, instructions = Rules.step state, resp, @config

    assert_equal :transmission_reading, next_state.status
    assert_equal 512, next_state.offset
    assert_equal 0, next_state.in_flight_length
    assert_equal 3, instructions.size
    assert_instance_of Instruction::NotifyProgress, instructions[0]
    assert_equal Progress.new(phase: :uploading, bytes_uploaded: 512, total_bytes: 1024), instructions[0].progress
    assert_instance_of Instruction::RealignBuffer, instructions[1]
    assert_equal 512, instructions[1].server_offset
    assert_instance_of Instruction::FillBuffer, instructions[2]
    assert_equal 512, instructions[2].target_bytesize
  end

  def test_transition_finalizing_sending_upload_success
    state = State.new status: :finalizing_sending_upload, offset: 512, in_flight_length: 512
    resp = Event::HttpResponse.new status: 200, headers: { "x-goog-upload-status" => "final" }, body: '{"done":true}'
    next_state, instructions = Rules.step state, resp, @config

    assert_equal :success, next_state.status
    assert_equal 1024, next_state.offset
    assert_equal 0, next_state.in_flight_length
    assert_equal 2, instructions.size
    assert_instance_of Instruction::NotifyProgress, instructions[0]
    assert_equal Progress.new(phase: :completed, bytes_uploaded: 1024, total_bytes: 1024), instructions[0].progress
    assert_instance_of Instruction::TerminateSuccess, instructions[1]
  end

  def test_transition_finalizing_sending_finalize_success
    state = State.new status: :finalizing_sending_finalize, offset: 1024, in_flight_length: 0
    resp = Event::HttpResponse.new status: 200, headers: { "x-goog-upload-status" => "final" }, body: '{"done":true}'
    next_state, instructions = Rules.step state, resp, @config

    assert_equal :success, next_state.status
    assert_equal 2, instructions.size
    assert_instance_of Instruction::NotifyProgress, instructions[0]
    assert_equal Progress.new(phase: :completed, bytes_uploaded: 1024, total_bytes: 1024), instructions[0].progress
    assert_instance_of Instruction::TerminateSuccess, instructions[1]
  end

  def test_transition_cancellation_flow
    state = State.new status: :transmission_sending, upload_url: "https://example.com/session"
    next_state, instructions = Rules.step state, Event::Cancel.new, @config

    assert_equal :cancelling, next_state.status
    assert_equal 2, instructions.size
    assert_instance_of Instruction::NotifyProgress, instructions[0]
    assert_equal Progress.new(phase: :cancelling, bytes_uploaded: 0, total_bytes: 1024), instructions[0].progress
    assert_instance_of Instruction::SendCancel, instructions[1]

    # A duplicate cancel re-enters cancel_session through the wildcard arm and re-issues the command
    dup_state, dup_instructions = Rules.step next_state, Event::Cancel.new, @config
    assert_equal :cancelling, dup_state.status
    assert_equal 2, dup_instructions.size
    assert_instance_of Instruction::SendCancel, dup_instructions[1]

    # Cancellation confirmed
    resp = Event::HttpResponse.new status: 200, headers: { "x-goog-upload-status" => "cancelled" }
    final_state, final_instructions = Rules.step next_state, resp, @config
    assert_equal :cancelled, final_state.status
    assert_instance_of UploadCancelledError, final_state.last_error
    assert_equal 1, final_instructions.size
    assert_instance_of Instruction::TerminateFailure, final_instructions.first
  end

  def test_all_recipes_respond_to_rules_method
    Rules::RECIPES.each do |recipe|
      assert_respond_to Rules, recipe
    end
  end

  def test_all_recipes_satisfy_trampoline_invariant
    resume_config = ResumeUploadConfig.new(
      upload_url: "https://example.com/session",
      chunk_size: 256,
      stream:     StringIO.new("abcd")
    )
    active_resp = Event::HttpResponse.new status: 200, headers: {
      "x-goog-upload-url"           => "https://example.com/session",
      "x-goog-upload-status"        => "active",
      "x-goog-upload-size-received" => "256"
    }
    final_resp = Event::HttpResponse.new status: 200, headers: { "x-goog-upload-status" => "final" }
    cancelled_resp = Event::HttpResponse.new status: 200, headers: { "x-goog-upload-status" => "cancelled" }
    cat2_resp = Event::HttpResponse.new status: 503, headers: {}
    rejected_resp = Event::HttpResponse.new status: 403, headers: { "x-goog-upload-status" => "final" }
    bad_resp = Event::HttpResponse.new status: 401, headers: {}
    req_err = Event::RequestFailed.new kind: :connection_failed, message: "connection lost"
    chunk_full = Event::ChunkRead.new bytes_buffered: 256, eof: false
    chunk_eof = Event::ChunkRead.new bytes_buffered: 256, eof: true
    base_state = State.new(
      status:           :transmission_sending,
      upload_url:       "https://example.com/session",
      chunk_size:       256,
      in_flight_length: 256
    )

    fixtures = {
      start_session:                  [State.new(status: :initializing), Event::StartUpload.new, @config],
      resume_session:                 [State.new(status: :initializing), Event::ResumeUpload.new, resume_config],
      begin_transmission:             [State.new(status: :starting), active_resp, @config],
      send_chunk:                     [base_state.with(status: :transmission_reading), chunk_full, @config],
      send_upload_finalize:           [base_state.with(status: :transmission_reading), chunk_eof, @config],
      send_finalize:                  [base_state.with(status: :transmission_reading), Event::ChunkRead.new(bytes_buffered: 0, eof: true), @config],
      ack_chunk:                      [base_state, active_resp, @config],
      enter_recovery:                 [base_state, cat2_resp, @config],
      retry_recovery:                 [base_state.with(status: :recovery), cat2_resp, @config],
      realign_from_recovery:          [base_state.with(status: :recovery), active_resp, @config],
      complete_upload_with_data:      [base_state.with(status: :finalizing_sending_upload), final_resp, @config],
      complete_upload_finalized:      [base_state.with(status: :finalizing_sending_finalize), final_resp, @config],
      cancel_session:                 [base_state, Event::Cancel.new, @config],
      complete_cancellation:          [base_state.with(status: :cancelling), cancelled_resp, @config],
      fail_with_deadline_exceeded:    [base_state, Event::GlobalDeadlineExceeded.new, @config],
      fail_with_rejected:             [base_state, rejected_resp, @config],
      fail_with_bad_response:         [base_state, bad_resp, @config],
      fail_with_request_error:        [base_state, req_err, @config],
      fail_with_unmatched_transition: [State.new(status: :success), Event::StartUpload.new, @config]
    }

    assert_equal Rules::RECIPES.sort, fixtures.keys.sort

    event_producing_types = [
      Instruction::FillBuffer,
      Instruction::SendStart,
      Instruction::SendChunk,
      Instruction::SendFinalize,
      Instruction::SendQuery,
      Instruction::SendCancel
    ].freeze
    terminal_types = [
      Instruction::TerminateSuccess,
      Instruction::TerminateFailure
    ].freeze

    fixtures.each do |recipe, (state, event, cfg)|
      if recipe == :fail_with_unmatched_transition
        assert_raises InvalidTransitionError do
          Rules.public_send recipe, state, event, cfg
        end
        next
      end

      _next_state, instructions = Rules.public_send recipe, state, event, cfg
      event_producing_count = instructions.count { |inst| event_producing_types.include? inst.class }
      terminal_count = instructions.count { |inst| terminal_types.include? inst.class }

      valid = (event_producing_count == 1 && terminal_count.zero?) ||
              (event_producing_count.zero? && terminal_count == 1)
      assert valid, "Recipe :#{recipe} produced #{event_producing_count} event-producing and #{terminal_count} terminal instructions"
    end
  end
end
