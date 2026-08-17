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

require "integration_helper"
require "json"
require "stringio"

##
# Golden path integration tests for ResumableUpload Driver against Showcase.
#
class GoldenPathTest < ShowcaseIntegrationTest
  def test_multi_chunk_known_size
    size = 1_500_000
    chunk_size = 524_288
    stream = StringIO.new payload(size)

    config = build_config(
      stream: stream,
      upload_size: size,
      chunk_size: chunk_size
    )

    driver = Gapic::Rest::ResumableUpload::Driver.new(
      client_stub: showcase_client_stub,
      config: config
    )

    result = driver.run
    parsed = JSON.parse result

    assert_equal size, parsed["size"]
    assert_equal [
      Gapic::Rest::ResumableUpload::Progress.new(phase: :initiating, bytes_uploaded: 0, total_bytes: 1_500_000),
      Gapic::Rest::ResumableUpload::Progress.new(phase: :uploading, bytes_uploaded: 0, total_bytes: 1_500_000),
      Gapic::Rest::ResumableUpload::Progress.new(phase: :uploading, bytes_uploaded: 524_288, total_bytes: 1_500_000),
      Gapic::Rest::ResumableUpload::Progress.new(phase: :uploading, bytes_uploaded: 1_048_576, total_bytes: 1_500_000),
      Gapic::Rest::ResumableUpload::Progress.new(phase: :finalizing, bytes_uploaded: 1_048_576, total_bytes: 1_500_000),
      Gapic::Rest::ResumableUpload::Progress.new(phase: :completed, bytes_uploaded: 1_500_000, total_bytes: 1_500_000)
    ], progress_records
  end

  def test_small_upload_default_chunk_size
    size = 100_000
    stream = StringIO.new payload(size)

    config = build_config(
      stream: stream,
      upload_size: size,
      chunk_size: nil # use default chunk size
    )

    driver = Gapic::Rest::ResumableUpload::Driver.new(
      client_stub: showcase_client_stub,
      config: config
    )

    result = driver.run
    parsed = JSON.parse result

    assert_equal size, parsed["size"]
    assert_equal [
      Gapic::Rest::ResumableUpload::Progress.new(phase: :initiating, bytes_uploaded: 0, total_bytes: size),
      Gapic::Rest::ResumableUpload::Progress.new(phase: :uploading, bytes_uploaded: 0, total_bytes: size),
      Gapic::Rest::ResumableUpload::Progress.new(phase: :finalizing, bytes_uploaded: 0, total_bytes: size),
      Gapic::Rest::ResumableUpload::Progress.new(phase: :completed, bytes_uploaded: size, total_bytes: size)
    ], progress_records
  end

  def test_standalone_finalize_unseekable_stream
    chunk_size = 262_144
    size = 3 * chunk_size
    stream = UnseekableStream.new payload(size)

    config = build_config(
      stream: stream,
      chunk_size: chunk_size
    )

    driver = Gapic::Rest::ResumableUpload::Driver.new(
      client_stub: showcase_client_stub,
      config: config
    )

    result = driver.run
    parsed = JSON.parse result

    assert_equal size, parsed["size"]
    assert_equal [
      Gapic::Rest::ResumableUpload::Progress.new(phase: :initiating, bytes_uploaded: 0, total_bytes: nil),
      Gapic::Rest::ResumableUpload::Progress.new(phase: :uploading, bytes_uploaded: 0, total_bytes: nil),
      Gapic::Rest::ResumableUpload::Progress.new(phase: :uploading, bytes_uploaded: 262_144, total_bytes: nil),
      Gapic::Rest::ResumableUpload::Progress.new(phase: :uploading, bytes_uploaded: 524_288, total_bytes: nil),
      Gapic::Rest::ResumableUpload::Progress.new(phase: :uploading, bytes_uploaded: 786_432, total_bytes: nil),
      Gapic::Rest::ResumableUpload::Progress.new(phase: :finalizing, bytes_uploaded: 786_432, total_bytes: nil),
      Gapic::Rest::ResumableUpload::Progress.new(phase: :completed, bytes_uploaded: 786_432, total_bytes: 786_432)
    ], progress_records
  end
end
