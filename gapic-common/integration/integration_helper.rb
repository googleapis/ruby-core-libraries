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

require "json"
require "logger"
require "securerandom"
require "stringio"
require "minitest/autorun"
require "minitest/focus"
require "minitest/mock"

require "gapic/common"
require "gapic/rest"
require "gapic/rest/resumable_upload"

##
# Base class for Showcase integration tests.
#
class ShowcaseIntegrationTest < Minitest::Test
  UPLOAD_PATH = "/resumable/upload/v1beta1/files:upload"
  FAST_RETRY = { initial_delay: 0.01, max_delay: 0.05, multiplier: 1, timeout: 2 }.freeze
  DEFAULT_CHUNK_SIZE = 262_144
  DEFAULT_PAYLOAD_SIZE = DEFAULT_CHUNK_SIZE * 3

  ##
  # Stream double that intentionally does not implement #seek.
  #
  class UnseekableStream
    def initialize data
      @io = StringIO.new data
    end

    def read length = nil
      @io.read length
    end

    def pos
      @io.pos
    end
  end

  attr_reader :logger
  attr_reader :progress_records

  def phases
    @progress_records.map(&:phase)
  end

  def offsets
    @progress_records.map(&:bytes_uploaded)
  end

  def showcase_endpoint
    ENV["SHOWCASE_ENDPOINT"]
  end

  def setup
    skip "SHOWCASE_ENDPOINT is not set" if showcase_endpoint.to_s.empty?
    @log_output = StringIO.new
    @logger = Logger.new @log_output, level: Logger::DEBUG
    super
  end

  def teardown
    if (!passed? || !ENV["SHOWCASE_LOG"].to_s.empty?) && @log_output && !@log_output.string.empty?
      warn "\n--- Captured trace for #{name} ---\n#{@log_output.string}--- End trace ---\n"
    end
    super
  end

  def payload size
    pattern = "0123456789".b
    (pattern * ((size / pattern.bytesize) + 1)).byteslice 0, size
  end

  def showcase_client_stub
    Gapic::Rest::ClientStub.new(
      endpoint:             showcase_endpoint,
      credentials:          :dummy_credentials,
      raise_faraday_errors: false,
      logger:               @logger
    )
  end

  def build_config scenario: nil, scenario_config: {}, **overrides
    @progress_records = []
    headers = (overrides[:initial_headers] || {}).dup
    if scenario
      headers["X-Goog-Test-Scenario"] = scenario
      headers["X-Goog-Test-Scenario-Config"] = JSON.generate(
        { "client_uuid" => SecureRandom.uuid }.merge(scenario_config)
      )
    end

    defaults = {
      initial_url:                UPLOAD_PATH,
      initial_headers:            headers,
      start_retry_policy:         FAST_RETRY,
      control_plane_retry_policy: FAST_RETRY,
      data_plane_retry_policy:    FAST_RETRY,
      timeout:                    10,
      chunk_size:                 DEFAULT_CHUNK_SIZE,
      on_progress:                ->(progress) { @progress_records << progress }
    }
    unless overrides.key? :stream
      defaults[:stream] = StringIO.new payload(DEFAULT_PAYLOAD_SIZE)
      defaults[:upload_size] = DEFAULT_PAYLOAD_SIZE
    end

    Gapic::Rest::ResumableUpload::StartUploadConfig.new(**defaults, **overrides, initial_headers: headers)
  end

  START_ONLY_KEYS = [:initial_url, :initial_body, :initial_headers, :chunk_size, :start_retry_policy].freeze

  # Builds a session from the shared arguments and remembers the per-run arguments that #start needs,
  # so callers can run it with `start_session session`.
  def build_session scenario: nil, scenario_config: {}, **overrides
    @progress_records = []
    headers = (overrides.delete(:initial_headers) || {}).dup
    if scenario
      headers["X-Goog-Test-Scenario"] = scenario
      headers["X-Goog-Test-Scenario-Config"] = JSON.generate(
        { "client_uuid" => SecureRandom.uuid }.merge(scenario_config)
      )
    end

    @start_args = {
      initial_url:        UPLOAD_PATH,
      initial_headers:    headers,
      start_retry_policy: FAST_RETRY,
      chunk_size:         DEFAULT_CHUNK_SIZE
    }.merge(overrides.slice(*START_ONLY_KEYS))

    defaults = {
      client_stub:                showcase_client_stub,
      control_plane_retry_policy: FAST_RETRY,
      data_plane_retry_policy:    FAST_RETRY,
      timeout:                    10,
      on_progress:                ->(progress) { @progress_records << progress },
      logger:                     @logger
    }
    unless overrides.key? :stream
      defaults[:stream] = StringIO.new payload(DEFAULT_PAYLOAD_SIZE)
      defaults[:upload_size] = DEFAULT_PAYLOAD_SIZE
    end

    Gapic::Rest::ResumableUpload::Session.new(**defaults, **overrides.except(*START_ONLY_KEYS))
  end

  def start_session session, **overrides
    session.start(**@start_args, **overrides)
  end

  def raw_start scenario: nil, scenario_config: {}, upload_size: nil, headers: {}
    req_headers = {
      "X-Goog-Upload-Protocol" => "resumable",
      "X-Goog-Upload-Command"  => "start"
    }
    req_headers["X-Goog-Upload-Header-Content-Length"] = upload_size.to_s if upload_size
    if scenario
      req_headers["X-Goog-Test-Scenario"] = scenario
      req_headers["X-Goog-Test-Scenario-Config"] = JSON.generate(
        { "client_uuid" => SecureRandom.uuid }.merge(scenario_config)
      )
    end
    req_headers.merge! headers

    response = showcase_client_stub.make_post_request(
      uri:     UPLOAD_PATH,
      body:    nil,
      options: { metadata: req_headers }
    )
    Gapic::Rest::ResumableUpload::Rules.header_value response.headers, "x-goog-upload-url"
  end

  def raw_upload upload_url:, offset:, bytes:, finalize: false, headers: {}
    req_headers = {
      "X-Goog-Upload-Command" => finalize ? "upload, finalize" : "upload",
      "X-Goog-Upload-Offset"  => offset.to_s,
      "Content-Type"          => "application/octet-stream",
      "Content-Length"        => bytes.bytesize.to_s
    }
    req_headers.merge! headers

    showcase_client_stub.make_post_request(
      uri:     upload_url,
      body:    bytes,
      options: { metadata: req_headers }
    )
  end
end
