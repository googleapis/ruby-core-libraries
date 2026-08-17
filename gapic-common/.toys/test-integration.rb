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

require "socket"
require "tmpdir"

expand :minitest, name: "" do |t|
  t.libs = ["lib", "integration"]
  t.files = ["integration/**/*_test.rb"]
  t.bundler = true
end

alias_method :run_minitest, :run

def run
  if !ENV["SHOWCASE_ENDPOINT"].to_s.empty?
    run_minitest
    return
  end

  bin = resolve_showcase_bin
  if bin.nil?
    if !ENV["CI"].to_s.empty?
      logger.error "No SHOWCASE_ENDPOINT or gapic-showcase binary found in CI environment."
      exit 1
    else
      logger.warn "Skipping integration tests: no SHOWCASE_ENDPOINT or gapic-showcase binary found."
      return
    end
  end

  verify_showcase_version! bin

  port = allocate_port
  fallback_port = allocate_port
  log_path = File.join Dir.tmpdir, "gapic-showcase-#{Process.pid}-#{Time.now.to_i}.log"

  pid = Process.spawn(
    bin, "run",
    "--port", ":#{port}",
    "--fallback-port", ":#{fallback_port}",
    out: log_path,
    err: log_path,
    pgroup: true
  )

  begin
    wait_for_showcase! pid, port, log_path
    ENV["SHOWCASE_ENDPOINT"] = "http://localhost:#{port}"
    run_minitest
  ensure
    if pid
      begin
        Process.kill "-TERM", pid
        Process.waitpid pid
      rescue Errno::ESRCH, Errno::ECHILD
        # Process already terminated
      end
    end
  end
end

def resolve_showcase_bin
  env_bin = ENV["SHOWCASE_BIN"].to_s
  return env_bin unless env_bin.empty?

  ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).each do |dir|
    candidate = File.join dir, "gapic-showcase"
    return candidate if File.executable?(candidate) && !File.directory?(candidate)
  end
  nil
end

def verify_showcase_version!(bin)
  output = begin
    IO.popen([bin, "--version"], err: [:child, :out], &:read).strip
  rescue StandardError => e
    logger.error "Failed to execute '#{bin} --version': #{e.message}"
    exit 1
  end

  version_match = output[/\d+\.\d+(?:\.\d+)*/]
  if version_match.nil?
    logger.error "Could not parse version from '#{bin} --version' output: #{output.inspect}"
    exit 1
  end

  if Gem::Version.new(version_match) < Gem::Version.new("0.43")
    logger.error "gapic-showcase version #{version_match} is too old (minimum required is 0.43)."
    exit 1
  end
end

def allocate_port
  server = TCPServer.open "127.0.0.1", 0
  port = server.addr[1]
  server.close
  port
end

def wait_for_showcase!(pid, port, log_path)
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10.0

  loop do
    exited_pid, status = Process.waitpid2 pid, Process::WNOHANG
    if exited_pid
      logger.error "gapic-showcase exited prematurely (status: #{status.exitstatus}). Log file: #{log_path}"
      exit 1
    end

    begin
      sock = TCPSocket.new "127.0.0.1", port
      sock.close
      return
    rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH
      # Server not ready yet
    end

    if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      logger.error "Timed out waiting 10s for gapic-showcase to listen on port #{port}. Log file: #{log_path}"
      exit 1
    end

    sleep 0.1
  end
end
