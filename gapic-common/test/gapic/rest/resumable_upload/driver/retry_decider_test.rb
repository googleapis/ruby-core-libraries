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
require "delegate"
require "faraday"

##
# Table tests for Driver::RetryDecider: every row of the decision table, on both planes.
#
class DriverRetryDeciderTest < Minitest::Test
  include Gapic::Rest::ResumableUpload

  RetryDecider = Driver::RetryDecider

  FakeResponse = Struct.new :status, :headers, :body, keyword_init: true

  # ============================================================================
  # SUT: failure_kind
  # ============================================================================

  def test_failure_kind
    {
      Gapic::Rest::DeadlineExceededError.new("deadline", 504) => :timeout,
      Gapic::Rest::Error.new("unavailable", 503)              => :status,
      Gapic::Rest::Error.new("network", nil)                  => :connection_failed,
      http_error(503)                                         => :status,
      Faraday::TimeoutError.new("read timeout")               => :timeout,
      Faraday::ConnectionFailed.new("refused")                => :connection_failed,
      Faraday::SSLError.new("handshake")                      => :connection_failed,
      Faraday::Error.new("no response")                       => :no_response,
      RuntimeError.new("token refresh failed")                => :non_transport
    }.each do |error, kind|
      assert_equal kind, RetryDecider.failure_kind(error), error.inspect
    end
  end

  # ============================================================================
  # SUT: retry? — rows of the decision table, start/control vs data
  # ============================================================================

  # Row 1: non-transport error — ask policy on both planes.
  def test_row_1_non_transport_error_asks_the_policy
    error = RuntimeError.new "token refresh failed"
    [false, true].each do |data_plane|
      refute decide(error, data_plane: data_plane), "default codes cannot match, data_plane: #{data_plane}"
      assert decide(error, data_plane: data_plane, retry_predicate: ->(_e) { true }), "data_plane: #{data_plane}"
    end
  end

  # Row 2: timeout — ask policy on start/control, surface on data.
  def test_row_2_timeout
    error = Faraday::TimeoutError.new "read timeout"
    refute decide(error)
    assert decide(error, retry_predicate: ->(_e) { true })
    refute decide(error, data_plane: true, retry_predicate: ->(_e) { true })
  end

  def test_row_2_a_transport_error_without_a_response_is_treated_as_a_timeout
    error = Faraday::Error.new "no response"
    assert decide(error, retry_predicate: ->(_e) { true })
    refute decide(error, data_plane: true, retry_predicate: ->(_e) { true })
  end

  # Row 3: connection and TLS failures — retry within budget on start/control, surface on data.
  def test_row_3_connection_and_tls_failures
    [Faraday::ConnectionFailed.new("refused"), Faraday::SSLError.new("handshake")].each do |error|
      assert decide(error, retry_predicate: ->(_e) { false }), "predicate is not consulted: #{error.class}"
      refute decide(error, data_plane: true, retry_predicate: ->(_e) { true }), error.class.name
      refute decide(error, timeout: 0), "budget exhausted: #{error.class}"
    end
  end

  # Row 4: headerless 200 — retry within budget on start/control, surface on data.
  def test_row_4_headerless_200
    [{}, { "X-Goog-Upload-Status" => "" }].each do |headers|
      response = FakeResponse.new status: 200, headers: headers, body: ""
      assert decide(response, retry_predicate: ->(_e) { false }), headers.inspect
      refute decide(response, data_plane: true, retry_predicate: ->(_e) { true }), headers.inspect
      refute decide(response, timeout: 0), "budget exhausted: #{headers.inspect}"
    end
  end

  def test_a_200_with_the_header_and_other_responses_surface
    [
      FakeResponse.new(status: 200, headers: { "X-Goog-Upload-Status" => "active" }, body: ""),
      FakeResponse.new(status: 200, headers: { "X-Goog-Upload-Status" => "final" }, body: ""),
      FakeResponse.new(status: 204, headers: {}, body: ""),
      FakeResponse.new(status: 308, headers: {}, body: "")
    ].each do |response|
      [false, true].each do |data_plane|
        refute decide(response, data_plane: data_plane, retry_predicate: ->(_e) { true }), response.inspect
      end
    end
  end

  # Row 5: non-200 with `final` — never retried on either plane, whatever the policy says.
  def test_row_5_final_rejection_is_never_retried
    [400, 409, 503].each do |status|
      error = http_error status, headers: { "X-Goog-Upload-Status" => "Final" }
      [false, true].each do |data_plane|
        refute decide(error, data_plane: data_plane, retry_predicate: ->(_e) { true }),
               "status #{status}, data_plane: #{data_plane}"
      end
    end
  end

  # Row 6: any 4xx on the data plane surfaces, whatever the policy says.
  def test_row_6_data_plane_never_retries_a_4xx
    [400, 408, 409, 429, 499].each do |status|
      refute decide(http_error(status), data_plane: true, retry_predicate: ->(_e) { true }), "status #{status}"
    end
  end

  # Row 7: a status in the default codes — ask policy, retried by default.
  def test_row_7_default_codes_are_retried
    [409, 429, 499, 500, 503, 504].each do |status|
      assert decide(http_error(status)), "start/control status #{status}"
    end
    [500, 503, 504].each do |status|
      assert decide(http_error(status), data_plane: true), "data status #{status}"
    end
  end

  def test_row_7_the_predicate_can_decline_a_default_code
    refute decide(http_error(503), retry_predicate: ->(_e) { false })
    refute decide(http_error(503), data_plane: true, retry_predicate: ->(_e) { false })
  end

  # Row 8: any other status — ask policy, not retried by default.
  def test_row_8_other_statuses_are_not_retried_by_default
    [400, 403, 404, 408, 412, 502].each do |status|
      refute decide(http_error(status)), "start/control status #{status}"
    end
    [501, 502, 505].each do |status|
      refute decide(http_error(status), data_plane: true), "data status #{status}"
      assert decide(http_error(status), data_plane: true, retry_predicate: ->(_e) { true }), "data status #{status}"
    end
  end

  def test_asking_the_policy_respects_its_deadline
    refute decide(http_error(503), timeout: 0)
    refute decide(RuntimeError.new("auth"), timeout: 0, retry_predicate: ->(_e) { true })
  end

  # Under `raise_faraday_errors: false`, the Faraday error is the `cause` of a Gapic::Rest::Error, and
  # retry_codes can read the status only from the Faraday error.
  def test_a_gapic_rest_error_is_judged_by_its_faraday_cause
    assert decide(wrapped(http_error(503)))
    refute decide(wrapped(http_error(503, headers: { "X-Goog-Upload-Status" => "final" })))
    refute decide(wrapped(http_error(429)), data_plane: true, retry_predicate: ->(_e) { true })
  end

  def test_a_gapic_rest_error_without_a_cause_is_judged_by_its_own_status
    error = Gapic::Rest::Error.new "unavailable", 503, headers: { "X-Goog-Upload-Status" => "final" }
    refute decide(error, retry_predicate: ->(_e) { true })

    error = Gapic::Rest::Error.new "conflict", 409, headers: {}
    refute decide(error, data_plane: true, retry_predicate: ->(_e) { true })
  end

  def test_a_retry_performs_the_backoff_delay
    policy = policy_for({}, data_plane: false)
    decider = RetryDecider.new policy, data_plane: false

    assert decider.retry?(http_error(503))
    assert_equal 1, policy.perform_delay_count
  end

  # Rows fixed ahead of the policy must not consult it at all: neither its predicate nor its backoff.
  def test_surfaced_outcomes_never_consult_the_policy
    final = { "X-Goog-Upload-Status" => "final" }
    active_200 = FakeResponse.new status: 200, headers: { "X-Goog-Upload-Status" => "active" }, body: ""
    headerless_200 = FakeResponse.new status: 200, headers: {}, body: ""
    {
      true  => [Faraday::ConnectionFailed.new("reset"), Faraday::SSLError.new("mac"),
                Faraday::TimeoutError.new("read"), Faraday::Error.new("none"), headerless_200, active_200,
                http_error(429), http_error(503, headers: final)],
      false => [active_200, http_error(503, headers: final)]
    }.each do |data_plane, outcomes|
      outcomes.each do |outcome|
        spy = SpyPolicy.new policy_for({ timeout: 60, retry_predicate: ->(_e) { true } }, data_plane: data_plane)
        refute RetryDecider.new(spy, data_plane: data_plane).retry?(outcome), outcome.inspect
        assert_equal 0, spy.calls, "policy consulted for #{outcome.inspect}, data_plane: #{data_plane}"
      end
    end
  end

  # Counts RetryPolicy#call invocations.
  class SpyPolicy < SimpleDelegator
    attr_reader :calls

    def initialize policy
      super
      @calls = 0
    end

    def call *args
      @calls += 1
      __getobj__.call(*args)
    end
  end

  private

  def decide outcome, data_plane: false, timeout: 60, retry_predicate: nil
    overrides = { timeout: timeout }
    overrides[:retry_predicate] = retry_predicate if retry_predicate
    RetryDecider.new(policy_for(overrides, data_plane: data_plane), data_plane: data_plane).retry?(outcome)
  end

  def policy_for overrides, data_plane:
    defaults = data_plane ? RetryPolicies::DATA_PLANE_DEFAULTS : RetryPolicies::START_DEFAULTS
    Gapic::Common::RetryPolicy.new(**overrides).apply_defaults(defaults).start!(mock_delay: true)
  end

  def http_error status, headers: {}
    klass = status >= 500 ? Faraday::ServerError : Faraday::ClientError
    klass.new "the server responded with status #{status}", { status: status, headers: headers, body: "" }
  end

  def wrapped faraday_error
    raise faraday_error
  rescue Faraday::Error => e
    begin
      raise Gapic::Rest::Error.wrap_faraday_error(e)
    rescue Gapic::Rest::Error => wrapped_error
      wrapped_error
    end
  end
end
