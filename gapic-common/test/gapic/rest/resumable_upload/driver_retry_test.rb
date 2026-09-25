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
require "faraday"

##
# Tests for the ResumableUpload Driver retry loop: which outcomes are re-sent on each plane, and what
# surfaces to Rules when they are not.
#
# Non-2xx outcomes are raised as Faraday errors carrying a response env, as Faraday's `raise_error`
# middleware does in production.
#
# rubocop:disable Metrics/ClassLength
# rubocop:disable Metrics/MethodLength
class DriverRetryTest < Minitest::Test
  include Gapic::Rest::ResumableUpload

  FakeResponse = Struct.new :status, :headers, :body, keyword_init: true

  SESSION_URL = "https://example.com/session/1"

  FAST = { initial_delay: 0.001, max_delay: 0.002, timeout: 1.0 }.freeze

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

  # ============================================================================
  # Initiation
  # ============================================================================

  def test_start_retries_a_200_without_status_header
    stub = FakeClientStub.new [headerless_200, initiation_response, final_response]

    assert_equal '{"done":true}', run_upload(stub, start_retry_policy: FAST)
    assert_commands stub, ["start", "start", "upload, finalize"]
  end

  # An exhausted headerless start 200 surfaces as the response itself, which Rules turns into a bad
  # response.
  def test_start_surfaces_an_exhausted_headerless_200_as_a_bad_response
    stub = FakeClientStub.new Array.new(200) { headerless_200 }

    err = assert_raises BadResponseError do
      run_upload stub, start_retry_policy: FAST.merge(timeout: 0.01)
    end

    assert_equal 200, err.status_code
    assert_match(/X-Goog-Upload-Status: missing/, err.message)
    assert stub.requests.size > 1
  end

  # The missing-header retry is the protocol's, so it must not depend on anything the policy carries.
  def test_start_retries_a_headerless_200_under_a_bare_policy
    stub = FakeClientStub.new Array.new(200) { headerless_200 }
    policy = Gapic::Common::RetryPolicy.new initial_delay: 0.001, max_delay: 0.002, timeout: 0.05
    assert_empty policy.retry_codes
    assert_nil policy.retry_predicate

    assert_raises BadResponseError do
      run_upload stub, start_retry_policy: policy
    end

    assert stub.requests.size > 1, "Expected the missing-header retry to survive a bare policy"
  end

  def test_start_retries_the_default_retriable_statuses
    [409, 429, 499, 500, 503, 504].each do |status|
      stub = FakeClientStub.new [http_error(status), initiation_response, final_response]

      assert_equal '{"done":true}', run_upload(stub, start_retry_policy: FAST), "status #{status}"
      assert_commands stub, ["start", "start", "upload, finalize"]
    end
  end

  def test_start_does_not_retry_other_statuses_by_default
    [400, 403, 404, 408, 502].each do |status|
      stub = FakeClientStub.new [http_error(status)]

      err = assert_raises BadResponseError do
        run_upload stub, start_retry_policy: FAST
      end

      assert_equal status, err.status_code
      assert_equal 1, stub.requests.size, "status #{status}"
    end
  end

  def test_start_retries_connection_and_tls_failures
    [Faraday::ConnectionFailed.new("refused"), Faraday::SSLError.new("handshake")].each do |error|
      stub = FakeClientStub.new [error, initiation_response, final_response]

      assert_equal '{"done":true}', run_upload(stub, start_retry_policy: FAST), error.class.name
      assert_commands stub, ["start", "start", "upload, finalize"]
    end
  end

  # A caller predicate cannot switch off the protocol's own connection retry: it is not consulted.
  def test_start_retries_a_connection_failure_without_asking_the_predicate
    seen = []
    predicate = lambda { |err|
      seen << err
      false
    }
    stub = FakeClientStub.new [Faraday::ConnectionFailed.new("refused"), initiation_response, final_response]

    run_upload stub, start_retry_policy: FAST.merge(retry_predicate: predicate)

    assert_equal 3, stub.requests.size
    assert_empty seen
  end

  def test_start_surfaces_an_exhausted_connection_failure_as_request_failed
    stub = FakeClientStub.new Array.new(200) { Faraday::ConnectionFailed.new "refused" }

    err = assert_raises RequestFailedError do
      run_upload stub, start_retry_policy: FAST.merge(timeout: 0.01)
    end

    assert_instance_of Faraday::ConnectionFailed, err.cause
    assert stub.requests.size > 1
  end

  def test_final_non_200_is_never_retried_even_when_the_predicate_says_yes
    stub = FakeClientStub.new [http_error(503, headers: { "X-Goog-Upload-Status" => "final" })]

    assert_raises UploadRejectedError do
      run_upload stub, start_retry_policy: FAST.merge(retry_predicate: ->(_err) { true })
    end

    assert_equal 1, stub.requests.size
  end

  def test_non_transport_error_is_not_retried_by_default
    stub = FakeClientStub.new [RuntimeError.new("token refresh failed")]

    err = assert_raises RequestFailedError do
      run_upload stub, start_retry_policy: FAST
    end

    assert_match(/token refresh failed/, err.message)
    assert_equal 1, stub.requests.size
  end

  def test_non_transport_error_is_retried_when_the_predicate_says_so
    predicate = ->(err) { err.is_a?(RuntimeError) || nil }
    stub = FakeClientStub.new [RuntimeError.new("token refresh failed"), initiation_response, final_response]

    assert_equal '{"done":true}', run_upload(stub, start_retry_policy: FAST.merge(retry_predicate: predicate))
    assert_commands stub, ["start", "start", "upload, finalize"]
  end

  # Under `raise_faraday_errors: false`, ClientStub raises a Gapic::Rest::Error from inside its own rescue.
  # Its status is readable by retry_codes only through `cause`.
  def test_start_retries_a_gapic_rest_error_through_its_faraday_cause
    wrapped = lambda do
      raise http_error(503)
    rescue Faraday::Error => e
      raise Gapic::Rest::Error.wrap_faraday_error(e)
    end
    stub = FakeClientStub.new [wrapped, initiation_response, final_response]

    assert_equal '{"done":true}', run_upload(stub, start_retry_policy: FAST)
    assert_equal 3, stub.requests.size
  end

  def test_client_stub_is_handed_a_never_retry_policy
    stub = FakeClientStub.new [initiation_response, final_response]
    run_upload stub

    stub.requests.each do |req|
      policy = req[:options][:retry_policy]
      refute policy.call(http_error(503)), "ClientStub must never retry on its own"
      refute policy.call(Faraday::ConnectionFailed.new("refused"))
    end
  end

  def test_the_predicate_never_sees_driver_internals
    seen = []
    predicate = lambda { |arg|
      seen << arg
      nil
    }
    outcomes = [headerless_200, http_error(503), RuntimeError.new("auth"), initiation_response, final_response]
    stub = FakeClientStub.new outcomes

    assert_raises RequestFailedError do
      run_upload stub, start_retry_policy: FAST.merge(retry_predicate: predicate)
    end

    refute_empty seen
    refute seen.any? { |arg| arg.is_a?(Event::HttpResponse) || arg.is_a?(BadResponseError) },
           "Predicate was handed driver internals: #{seen.map(&:class).uniq.inspect}"
  end

  # ============================================================================
  # Control plane
  # ============================================================================

  def test_query_retries_a_200_without_status_header
    outcomes = [
      initiation_response,
      Faraday::ConnectionFailed.new("reset"),
      headerless_200,
      query_response(received: 0),
      final_response
    ]
    stub = FakeClientStub.new outcomes

    assert_equal '{"done":true}', run_upload(stub, control_plane_retry_policy: FAST)
    assert_commands stub, ["start", "upload, finalize", "query", "query", "upload, finalize"]
  end

  def test_query_retries_connection_and_tls_failures
    [Faraday::ConnectionFailed.new("refused"), Faraday::SSLError.new("handshake")].each do |error|
      outcomes = [initiation_response, Faraday::ConnectionFailed.new("reset"), error, query_response(received: 0),
                  final_response]
      stub = FakeClientStub.new outcomes

      assert_equal '{"done":true}', run_upload(stub, control_plane_retry_policy: FAST), error.class.name
      assert_commands stub, ["start", "upload, finalize", "query", "query", "upload, finalize"]
    end
  end

  def test_query_retries_a_retriable_4xx
    outcomes = [initiation_response, Faraday::ConnectionFailed.new("reset"), http_error(429),
                query_response(received: 0), final_response]
    stub = FakeClientStub.new outcomes

    assert_equal '{"done":true}', run_upload(stub, control_plane_retry_policy: FAST)
    assert_commands stub, ["start", "upload, finalize", "query", "query", "upload, finalize"]
  end

  # ============================================================================
  # Data plane
  # ============================================================================

  # Recovery owns every outcome that leaves the server offset unknown: the chunk is not re-sent blindly.
  def test_upload_surfaces_connection_and_tls_failures_to_recovery
    [Faraday::ConnectionFailed.new("reset"), Faraday::SSLError.new("bad record mac")].each do |error|
      stub = FakeClientStub.new [initiation_response, error, query_response(received: 0), final_response]

      assert_equal '{"done":true}', run_upload(stub, data_plane_retry_policy: FAST), error.class.name
      assert_commands stub, ["start", "upload, finalize", "query", "upload, finalize"]
    end
  end

  def test_upload_surfaces_a_headerless_200_to_recovery
    stub = FakeClientStub.new [initiation_response, headerless_200, query_response(received: 0), final_response]

    assert_equal '{"done":true}', run_upload(stub, data_plane_retry_policy: FAST)
    assert_commands stub, ["start", "upload, finalize", "query", "upload, finalize"]
  end

  def test_upload_never_retries_a_4xx_even_when_the_predicate_says_yes
    [409, 429].each do |status|
      stub = FakeClientStub.new [initiation_response, http_error(status), query_response(received: 0),
                                 final_response]

      result = run_upload stub, data_plane_retry_policy: FAST.merge(retry_predicate: ->(_err) { true })

      assert_equal '{"done":true}', result, "status #{status}"
      assert_commands stub, ["start", "upload, finalize", "query", "upload, finalize"]
    end
  end

  def test_upload_retries_a_retriable_5xx
    stub = FakeClientStub.new [initiation_response, http_error(503), final_response]

    assert_equal '{"done":true}', run_upload(stub, data_plane_retry_policy: FAST)
    assert_commands stub, ["start", "upload, finalize", "upload, finalize"]
  end

  def test_upload_surfaces_a_timeout_to_recovery
    stub = FakeClientStub.new [initiation_response, Faraday::TimeoutError.new("read timeout"),
                               query_response(received: 0), final_response]

    assert_equal '{"done":true}', run_upload(stub, data_plane_retry_policy: FAST)
    assert_commands stub, ["start", "upload, finalize", "query", "upload, finalize"]
  end

  # ============================================================================
  # Budgets
  # ============================================================================

  def test_each_attempt_timeout_fits_within_the_shrinking_command_budget
    stub = FakeClientStub.new [headerless_200, headerless_200, initiation_response, final_response]

    run_upload stub, start_retry_policy: { initial_delay: 0.02, max_delay: 0.02, timeout: 0.5 }

    timeouts = stub.requests.first(3).map { |req| req[:options][:timeout] }
    assert(timeouts.all? { |t| t <= 0.5 }, "Expected every attempt timeout within the budget: #{timeouts}")
    assert timeouts[1] < timeouts[0], "Expected the attempt timeout to shrink: #{timeouts}"
    assert timeouts[2] < timeouts[1], "Expected the attempt timeout to shrink: #{timeouts}"
  end

  def test_the_global_deadline_ends_a_retry_loop
    stub = FakeClientStub.new Array.new(200) { headerless_200 }

    assert_raises DeadlineExceededError do
      run_upload stub, timeout: 0.05, start_retry_policy: { initial_delay: 0.01, max_delay: 0.01, timeout: 60 }
    end

    assert stub.requests.size > 1
    assert stub.requests.size < 200
  end

  private

  def run_upload stub, **config_overrides
    config = StartUploadConfig.new(
      initial_url: "https://example.com/upload",
      stream:      StringIO.new("0123"),
      upload_size: 4,
      chunk_size:  10,
      **config_overrides
    )
    Driver.new(client_stub: stub, config: config).run
  end

  def headerless_200
    FakeResponse.new status: 200, headers: {}, body: ""
  end

  def initiation_response
    FakeResponse.new status: 200, headers: { "X-Goog-Upload-URL" => SESSION_URL, "X-Goog-Upload-Status" => "active" },
                     body: ""
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
# rubocop:enable Metrics/MethodLength
# rubocop:enable Metrics/ClassLength
