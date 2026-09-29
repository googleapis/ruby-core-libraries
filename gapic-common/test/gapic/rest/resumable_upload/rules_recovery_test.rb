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
# Tests for ResumableUpload Rules protocol recovery state transitions.
#
class RulesRecoveryTest < Minitest::Test
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

  def test_transition_transmission_sending_cat2_triggers_recovery
    state = State.new status: :transmission_sending, upload_url: "https://example.com/session", offset: 0,
                      in_flight_length: 512
    resp = Event::HttpResponse.new status: 503, headers: {}
    next_state, instructions = Rules.step state, resp, @config

    assert_equal :recovery, next_state.status
    assert_equal 0, next_state.in_flight_length
    assert_equal 2, instructions.size
    assert_instance_of Instruction::NotifyProgress, instructions[0]
    assert_equal Progress.new(phase: :recovering, bytes_uploaded: 0, total_bytes: 1024), instructions[0].progress
    assert_instance_of Instruction::SendQuery, instructions[1]
  end

  def test_transition_transmission_sending_connection_failed_triggers_recovery
    state = State.new status: :transmission_sending, upload_url: "https://example.com/session", offset: 0,
                      in_flight_length: 512
    req_failed = Event::RequestFailed.new kind: :connection_failed, message: "Network unreachable"
    next_state, instructions = Rules.step state, req_failed, @config

    assert_equal :recovery, next_state.status
    assert_equal 0, next_state.in_flight_length
    assert_equal 2, instructions.size
    assert_instance_of Instruction::NotifyProgress, instructions[0]
    assert_equal Progress.new(phase: :recovering, bytes_uploaded: 0, total_bytes: 1024), instructions[0].progress
    assert_instance_of Instruction::SendQuery, instructions[1]
  end

  def test_transition_transmission_sending_timeout_triggers_recovery
    state = State.new status: :transmission_sending, upload_url: "https://example.com/session", offset: 0,
                      in_flight_length: 512
    req_failed = Event::RequestFailed.new kind: :timeout, message: "Read timeout"
    next_state, instructions = Rules.step state, req_failed, @config

    assert_equal :recovery, next_state.status
    assert_equal 0, next_state.in_flight_length
    assert_equal 2, instructions.size
    assert_instance_of Instruction::NotifyProgress, instructions[0]
    assert_equal Progress.new(phase: :recovering, bytes_uploaded: 0, total_bytes: 1024), instructions[0].progress
    assert_instance_of Instruction::SendQuery, instructions[1]
  end

  def test_transition_finalizing_sending_upload_timeout_triggers_recovery
    state = State.new status: :finalizing_sending_upload, upload_url: "https://example.com/session", offset: 512,
                      in_flight_length: 512
    req_failed = Event::RequestFailed.new kind: :timeout, message: "Read timeout"
    next_state, instructions = Rules.step state, req_failed, @config

    assert_equal :recovery, next_state.status
    assert_equal 0, next_state.in_flight_length
    assert_equal 2, instructions.size
    assert_instance_of Instruction::NotifyProgress, instructions[0]
    assert_equal Progress.new(phase: :recovering, bytes_uploaded: 512, total_bytes: 1024), instructions[0].progress
    assert_instance_of Instruction::SendQuery, instructions[1]
  end

  def test_transition_recovery_active_realigns_buffer
    state = State.new status: :recovery, upload_url: "https://example.com/session", offset: 0, chunk_size: 512
    headers = {
      "x-goog-upload-status"        => "active",
      "x-goog-upload-size-received" => "768"
    }
    resp = Event::HttpResponse.new status: 200, headers: headers
    next_state, instructions = Rules.step state, resp, @config

    assert_equal :transmission_reading, next_state.status
    assert_equal 768, next_state.offset
    assert_equal 3, instructions.size
    assert_instance_of Instruction::NotifyProgress, instructions[0]
    assert_equal Progress.new(phase: :uploading, bytes_uploaded: 768, total_bytes: 1024), instructions[0].progress
    assert_instance_of Instruction::RealignBuffer, instructions[1]
    assert_equal 768, instructions[1].server_offset
    assert_instance_of Instruction::FillBuffer, instructions[2]
  end

  def test_transition_recovery_final_completes_upload
    state = State.new status: :recovery, upload_url: "https://example.com/session", offset: 512
    resp = Event::HttpResponse.new status: 200, headers: { "x-goog-upload-status" => "final" }
    next_state, instructions = Rules.step state, resp, @config

    assert_equal :success, next_state.status
    assert_equal 2, instructions.size
    assert_instance_of Instruction::NotifyProgress, instructions[0]
    assert_equal Progress.new(phase: :completed, bytes_uploaded: 512, total_bytes: 512), instructions[0].progress
    assert_instance_of Instruction::TerminateSuccess, instructions[1]
  end

  def test_transition_recovery_cat2_retries_query
    state = State.new status: :recovery, upload_url: "https://example.com/session"
    resp = Event::HttpResponse.new status: 416, headers: {}
    next_state, instructions = Rules.step state, resp, @config

    assert_equal :recovery, next_state.status
    assert_equal 1, instructions.size
    assert_instance_of Instruction::SendQuery, instructions.first
  end
end
