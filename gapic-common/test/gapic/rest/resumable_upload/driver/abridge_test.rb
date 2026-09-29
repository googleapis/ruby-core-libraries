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

##
# Unit tests for Gapic::Rest::ResumableUpload::Driver::Abridge.
#
class AbridgeTest < Minitest::Test
  include Gapic::Rest::ResumableUpload

  def test_bytes_hex_encodes_short_payloads
    assert_nil Driver::Abridge.bytes(nil)

    short = "hello"
    assert_equal short.unpack1("H*"), Driver::Abridge.bytes(short)

    boundary = "A" * 63
    assert_equal boundary.unpack1("H*"), Driver::Abridge.bytes(boundary)
  end

  def test_bytes_abridges_and_hex_encodes_large_payloads
    large = "A" * 100
    expected_prefix = ("A" * 32).unpack1 "H*"
    assert_equal "#{expected_prefix}... <100 bytes>", Driver::Abridge.bytes(large)
  end

  def test_error_body_truncates_at_512_bytes_and_scrubs_invalid_utf8
    assert_nil Driver::Abridge.error_body(nil)

    long_err = "E" * 600
    assert_equal 512, Driver::Abridge.error_body(long_err).bytesize

    invalid_utf8 = "error \xFF\xFE message".b
    scrubbed = Driver::Abridge.error_body invalid_utf8
    assert scrubbed.valid_encoding?
    assert_includes scrubbed, "error "
    assert_includes scrubbed, " message"
  end

  def test_url_elides_query_parameter_values
    assert_nil Driver::Abridge.url(nil)

    url = "https://storage.googleapis.com/upload/storage/v1/b/bucket/o?uploadType=resumable&sid=SECRET123"
    assert_equal "https://storage.googleapis.com/upload/storage/v1/b/bucket/o?uploadType=<...>&sid=<...>",
                 Driver::Abridge.url(url)
  end

  def test_headers_retains_x_goog_upload_and_redacts_others
    headers = {
      "X-Goog-Upload-Command" => "upload, finalize",
      "X-Goog-Upload-Offset"  => "0",
      "Authorization"         => "Bearer SECRET123",
      "Content-Type"          => "application/octet-stream"
    }

    abridged = Driver::Abridge.headers headers
    assert_equal "upload, finalize", abridged["X-Goog-Upload-Command"]
    assert_equal "0", abridged["X-Goog-Upload-Offset"]
    assert_equal "<...>", abridged["Authorization"]
    assert_equal "<...>", abridged["Content-Type"]
  end

  def test_instructions_summarizes_without_bodies
    instructions = [
      Instruction::SendStart.new(url: "https://example.com/upload?key=SECRET", headers: {}, body: "secret_body"),
      Instruction::SendChunk.new(url: "https://example.com/session?id=123", offset: 0, length: 64, finalize: true),
      Instruction::NotifyProgress.new(progress: Progress.new(phase: :uploading, bytes_uploaded: 64, total_bytes: 1024))
    ]

    summary = Driver::Abridge.instructions instructions
    assert_equal "SendStart", summary[0]["type"]
    assert_equal "https://example.com/upload?key=<...>", summary[0]["url"]
    refute summary[0].key?("body")

    assert_equal "SendChunk", summary[1]["type"]
    assert_equal "https://example.com/session?id=<...>", summary[1]["url"]
    assert_equal 0, summary[1]["offset"]
    assert_equal 64, summary[1]["length"]
    assert_equal true, summary[1]["finalize"]

    assert_equal "NotifyProgress", summary[2]["type"]
    assert_equal "uploading", summary[2]["phase"]
    assert_equal 64, summary[2]["bytesUploaded"]
    assert_equal 1024, summary[2]["totalBytes"]
  end
end
