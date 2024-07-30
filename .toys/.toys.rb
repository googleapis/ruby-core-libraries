# frozen_string_literal: true

# Copyright 2024 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

toys_version! ">= 0.15.6"

expand :clean, paths: :gitignore

# Figure out if we are in a gem directory.
# gem_context will be set to the gem base directory, otherwise nil.
gem_context = nil
cur_dir = Dir.getwd
root_dir = context_directory
if cur_dir.start_with? root_dir
  while (parent = File.dirname cur_dir) != root_dir && parent != cur_dir
    cur_dir = parent
  end
  gem_name = File.basename cur_dir
  gem_context = cur_dir if File.file? "#{cur_dir}/#{gem_name}.gemspec"
end

if gem_context
  expand :rubocop do |t|
    t.bundler = true
    t.context_directory = gem_context
  end

  expand :minitest do |t|
    t.libs = ["lib", "test"]
    t.files = ["test/**/*_test.rb"]
    t.bundler = true
    t.context_directory = gem_context
  end

  expand :yardoc do |t|
    t.generate_output_flag = true
    t.fail_on_warning = true
    t.fail_on_undocumented_objects = true
    t.bundler = true
    t.context_directory = gem_context
  end

  tool "yard", delegate_to: "yardoc"

  expand :gem_build do |t|
    t.context_directory = gem_context
  end

  expand :gem_build do |t|
    t.name = "install"
    t.install_gem = true
    t.context_directory = gem_context
  end

  tool "bundle" do
    set_context_directory gem_context

    flag :update, desc: "Update rather than install the bundle"

    include :exec, e: true

    def run
      require "bundler"
      Dir.chdir context_directory
      Bundler.with_unbundled_env do
        exec ["bundle", update ? "update" : "install"]
      end
    end
  end

  tool "linkinator" do
    set_context_directory gem_context

    include :exec, e: true
    include :terminal
  
    def run
      Dir.chdir File.dirname context_directory
      gem_name = File.basename context_directory
      skip_regexes = [
        "\\w+\\.md$",
        "^https://rubygems\\.org/gems/#{gem_name}",
        "^https://cloud\\.google\\.com/ruby/docs/reference/#{gem_name}/latest$",
        "^https://rubydoc\\.info/gems/#{gem_name}"
      ]
      linkinator_cmd = ["npx", "linkinator", "./#{gem_name}/doc", "--retry-errors", "--skip", skip_regexes.join(" ")]
      result = exec linkinator_cmd, out: [:tee, :capture, :inherit], err: [:child, :out], in: :null
      output_lines = result.captured_out.split "\n"
      allowed_http_codes = ["200", "202"]
      output_lines.select! { |link| link =~ /^\[(\d+)\]/ && !allowed_http_codes.include?(::Regexp.last_match[1]) }
      output_lines.each do |link|
        puts link, :yellow
      end
      exit 1 unless output_lines.empty?
    end
  end
end
