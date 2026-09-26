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
# Integration tests for chunk granularity alignment against Showcase, driven through
# ::Gapic::ResumableUpload.
#
class ChunkGranularityTest < ShowcaseIntegrationTest
  # Verifies chunk size alignment to server-specified granularity (300_000 -> 299_776) and progress notifications.
  def test_chunk_granularity_alignment
    size = 1_000_000

    upload = build_upload scenario: "chunk_granularity"
    result = upload.start(**start_args(stream:         StringIO.new(payload(size)),
                                       upload_size:    size,
                                       chunk_size:     300_000,
                                       upload_timeout: 5))
    parsed = JSON.parse result

    assert_equal size, parsed["size"]
    assert_equal [0, 0, 299_776, 599_552, 899_328, 899_328, 1_000_000], offsets
    assert_equal [:initiating, :uploading, :uploading, :uploading, :uploading, :finalizing, :completed], phases

    # A finalized upload leaves nothing to resume, alignment or not.
    assert_nil upload.resume_handle
  end
end
