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
# Tests for Driver progress notification dispatching and callback error propagation.
#
class DriverProgressTest < Minitest::Test
  include Gapic::Rest::ResumableUpload

  CustomCallbackError = Class.new StandardError
  FakeResponse = Struct.new :status, :headers, :body, keyword_init: true

  class ScriptedClientStub
    def initialize responses
      @responses = responses
    end

    def make_post_request uri:, body: nil, params: {}, options: {}, method_name: nil
      raise "No scripted response" if @responses.empty?

      @responses.shift
    end
  end

  def test_execute_notify_progress_without_callback_does_not_raise
    driver = build_driver on_progress: nil

    instruction = Instruction::NotifyProgress.new progress: Progress.new(phase: :uploading, bytes_uploaded: 1024, total_bytes: 4096)
    # Must not raise when callback is nil
    driver.send :execute_notify_progress, instruction
  end

  def test_execute_notify_progress_happy_path_invoked_once
    calls = []
    callback = ->(progress) { calls << progress }
    driver = build_driver on_progress: callback

    instruction = Instruction::NotifyProgress.new progress: Progress.new(phase: :uploading, bytes_uploaded: 500, total_bytes: 1000)
    driver.send :execute_notify_progress, instruction

    assert_equal 1, calls.size
    assert_equal Progress.new(phase: :uploading, bytes_uploaded: 500, total_bytes: 1000), calls.first
  end

  def test_execute_notify_progress_total_bytes_nil_passes_through
    calls = []
    callback = ->(progress) { calls << progress }
    driver = build_driver on_progress: callback

    instruction = Instruction::NotifyProgress.new progress: Progress.new(phase: :uploading, bytes_uploaded: 250, total_bytes: nil)
    driver.send :execute_notify_progress, instruction

    assert_equal 1, calls.size
    assert_equal Progress.new(phase: :uploading, bytes_uploaded: 250, total_bytes: nil), calls.first
  end

  def test_execute_notify_progress_raises_error_to_caller_when_callback_fails
    callback = ->(_progress) { raise CustomCallbackError, "User UI crashed in progress callback" }
    driver = build_driver on_progress: callback

    instruction = Instruction::NotifyProgress.new progress: Progress.new(phase: :uploading, bytes_uploaded: 100, total_bytes: 1000)
    err = assert_raises CustomCallbackError do
      driver.send :execute_notify_progress, instruction
    end

    assert_equal "User UI crashed in progress callback", err.message
  end

  def test_driver_run_propagates_callback_error_end_to_end
    # Script responses: 1. start response -> 2. chunk response (triggers NotifyProgress)
    responses = [
      FakeResponse.new(
        status:  200,
        headers: { "x-goog-upload-url" => "https://example.com/upload/123", "x-goog-upload-status" => "active" },
        body:    ""
      ),
      FakeResponse.new(
        status:  200,
        headers: { "x-goog-upload-status" => "active" },
        body:    ""
      )
    ]
    stub = ScriptedClientStub.new responses

    callback = ->(_progress) { raise CustomCallbackError, "Terminal failure in user progress handler" }
    config = StartUploadConfig.new(
      initial_url: "https://example.com/upload",
      stream:      StringIO.new("0123456789"),
      upload_size: 10,
      chunk_size:  4,
      on_progress: callback
    )
    driver = Driver.new client_stub: stub, config: config

    err = assert_raises CustomCallbackError do
      driver.run
    end
    assert_equal "Terminal failure in user progress handler", err.message
  end

  def test_completed_progress_reports_total_bytes_when_upload_size_unknown
    responses = [
      FakeResponse.new(
        status:  200,
        headers: { "x-goog-upload-url" => "https://example.com/upload/123", "x-goog-upload-status" => "active" },
        body:    ""
      ),
      FakeResponse.new(
        status:  200,
        headers: { "x-goog-upload-status" => "active" },
        body:    ""
      ),
      FakeResponse.new(
        status:  200,
        headers: { "x-goog-upload-status" => "active" },
        body:    ""
      ),
      FakeResponse.new(
        status:  200,
        headers: { "x-goog-upload-status" => "final" },
        body:    "{\"done\":true}"
      )
    ]
    stub = ScriptedClientStub.new responses

    progress_events = []
    config = StartUploadConfig.new(
      initial_url: "https://example.com/upload",
      stream:      StringIO.new("0123456789"),
      upload_size: nil,
      chunk_size:  4,
      on_progress: ->(progress) { progress_events << progress }
    )
    driver = Driver.new client_stub: stub, config: config

    result = driver.run
    assert_equal "{\"done\":true}", result

    uploading_snapshots = progress_events.select { |p| p.phase == :uploading }
    refute_empty uploading_snapshots
    assert uploading_snapshots.all? { |p| p.total_bytes.nil? }

    completed_snapshot = progress_events.last
    assert_equal :completed, completed_snapshot.phase
    assert_equal 10, completed_snapshot.bytes_uploaded
    assert_equal 10, completed_snapshot.total_bytes
  end

  private

  def build_driver on_progress: nil
    config = StartUploadConfig.new(
      initial_url: "https://example.com/upload",
      stream:      StringIO.new("0123456789"),
      upload_size: 10,
      chunk_size:  4,
      on_progress: on_progress
    )
    Driver.new client_stub: Object.new, config: config
  end
end
