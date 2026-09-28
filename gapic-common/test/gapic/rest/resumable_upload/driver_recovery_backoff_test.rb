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
# Tests that recovery queries are spaced by one `Gapic::Common::RetryPolicy` per recovery episode.
#
# `Kernel.sleep` is stubbed to record delays instead of waiting: `RetryPolicy` performs every backoff through
# it. The control plane policy uses `jitter: 0` so the recorded delays are exact.
#
# See `design/resumable_upload/implementation-guide.md` section 6.2.1.
#
class DriverRecoveryBackoffTest < Minitest::Test
  include Gapic::Rest::ResumableUpload

  FakeResponse = Struct.new :status, :headers, :body, keyword_init: true

  SESSION_URL = "https://example.com/session/1"

  # Delays 1, 2, 4, then capped at 5.
  BACKOFF = { initial_delay: 1, multiplier: 2, max_delay: 5, jitter: 0 }.freeze

  # Fake client stub recording calls and yielding scripted outcomes. An Exception is raised, a Proc is
  # called, anything else is returned.
  class FakeClientStub
    attr_reader :requests

    def initialize outcomes
      @outcomes = outcomes
      @requests = []
    end

    def make_post_request uri:, body:, params:, options:, method_name: nil
      @requests << { uri: uri, body: body, params: params, options: options, method_name: method_name }
      raise "Unexpected request: no scripted response left" if @outcomes.empty?

      outcome = @outcomes.shift
      case outcome
      when Exception then raise outcome
      when Proc then outcome.call
      else outcome
      end
    end
  end

  # Retry policy whose budget is a fixed number of retries per `start!` instead of a wall-clock deadline.
  # Because the Driver starts the control plane policy once per recovery episode, the count is shared by
  # every query in the episode. `dup` is overridden because `RetryPolicy#dup` builds a plain `RetryPolicy`.
  class CountedRetryPolicy < Gapic::Common::RetryPolicy
    def initialize retries:, **kwargs
      @retries = retries
      super(timeout: 60, **kwargs)
    end

    def dup
      self.class.new retries: @retries, **overrides.except(:timeout)
    end

    def start! **kwargs
      @retries_left = @retries
      super
    end

    def retry_with_deadline?
      return false unless @retries_left.positive?
      @retries_left -= 1
      true
    end
  end

  # Loop A: a query answered with a Category 2 status that the control plane `retry_codes` do not cover
  # used to be re-sent with no delay until the global deadline.
  def test_endless_non_retriable_category_2_on_query_backs_off_across_queries
    [400, 408, 412, 416, 502].each do |status|
      outcomes = [initiation_response, Faraday::ConnectionFailed.new("reset")] +
                 Array.new(4) { http_error status } +
                 [query_response(received: 0), final_response]
      stub = FakeClientStub.new outcomes

      result, delays = run_recording_delays stub

      assert_equal '{"done":true}', result, "status #{status}"
      assert_equal [1.0, 2.0, 4.0, 5.0], delays, "status #{status}"
      assert_commands stub, ["start", "upload, finalize"] + Array.new(5, "query") + ["upload, finalize"]
    end
  end

  # Loop B: the upload keeps failing and the query keeps answering `active` at the same offset. The first
  # query of the episode is immediate; every later lap waits for the next delay.
  def test_repeated_upload_failures_without_progress_back_off_before_each_later_query
    outcomes = [initiation_response]
    3.times { outcomes += [http_error(502), query_response(received: 0)] }
    outcomes << final_response
    stub = FakeClientStub.new outcomes

    result, delays = run_recording_delays stub

    assert_equal '{"done":true}', result
    assert_equal [1.0, 2.0], delays
    assert_commands stub, ["start"] + (["upload, finalize", "query"] * 3) + ["upload, finalize"]
  end

  # Retries inside one query (RetryDecider) and re-queries decided by Rules draw from one sequence.
  def test_in_command_retries_and_re_queries_share_one_backoff_sequence
    outcomes = [initiation_response, Faraday::ConnectionFailed.new("reset"),
                http_error(429), http_error(429), http_error(502),
                query_response(received: 0), final_response]
    stub = FakeClientStub.new outcomes

    result, delays = run_recording_delays stub

    assert_equal '{"done":true}', result
    assert_equal [1.0, 2.0, 4.0], delays
  end

  # A successful upload closes the episode, so the next failure starts a fresh sequence with an immediate
  # first query.
  def test_an_acknowledged_chunk_resets_the_backoff
    outcomes = [
      initiation_response,
      http_error(502), http_error(502), query_response(received: 0), # episode 1: one re-query
      chunk_ack,                                                   # closes episode 1
      http_error(502), http_error(502), query_response(received: 4), # episode 2: one re-query
      final_response
    ]
    stub = FakeClientStub.new outcomes

    result, delays = run_recording_delays stub, stream: "012345", upload_size: 6, chunk_size: 4

    assert_equal '{"done":true}', result
    assert_equal [1.0, 1.0], delays
    assert_commands stub, ["start", "upload", "query", "query", "upload", "upload, finalize", "query", "query",
                           "upload, finalize"]
  end

  # A query reporting bytes beyond the episode's starting offset closes the episode, even though the upload
  # that failed was never acknowledged.
  def test_server_progress_reported_by_a_query_resets_the_backoff
    outcomes = [
      initiation_response,
      http_error(502), query_response(received: 2), # server stored the chunk despite the 502
      http_error(502), query_response(received: 4),
      final_response
    ]
    stub = FakeClientStub.new outcomes

    result, delays = run_recording_delays stub, chunk_size: 2

    assert_equal '{"done":true}', result
    assert_empty delays
    assert_commands stub, ["start", "upload", "query", "upload", "query", "finalize"]
  end

  # A server whose reported offset flips between two values without ever exceeding the higher one makes no
  # progress, so the backoff keeps growing. Closing the episode on any change of offset would reset it every
  # lap and query with no delay.
  def test_an_oscillating_offset_does_not_reset_the_backoff
    outcomes = [
      initiation_response,
      http_error(502), query_response(received: 2), # episode at 0: 2 > 0 closes it
      http_error(502), query_response(received: 0), # episode opens at 2; the drop to 0 keeps it open
      http_error(502), query_response(received: 2), # back to 2: not beyond 2, still open
      http_error(502), query_response(received: 0),
      http_error(502), query_response(received: 4), # 4 > 2 closes it
      final_response
    ]
    stub = FakeClientStub.new outcomes

    result, delays = run_recording_delays stub, chunk_size: 2

    assert_equal '{"done":true}', result
    assert_equal [1.0, 2.0, 4.0], delays
    assert_commands stub, ["start"] + (["upload", "query"] * 5) + ["finalize"]
  end

  # The control plane budget covers the whole episode: once an earlier query has spent it, a connection
  # failure on a later query is no longer retried and ends the run.
  def test_the_control_plane_budget_is_shared_by_every_query_in_the_episode
    outcomes = [initiation_response, Faraday::ConnectionFailed.new("reset"),
                Faraday::ConnectionFailed.new("refused"), http_error(502), # query 1: spends the only retry
                Faraday::ConnectionFailed.new("refused")]                  # query 2: nothing left
    stub = FakeClientStub.new outcomes
    policy = CountedRetryPolicy.new retries: 1, **BACKOFF

    error = assert_raises RequestFailedError do
      run_recording_delays stub, control_plane_retry_policy: policy
    end

    refute_nil error.resume_handle
    assert_commands stub, ["start", "upload, finalize", "query", "query", "query"]
  end

  # A backoff never starts once the whole-upload deadline has passed.
  def test_no_backoff_is_performed_after_the_global_deadline
    outcomes = [initiation_response, http_error(502), query_response(received: 0), http_error(502)]
    stub = FakeClientStub.new outcomes
    recoveries = 0
    spend_deadline = lambda do |progress|
      next unless progress.phase == :recovering
      recoveries += 1
      busy_wait 0.6 if recoveries == 2
    end

    delays = []
    Kernel.stub :sleep, ->(seconds) { delays << seconds.to_f } do
      assert_raises DeadlineExceededError do
        run_upload stub, timeout: 0.5, on_progress: spend_deadline
      end
    end

    assert_empty delays
    assert_commands stub, ["start", "upload, finalize", "query", "upload, finalize"]
  end

  private

  def run_recording_delays stub, control_plane_retry_policy: BACKOFF, **overrides
    delays = []
    result = Kernel.stub :sleep, ->(seconds) { delays << seconds.to_f } do
      run_upload stub, control_plane_retry_policy: control_plane_retry_policy, **overrides
    end
    [result, delays]
  end

  def run_upload stub, stream: "0123", upload_size: 4, chunk_size: 10, **overrides
    config = StartUploadConfig.new(
      initial_url: "https://example.com/upload",
      stream:      StringIO.new(stream),
      upload_size: upload_size,
      chunk_size:  chunk_size,
      **overrides
    )
    Driver.new(client_stub: stub, config: config).run
  end

  def busy_wait seconds
    until_time = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
    nil while Process.clock_gettime(Process::CLOCK_MONOTONIC) < until_time
  end

  def initiation_response
    FakeResponse.new status: 200, headers: { "X-Goog-Upload-URL" => SESSION_URL, "X-Goog-Upload-Status" => "active" },
                     body: ""
  end

  def chunk_ack
    FakeResponse.new status: 200, headers: { "X-Goog-Upload-Status" => "active" }, body: ""
  end

  def query_response received:
    FakeResponse.new status:  200,
                     headers: { "X-Goog-Upload-Status" => "active", "X-Goog-Upload-Size-Received" => received.to_s },
                     body:    ""
  end

  def final_response
    FakeResponse.new status: 200, headers: { "X-Goog-Upload-Status" => "final" }, body: '{"done":true}'
  end

  def http_error status, headers: {}
    klass = status >= 500 ? Faraday::ServerError : Faraday::ClientError
    klass.new "the server responded with status #{status}", { status: status, headers: headers, body: "" }
  end

  def assert_commands stub, expected
    assert_equal expected, stub.requests.map { |req| req[:options][:metadata]["X-Goog-Upload-Command"] }
  end
end
