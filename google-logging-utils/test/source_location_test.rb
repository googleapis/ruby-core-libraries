# frozen_string_literal: true

# Copyright 2024 Google LLC
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

require "helper"
require "google/logging/source_location"

describe Google::Logging::SourceLocation do
  let(:sample_file) { "/path/to/file" }
  let(:sample_line_int) { 1234 }
  let(:sample_line) { sample_line_int.to_s }
  let(:sample_function) { "migrate_to_ruby" }
  let(:sample_location) {
    Google::Logging::SourceLocation.new file: sample_file, line: sample_line_int, function: sample_function
  }
  let(:duplicate_location) {
    Google::Logging::SourceLocation.new file: sample_file, line: sample_line_int, function: sample_function
  }

  it "sets fields" do
    assert_equal sample_file, sample_location.file
    assert_equal sample_line, sample_location.line
    assert_equal sample_function, sample_location.function
  end

  it "converts to a hash" do
    expected = {
      file: sample_file,
      line: sample_line,
      function: sample_function
    }
    assert_equal expected, sample_location.to_h
  end

  it "tests equality" do
    assert_equal sample_location, duplicate_location
    assert_equal sample_location.hash, duplicate_location.hash
  end

  def immediate_caller_line_loc
    expected_line = (__LINE__ + 1).to_s
    loc = Google::Logging::SourceLocation.for_caller
    [expected_line, loc]
  end

  def nested_caller_line_loc
    expected_line = (__LINE__ + 1).to_s
    loc = nested_make_loc
    [expected_line, loc]
  end

  def nested_make_loc
    Google::Logging::SourceLocation.for_caller extra_depth: 1
  end

  it "gets the caller info" do
    expected_line, loc = immediate_caller_line_loc
    assert_equal __FILE__, loc.file
    assert_equal expected_line, loc.line
    assert_equal "immediate_caller_line_loc", loc.function
  end

  it "gets the caller info with extra_depth" do
    expected_line, loc = nested_caller_line_loc
    assert_equal __FILE__, loc.file
    assert_equal expected_line, loc.line
    assert_equal "nested_caller_line_loc", loc.function
  end
end
