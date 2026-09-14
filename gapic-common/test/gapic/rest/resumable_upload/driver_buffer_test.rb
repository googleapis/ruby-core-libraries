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
# Tests for Driver stream reading and buffer realignment mechanics.
#
class DriverBufferTest < Minitest::Test
  include Gapic::Rest::ResumableUpload

  ##
  # Stream double that returns at most max_chunk_size bytes per read call.
  #
  class ChunkedStream
    def initialize data, max_chunk_size
      @io = StringIO.new data
      @max_chunk_size = max_chunk_size
    end

    def read length = nil
      return @io.read if length.nil?

      actual_length = [length, @max_chunk_size].min
      @io.read actual_length
    end

    def seek offset
      @io.seek offset
    end

    def pos
      @io.pos
    end
  end

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

  def setup
    @dummy_client = Object.new
  end

  # ============================================================================
  # execute_fill_buffer tests
  # ============================================================================

  def test_fill_buffer_short_reads_accumulates_until_target
    data = "abcdefghijklmnopqrstuvwxyz" * 4 # 104 bytes
    stream = ChunkedStream.new data, 20
    driver = build_driver stream: stream

    event = driver.send :execute_fill_buffer, Instruction::FillBuffer.new(target_bytesize: 100)

    assert_instance_of Event::ChunkRead, event
    assert_equal 100, event.bytes_buffered
    refute event.eof
    assert_equal data.byteslice(0, 100), driver.instance_variable_get(:@buffer)
  end

  def test_fill_buffer_eof_exactly_at_target_boundary
    data = "0123456789" * 10 # exactly 100 bytes
    stream = StringIO.new data
    driver = build_driver stream: stream

    event = driver.send :execute_fill_buffer, Instruction::FillBuffer.new(target_bytesize: 100)

    assert_instance_of Event::ChunkRead, event
    assert_equal 100, event.bytes_buffered
    # eof stays false until a subsequent read attempts to read past boundary
    refute event.eof
    assert_equal 100, stream.pos

    # Subsequent fill detects EOF
    second_event = driver.send :execute_fill_buffer, Instruction::FillBuffer.new(target_bytesize: 101)
    assert_equal 100, second_event.bytes_buffered
    assert second_event.eof
  end

  def test_fill_buffer_eof_mid_fill
    data = "short data of 45 bytes......................." # 45 bytes
    stream = StringIO.new data
    driver = build_driver stream: stream

    event = driver.send :execute_fill_buffer, Instruction::FillBuffer.new(target_bytesize: 100)

    assert_instance_of Event::ChunkRead, event
    assert_equal 45, event.bytes_buffered
    assert event.eof
    assert_equal data, driver.instance_variable_get(:@buffer)
  end

  def test_fill_buffer_empty_stream
    stream = StringIO.new ""
    driver = build_driver stream: stream

    event = driver.send :execute_fill_buffer, Instruction::FillBuffer.new(target_bytesize: 100)

    assert_instance_of Event::ChunkRead, event
    assert_equal 0, event.bytes_buffered
    assert event.eof
    assert_equal "".b, driver.instance_variable_get(:@buffer)
  end

  # ============================================================================
  # execute_realign_buffer tests: trim within buffer
  # ============================================================================

  def test_realign_buffer_trim_exact_beginning
    driver = build_driver stream: StringIO.new
    driver.instance_variable_set :@buffer_start_offset, 1000
    driver.instance_variable_set :@buffer, "0123456789".b

    driver.send :execute_realign_buffer, Instruction::RealignBuffer.new(server_offset: 1000)

    assert_equal 1000, driver.instance_variable_get(:@buffer_start_offset)
    assert_equal "0123456789".b, driver.instance_variable_get(:@buffer)
  end

  def test_realign_buffer_trim_middle
    driver = build_driver stream: StringIO.new
    driver.instance_variable_set :@buffer_start_offset, 1000
    driver.instance_variable_set :@buffer, "0123456789".b

    driver.send :execute_realign_buffer, Instruction::RealignBuffer.new(server_offset: 1004)

    assert_equal 1004, driver.instance_variable_get(:@buffer_start_offset)
    assert_equal "456789".b, driver.instance_variable_get(:@buffer)
  end

  def test_realign_buffer_trim_exact_end
    driver = build_driver stream: StringIO.new
    driver.instance_variable_set :@buffer_start_offset, 1000
    driver.instance_variable_set :@buffer, "0123456789".b

    driver.send :execute_realign_buffer, Instruction::RealignBuffer.new(server_offset: 1010)

    assert_equal 1010, driver.instance_variable_get(:@buffer_start_offset)
    assert_equal "".b, driver.instance_variable_get(:@buffer)
  end

  # ============================================================================
  # execute_realign_buffer tests: rewind stream
  # ============================================================================

  def test_realign_buffer_rewind_seekable_stream
    stream = StringIO.new "0123456789" * 100
    stream.seek 1000
    driver = build_driver stream: stream
    driver.instance_variable_set :@buffer_start_offset, 1000
    driver.instance_variable_set :@buffer, "buffered".b

    driver.send :execute_realign_buffer, Instruction::RealignBuffer.new(server_offset: 500)

    assert_equal 500, driver.instance_variable_get(:@buffer_start_offset)
    assert_equal "".b, driver.instance_variable_get(:@buffer)
    assert_equal 500, stream.pos
  end

  def test_realign_buffer_rewind_unseekable_stream_raises_error
    stream = UnseekableStream.new "0123456789" * 100
    driver = build_driver stream: stream
    driver.instance_variable_set :@buffer_start_offset, 1000
    driver.instance_variable_set :@buffer, "buffered".b

    err = assert_raises UnseekableStreamError do
      driver.send :execute_realign_buffer, Instruction::RealignBuffer.new(server_offset: 500)
    end

    assert_includes err.message, "offset 500"
    assert_includes err.message, "buffered from 1000"
    assert_nil err.resume_handle
    refute_includes err.message, "(upload session is resumable: see #resume_handle)"
  end

  def test_realign_buffer_rewind_unseekable_stream_with_resume_handle
    stream = UnseekableStream.new "0123456789" * 100
    driver = build_driver stream: stream
    driver.core.instance_variable_set(
      :@state,
      driver.core.state.with(status: :recovery, upload_url: "https://upload.example.com/session_1", chunk_size: 256)
    )
    driver.instance_variable_set :@buffer_start_offset, 1000
    driver.instance_variable_set :@buffer, "buffered".b

    err = assert_raises UnseekableStreamError do
      driver.send :execute_realign_buffer, Instruction::RealignBuffer.new(server_offset: 500)
    end

    refute_nil err.resume_handle
    assert_equal "https://upload.example.com/session_1", err.resume_handle.upload_url
    assert_equal 256, err.resume_handle.chunk_size
    assert_includes err.message, "offset 500"
    assert_includes err.message, "buffered from 1000"
    assert_includes err.message, "(upload session is resumable: see #resume_handle)"
  end

  def test_driver_resume_handle_property
    stream = StringIO.new "test"
    driver = build_driver stream: stream
    assert_nil driver.resume_handle

    driver.core.instance_variable_set(
      :@state,
      driver.core.state.with(upload_url: "https://upload.example.com/session_2", chunk_size: 512)
    )
    handle = driver.resume_handle
    refute_nil handle
    assert_equal "https://upload.example.com/session_2", handle.upload_url
    assert_equal 512, handle.chunk_size

    driver.core.instance_variable_set(
      :@state,
      driver.core.state.with(status: :rejected, upload_url: "https://upload.example.com/session_2", chunk_size: 512)
    )
    assert_nil driver.resume_handle

    driver.core.instance_variable_set(
      :@state,
      driver.core.state.with(status: :cancelled, upload_url: "https://upload.example.com/session_2", chunk_size: 512)
    )
    assert_nil driver.resume_handle
  end

  # ============================================================================
  # execute_realign_buffer tests: fast forward stream
  # ============================================================================

  def test_realign_buffer_fast_forward_seekable_stream
    stream = StringIO.new "0123456789" * 200
    stream.seek 1010
    driver = build_driver stream: stream
    driver.instance_variable_set :@buffer_start_offset, 1000
    driver.instance_variable_set :@buffer, "0123456789".b # buffer ends at 1010

    driver.send :execute_realign_buffer, Instruction::RealignBuffer.new(server_offset: 1050)

    assert_equal 1050, driver.instance_variable_get(:@buffer_start_offset)
    assert_equal "".b, driver.instance_variable_get(:@buffer)
    assert_equal 1050, stream.pos
  end

  def test_realign_buffer_fast_forward_unseekable_stream
    # Stream contains 1000 bytes. Buffer has consumed up to 10 bytes (buffer_start=0, length=10 -> buffer_end=10).
    # Unseekable stream pos is currently at 10.
    stream = UnseekableStream.new "0123456789" * 100
    stream.read 10 # advance stream to match buffer_end
    assert_equal 10, stream.pos

    driver = build_driver stream: stream
    driver.instance_variable_set :@buffer_start_offset, 0
    driver.instance_variable_set :@buffer, "0123456789".b # ends at offset 10

    # Fast forward to 50 (discards 40 bytes from stream)
    driver.send :execute_realign_buffer, Instruction::RealignBuffer.new(server_offset: 50)

    assert_equal 50, driver.instance_variable_get(:@buffer_start_offset)
    assert_equal "".b, driver.instance_variable_get(:@buffer)
    assert_equal 50, stream.pos
    assert_equal "0123456789", stream.read(10)
  end

  def test_fast_forward_unseekable_stream_raises_stream_mismatch_on_unexpected_eof
    # Stream has only 20 bytes total
    stream = UnseekableStream.new "01234567890123456789"
    resume_config = ResumeUploadConfig.new(
      upload_url: "https://upload.example.com/session_resume",
      chunk_size: 256,
      stream:     stream
    )
    driver = Driver.new client_stub: @dummy_client, config: resume_config
    driver.core.instance_variable_set(
      :@state,
      driver.core.state.with(status: :recovery, upload_url: "https://upload.example.com/session_resume", chunk_size: 256)
    )
    driver.instance_variable_set :@buffer, "".b
    driver.instance_variable_set :@buffer_start_offset, 0

    # Server offset is 50, but stream only has 20 bytes -> EOF hit during discard
    err = assert_raises StreamMismatchError do
      driver.send :execute_realign_buffer, Instruction::RealignBuffer.new(server_offset: 50)
    end

    refute_nil err.resume_handle
    assert_equal "https://upload.example.com/session_resume", err.resume_handle.upload_url
    assert_includes err.message, "unexpected EOF during fast-forward"
    assert_includes err.message, "(upload session is resumable: see #resume_handle)"
  end

  def test_realign_buffer_raises_stream_mismatch_when_server_offset_exceeds_upload_size
    stream = StringIO.new "data"
    resume_config = ResumeUploadConfig.new(
      upload_url:  "https://upload.example.com/session_resume",
      chunk_size:  256,
      stream:      stream,
      upload_size: 500
    )
    driver = Driver.new client_stub: @dummy_client, config: resume_config
    driver.core.instance_variable_set(
      :@state,
      driver.core.state.with(status: :recovery, upload_url: "https://upload.example.com/session_resume", chunk_size: 256)
    )

    err = assert_raises StreamMismatchError do
      driver.send :execute_realign_buffer, Instruction::RealignBuffer.new(server_offset: 600)
    end

    refute_nil err.resume_handle
    assert_equal "https://upload.example.com/session_resume", err.resume_handle.upload_url
    assert_includes err.message, "Server reported offset 600 exceeds total upload size 500"
    assert_includes err.message, "(upload session is resumable: see #resume_handle)"
  end

  def test_realign_buffer_fast_forward_seekable_stream_raises_stream_mismatch_when_exceeding_stream_size
    stream = StringIO.new "hello"
    resume_config = ResumeUploadConfig.new(
      upload_url:  "https://upload.example.com/session_resume",
      chunk_size:  256,
      stream:      stream,
      upload_size: nil
    )
    driver = Driver.new client_stub: @dummy_client, config: resume_config
    driver.core.instance_variable_set(
      :@state,
      driver.core.state.with(status: :recovery, upload_url: "https://upload.example.com/session_resume", chunk_size: 256)
    )

    err = assert_raises StreamMismatchError do
      driver.send :execute_realign_buffer, Instruction::RealignBuffer.new(server_offset: 1000)
    end

    refute_nil err.resume_handle
    assert_equal "https://upload.example.com/session_resume", err.resume_handle.upload_url
    assert_includes err.message, "Server reported offset 1000 exceeds stream size 5"
    assert_includes err.message, "(upload session is resumable: see #resume_handle)"
  end

  private

  def build_driver stream:
    config = StartUploadConfig.new(
      initial_url: "https://example.com/upload",
      stream:      stream,
      upload_size: 2000,
      chunk_size:  100
    )
    Driver.new client_stub: @dummy_client, config: config
  end
end
