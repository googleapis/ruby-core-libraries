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
# Tests for recovery episode tracking in Rules: which recipes open, continue and close an episode
# (`State#recovery_offset`), and which queries wait for the episode's backoff (`SendQuery#backoff`).
#
# See `design/resumable_upload/implementation-guide.md` section 6.2.1.
#
class RulesRecoveryEpisodeTest < Minitest::Test
  include Gapic::Rest::ResumableUpload

  SESSION_URL = "https://example.com/session"

  def setup
    @config = StartUploadConfig.new(
      initial_url: "https://example.com/upload",
      stream:      StringIO.new("0123456789"),
      upload_size: 10,
      chunk_size:  4
    )
  end

  def test_send_query_defaults_to_opening_an_episode
    refute Instruction::SendQuery.new(url: SESSION_URL).backoff
  end

  def test_state_starts_with_no_open_episode
    assert_nil State.new.recovery_offset
  end

  def test_resume_session_opens_an_episode_at_offset_zero_and_queries_at_once
    config = ResumeUploadConfig.new upload_url: SESSION_URL, chunk_size: 4, stream: StringIO.new("0123"),
                                    upload_size: 4
    next_state, instructions = Rules.step State.new, Event::ResumeUpload.new, config

    assert_equal 0, next_state.recovery_offset
    refute query_in(instructions).backoff
  end

  def test_enter_recovery_with_no_open_episode_opens_one_at_the_current_offset
    state = sending_state offset: 4
    next_state, instructions = Rules.step state, cat2_response, @config

    assert_equal :recovery, next_state.status
    assert_equal 4, next_state.recovery_offset
    refute query_in(instructions).backoff
  end

  def test_enter_recovery_with_an_open_episode_backs_off_and_keeps_the_episode_start
    state = sending_state(offset: 4).with recovery_offset: 4
    next_state, instructions = Rules.step state, cat2_response, @config

    assert_equal 4, next_state.recovery_offset
    assert query_in(instructions).backoff
  end

  def test_enter_recovery_on_a_connection_failure_follows_the_same_rule
    failure = Event::RequestFailed.new kind: :connection_failed, message: "reset"

    _, opening = Rules.step sending_state(offset: 0), failure, @config
    _, continuing = Rules.step sending_state(offset: 0).with(recovery_offset: 0), failure, @config

    refute query_in(opening).backoff
    assert query_in(continuing).backoff
  end

  def test_retry_recovery_backs_off_and_keeps_the_episode_start
    state = recovery_state offset: 4, recovery_offset: 4
    next_state, instructions = Rules.step state, cat2_response, @config

    assert_equal :recovery, next_state.status
    assert_equal 4, next_state.recovery_offset
    assert query_in(instructions).backoff
  end

  def test_realign_without_progress_keeps_the_episode_open
    state = recovery_state offset: 4, recovery_offset: 4
    next_state, = Rules.step state, query_response(received: 4), @config

    assert_equal :transmission_reading, next_state.status
    assert_equal 4, next_state.recovery_offset
  end

  # A lower offset is a regression, not progress: the episode stays open at its starting offset while the
  # client rewinds.
  def test_realign_to_a_lower_offset_keeps_the_episode_open
    state = recovery_state offset: 4, recovery_offset: 4
    next_state, = Rules.step state, query_response(received: 2), @config

    assert_equal 2, next_state.offset
    assert_equal 4, next_state.recovery_offset
  end

  def test_realign_with_progress_closes_the_episode
    state = recovery_state offset: 4, recovery_offset: 4
    next_state, = Rules.step state, query_response(received: 8), @config

    assert_equal 8, next_state.offset
    assert_nil next_state.recovery_offset
  end

  def test_ack_chunk_closes_the_episode
    state = sending_state(offset: 4).with recovery_offset: 4
    next_state, = Rules.step state, Event::HttpResponse.new(status: 200, headers: { "x-goog-upload-status" => "active" }),
                             @config

    assert_equal 8, next_state.offset
    assert_nil next_state.recovery_offset
  end

  # Loop B from the design doc: an upload that keeps failing while the query keeps answering `active`
  # at the same offset. Only the first query of the episode is sent at once.
  def test_repeated_failures_without_progress_back_off_every_query_after_the_first
    state = sending_state offset: 0
    backoffs = []

    3.times do
      state, instructions = Rules.step state, cat2_response, @config
      backoffs << query_in(instructions).backoff
      state, = Rules.step state, query_response(received: 0), @config
      state = state.with status: :transmission_sending, in_flight_length: 4
    end

    assert_equal [false, true, true], backoffs
  end

  private

  def sending_state offset:
    State.new status: :transmission_sending, upload_url: SESSION_URL, offset: offset, chunk_size: 4,
              in_flight_length: 4
  end

  def recovery_state offset:, recovery_offset:
    State.new status: :recovery, upload_url: SESSION_URL, offset: offset, chunk_size: 4,
              recovery_offset: recovery_offset
  end

  def cat2_response
    Event::HttpResponse.new status: 502, headers: {}
  end

  def query_response received:
    Event::HttpResponse.new status:  200,
                            headers: { "x-goog-upload-status" => "active", "x-goog-upload-size-received" => received.to_s }
  end

  def query_in instructions
    queries = instructions.grep Instruction::SendQuery
    assert_equal 1, queries.size, "Expected exactly one SendQuery in #{instructions.map(&:class)}"
    queries.first
  end
end
