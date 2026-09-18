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
# Golden path integration tests against Showcase, driven through ::Gapic::ResumableUpload.
#
class GoldenPathTest < ShowcaseIntegrationTest
  def test_multi_chunk_known_size
    size = 1_500_000
    chunk_size = 524_288

    upload = build_upload
    result = upload.start(**start_args(stream:      StringIO.new(payload(size)),
                                       upload_size: size,
                                       chunk_size:  chunk_size))
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

    upload = build_upload
    result = upload.start(**start_args(stream:      StringIO.new(payload(size)),
                                       upload_size: size,
                                       chunk_size:  nil)) # use default chunk size
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

    upload = build_upload
    result = upload.start(**start_args(stream:     UnseekableStream.new(payload(size)),
                                       chunk_size: chunk_size))
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

  ##
  # The decode path a generated client actually takes: a real message class, against a live response that
  # carries a field the message does not declare. That field only survives because the coordinator decodes
  # with `ignore_unknown_fields: true` — without it, `decode_json` would raise.
  #
  def test_decodes_the_final_body_into_the_response_type
    size = 100_000

    upload = build_upload response_type: Gapic::Examples::User
    response = upload.start(**start_args(stream: StringIO.new(payload(size)), upload_size: size))

    assert_instance_of Gapic::Examples::User, response
    refute_empty response.name
  end
end
