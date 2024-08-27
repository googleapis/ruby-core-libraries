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
require "logger"
require "stringio"
require "google/logging/message"

describe Google::Logging::Message do
  let(:sample_file) { "/path/to/file" }
  let(:sample_line_int) { 1234 }
  let(:sample_line) { sample_line_int.to_s }
  let(:sample_function) { "migrate_to_ruby" }
  let(:sample_location) {
    Google::Logging::SourceLocation.new file: sample_file, line: sample_line_int, function: sample_function
  }

  describe "#== and #hash" do
    it "detects equal messages" do
      msg1 = Google::Logging::Message.new message: :hello
      msg2 = Google::Logging::Message.new message: "hello"
      assert_equal msg1, msg2
      assert_equal msg1.hash, msg2.hash
    end

    it "detects unequal messages" do
      msg1 = Google::Logging::Message.new message: "hello2"
      msg2 = Google::Logging::Message.new message: "hello1"
      refute_equal msg1, msg2
      refute_equal msg1.hash, msg2.hash
    end
  end

  describe "#message" do
    it "constructs from a message string" do
      msg = Google::Logging::Message.new message: :hello
      assert_equal "hello", msg.message
      assert_equal "hello", msg.to_s
    end

    it "constructs from a set of fields" do
      msg = Google::Logging::Message.new fields: {foo: 1, bar: 2}
      assert_equal '{"foo":1,"bar":2}', msg.message
      assert_equal '{"foo":1,"bar":2}', msg.to_s
    end

    it "constructs from a message string and fields" do
      msg = Google::Logging::Message.new message: :hello, fields: {foo: 1, bar: 2}
      assert_equal "hello", msg.message
      assert_equal "hello", msg.to_s
    end
  end

  describe "#full_message" do
    it "constructs from a message string" do
      msg = Google::Logging::Message.new message: :hello
      assert_equal "hello", msg.full_message
      assert_equal "hello", msg.inspect
    end

    it "constructs from a set of fields" do
      msg = Google::Logging::Message.new fields: {foo: 1, bar: 2}
      assert_equal '{"foo":1,"bar":2}', msg.full_message
      assert_equal '{"foo":1,"bar":2}', msg.inspect
    end

    it "constructs from a message string and fields" do
      msg = Google::Logging::Message.new message: :hello, fields: {foo: 1, bar: 2}
      assert_equal 'hello -- {"foo":1,"bar":2}', msg.full_message
      assert_equal 'hello -- {"foo":1,"bar":2}', msg.inspect
    end
  end

  describe "#fields" do
    it "is nil when fields were not used" do
      msg = Google::Logging::Message.new message: :hello
      assert_nil msg.fields
    end

    it "normalizes" do
      input = {
        "sym" => :foo,
        str: "bar",
        numeric: -1.5,
        null: nil,
        array: [1, "two", {ruby: "rules"}],
        hash: {
          "sym" => :baz,
          str: "qux",
          nested: ["ruby", :rules]
        }
      }
      expected = {
        "sym" => "foo",
        "str" => "bar",
        "numeric" => -1.5,
        "null" => nil,
        "array" => [1, "two", {"ruby" => "rules"}],
        "hash" => {
          "sym" => "baz",
          "str" => "qux",
          "nested" => ["ruby", "rules"]
        }
      }
      msg = Google::Logging::Message.new fields: input
      assert_equal expected, msg.fields
    end

    [
      :severity,
      :message,
      :log,
      :httpRequest,
      :timestamp,
      "logging.googleapis.com/insertId"
    ].each do |bad_field|
      it "disallows #{bad_field} field" do
        ex = assert_raises ArgumentError do
          Google::Logging::Message.new fields: {bad_field => "max"}
        end
        assert_equal "Field key not allowed: #{bad_field}", ex.message
      end
    end
  end

  describe "#timestamp" do
    let(:time_secs) { 123456789 }
    let(:time_obj) { Time.at time_secs }

    it "supports nil" do
      msg = Google::Logging::Message.new message: :hello
      assert_nil msg.timestamp
    end

    it "supports a time object input" do
      msg = Google::Logging::Message.new message: :hello, timestamp: time_obj
      assert_equal time_obj, msg.timestamp
    end

    it "supports a numeric input" do
      msg = Google::Logging::Message.new message: :hello, timestamp: time_secs
      assert_equal time_obj, msg.timestamp
    end

    it "supports :now as input" do
      msg = Google::Logging::Message.new message: :hello, timestamp: :now
      assert_kind_of Time, msg.timestamp
    end
  end

  describe "#source_location" do
    let(:sample_file) { "/path/to/file" }
    let(:sample_line) { "1234" }
    let(:sample_function) { "migrate_to_ruby" }
    let(:sample_location) {
      Google::Logging::SourceLocation.new file: sample_file, line: sample_line, function: sample_function
    }

    it "supports nil" do
      msg = Google::Logging::Message.new message: :hello
      assert_nil msg.source_location
    end

    it "supports a SourceLocation object input" do
      msg = Google::Logging::Message.new message: :hello, source_location: sample_location
      assert_equal sample_location, msg.source_location
    end

    it "supports hash input" do
      input = {
        file: sample_file,
        line: sample_line,
        function: sample_function
      }
      msg = Google::Logging::Message.new message: :hello, source_location: input
      assert_equal sample_location, msg.source_location
    end

    it "supports :caller input" do
      expected_line = (__LINE__ + 1).to_s
      msg = Google::Logging::Message.new message: :hello, source_location: :caller
      loc = msg.source_location
      assert_equal __FILE__, loc.file
      assert_equal expected_line, loc.line
    end
  end

  describe "string fields" do
    let(:sample_insert_id) { "123" }
    let(:sample_trace) { "projects/hello/trace/ruby" }
    let(:sample_span_id) { "456" }

    it "supports nil" do
      msg = Google::Logging::Message.new message: :hello
      assert_nil msg.insert_id
      assert_nil msg.trace
      assert_nil msg.span_id
    end

    it "supports string input" do
      msg = Google::Logging::Message.new message: :hello,
                                         insert_id: sample_insert_id,
                                         trace: sample_trace,
                                         span_id: sample_span_id
      assert_equal sample_insert_id, msg.insert_id
      assert_equal sample_trace, msg.trace
      assert_equal sample_span_id, msg.span_id
    end

    it "supports non-string input" do
      msg = Google::Logging::Message.new message: :hello,
                                         insert_id: sample_insert_id.to_i,
                                         trace: sample_trace.to_sym,
                                         span_id: sample_span_id.to_i
      assert_equal sample_insert_id, msg.insert_id
      assert_equal sample_trace, msg.trace
      assert_equal sample_span_id, msg.span_id
    end
  end

  describe "#trace_sampled" do
    it "supports nil" do
      msg = Google::Logging::Message.new message: :hello
      assert_nil msg.trace_sampled
      assert_nil msg.trace_sampled?
    end

    it "supports truthy" do
      msg = Google::Logging::Message.new message: :hello, trace_sampled: 1
      assert_equal true, msg.trace_sampled
      assert_equal true, msg.trace_sampled?
    end

    it "supports falsy" do
      msg = Google::Logging::Message.new message: :hello, trace_sampled: false
      assert_equal false, msg.trace_sampled
      assert_equal false, msg.trace_sampled?
    end
  end

  describe "#labels" do
    it "supports nil" do
      msg = Google::Logging::Message.new message: :hello
      assert_nil msg.labels
    end

    it "normalizes" do
      input = {
        "sym" => :foo,
        str: "bar",
        numeric: -1.5,
        null: nil,
        array: [1, "two"],
        hash: {
          "sym" => :baz,
          str: "qux",
        }
      }
      expected = {
        "sym" => "foo",
        "str" => "bar",
        "numeric" => "-1.5",
        "null" => "",
        "array" => '[1,"two"]',
        "hash" => '{"sym":"baz","str":"qux"}'
      }
      msg = Google::Logging::Message.new message: :hello, labels: input
      assert_equal expected, msg.labels
    end
  end

  describe ".from" do
    let(:sample_insert_id) { "123456789" }
    let(:fields_hash) { {"foo" => 1, "bar" => 2} }

    it "interprets a hash as fields and kwargs" do
      msg = Google::Logging::Message.from insert_id: sample_insert_id, **fields_hash
      assert_equal '{"foo":1,"bar":2}', msg.message
      assert_equal fields_hash, msg.fields
      assert_equal sample_insert_id, msg.insert_id
    end

    it "merges fields and the :fields kwarg" do
      msg = Google::Logging::Message.from insert_id: sample_insert_id, fields: {foo: 1}, "bar" => 2
      assert_equal '{"foo":1,"bar":2}', msg.message
      assert_equal fields_hash, msg.fields
      assert_equal sample_insert_id, msg.insert_id
    end

    it "interprets a message" do
      original = Google::Logging::Message.new message: :hello, fields: fields_hash
      msg = Google::Logging::Message.from original
      assert_same original, msg
    end

    it "interprets a stringy value" do
      msg = Google::Logging::Message.from 12345
      assert_equal "12345", msg.message
      assert_nil msg.fields
    end
  end

  describe "logging" do
    let(:io) { StringIO.new }
    let(:logger) { Logger.new io, progname: "myprog" }

    it "formats using the text message by default" do
      msg = Google::Logging::Message.from "Hello Ruby"
      logger.warn msg
      str = io.string
      assert str.end_with? "-- myprog: Hello Ruby\n"
    end
  end
end
