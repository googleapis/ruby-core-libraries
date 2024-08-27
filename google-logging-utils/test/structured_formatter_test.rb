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
require "json"
require "logger"
require "stringio"
require "google/logging/structured_formatter"

describe Google::Logging::StructuredFormatter do
  let(:io) { StringIO.new }
  let(:formatter) { Google::Logging::StructuredFormatter.new }
  let(:progname) { "tron" }
  let(:logger) { Logger.new io, level: Logger::DEBUG, progname: progname, formatter: formatter }
  let(:log_entries) { io.string.split("\n").map { |line| JSON.load line } }

  it "logs a simple string" do
    logger.info "hello ruby"
    assert_equal "hello ruby", log_entries.first["message"]
  end

  it "logs a hash of stuff" do
    stuff = { "foo" => "bar", "baz" => [1, 2, 3], message: "hello ruby" }
    logger.info stuff
    assert_equal "hello ruby", log_entries.first["message"]
    assert_equal "bar", log_entries.first["foo"]
    assert_equal [1, 2, 3], log_entries.first["baz"]
  end

  it "logs a message object" do
    logger.info Google::Logging::Message.from "hello message"
    assert_equal "hello message", log_entries.first["message"]
  end

  it "escapes newlines" do
    logger.debug "hello\nruby"
    assert_equal "hello\nruby", log_entries.first["message"]
  end

  it "recognizes debug severity" do
    logger.debug "hello ruby"
    assert_equal "DEBUG", log_entries.first["severity"]
  end

  it "recognizes info severity" do
    logger.info "hello ruby"
    assert_equal "INFO", log_entries.first["severity"]
  end

  it "recognizes warning severity" do
    logger.warn "hello ruby"
    assert_equal "WARNING", log_entries.first["severity"]
  end

  it "recognizes error severity" do
    logger.error "hello ruby"
    assert_equal "ERROR", log_entries.first["severity"]
  end

  it "recognizes critical severity" do
    logger.fatal "hello ruby"
    assert_equal "CRITICAL", log_entries.first["severity"]
  end

  it "recognizes any severity" do
    logger.unknown "hello ruby"
    assert_equal "DEFAULT", log_entries.first["severity"]
  end

  it "includes progname" do
    logger.debug "hello ruby"
    assert_equal progname, log_entries.first["progname"]
  end

  it "includes a default time" do
    logger.debug "hello ruby"
    assert_kind_of Integer, log_entries.first["timestamp"]["seconds"]
    assert_kind_of Integer, log_entries.first["timestamp"]["nanos"]
  end

  it "includes a custom time" do
    time = Time.at(123456789, 654321, :nsec)
    msg = Google::Logging::Message.from message: "hello, ruby", timestamp: time
    logger.info msg
    assert_equal 123456789, log_entries.first["timestamp"]["seconds"]
    assert_equal 654321, log_entries.first["timestamp"]["nanos"]
  end

  it "does not include unset fields" do
    logger.progname = nil
    logger.info "hello, ruby"
    refute log_entries.first.key?("logging.googleapis.com/sourceLocation")
    refute log_entries.first.key?("logging.googleapis.com/insertId")
    refute log_entries.first.key?("logging.googleapis.com/spanId")
    refute log_entries.first.key?("logging.googleapis.com/trace")
    refute log_entries.first.key?("logging.googleapis.com/traceSampled")
    refute log_entries.first.key?("logging.googleapis.com/labels")
    refute log_entries.first.key?("progname")
  end

  it "includes insert_id" do
    insert_id = "12345"
    msg = Google::Logging::Message.from message: "hello, ruby", insert_id: insert_id
    logger.info msg
    assert_equal insert_id, log_entries.first["logging.googleapis.com/insertId"]
  end

  it "includes span_id" do
    span_id = "12345"
    msg = Google::Logging::Message.from message: "hello, ruby", span_id: span_id
    logger.info msg
    assert_equal span_id, log_entries.first["logging.googleapis.com/spanId"]
  end

  it "includes trace" do
    trace = "projects/myproj/trace/hello"
    msg = Google::Logging::Message.from message: "hello, ruby", trace: trace
    logger.info msg
    assert_equal trace, log_entries.first["logging.googleapis.com/trace"]
  end

  it "includes traceSampled" do
    msg = Google::Logging::Message.from message: "hello, ruby", trace_sampled: true
    logger.info msg
    assert_equal true, log_entries.first["logging.googleapis.com/traceSampled"]
  end

  it "includes labels" do
    msg = Google::Logging::Message.from message: "hello, ruby", labels: {foo: "bar"}
    logger.info msg
    expected_labels = {"foo" => "bar"}
    assert_equal expected_labels, log_entries.first["logging.googleapis.com/labels"]
  end

  def line_and_msg
    expected_line = (__LINE__ + 1).to_s
    msg = Google::Logging::Message.from message: "hello, ruby", source_location: :caller
    [expected_line, msg]
  end

  it "includes source location" do
    expected_line, msg = line_and_msg
    logger.info msg
    expected_source_location = {
      "file" => __FILE__,
      "line" => expected_line,
      "function" => "line_and_msg"
    }
    assert_equal expected_source_location, log_entries.first["logging.googleapis.com/sourceLocation"]
  end

  it "logs multiple times" do
    logger.debug "hello ruby"
    logger.debug "hello again"
    assert_equal 2, log_entries.size
  end
end
