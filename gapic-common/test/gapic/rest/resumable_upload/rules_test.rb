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

    # Duplicate cancel in cancelling state does nothing
    dup_state, dup_instructions = Rules.step next_state, Event::Cancel.new, @config
    assert_equal :cancelling, dup_state.status
    assert_empty dup_instructions

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
end
