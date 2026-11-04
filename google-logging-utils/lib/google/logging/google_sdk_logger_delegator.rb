# Copyright 2025 Google LLC
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

require "delegate"

module Google
  module Logging
    # A delegator that wraps a logger or its duck-type instance to add dynamic
    # filtering based on GOOGLE_SDK_RUBY_LOGGING_GEMS environment variable, and
    # error supression based on suppress_logger_errors parameter
    class GoogleSdkLoggerDelegator < SimpleDelegator
      # @private
      # The environment variable that controls which gems have logging enabled.
      ENV_VAR = "GOOGLE_SDK_RUBY_LOGGING_GEMS".freeze

      # @private
      # The full list of methods a compatible logger must implement.
      REQUIRED_LOGGER_METHODS = [
        :level, :level=, :sev_threshold, :sev_threshold=,
        :progname, :progname=, :formatter, :formatter=,
        :datetime_format, :datetime_format=,
        :debug?, :info?, :warn?, :error?, :fatal?,
        :debug!, :info!, :warn!, :error!, :fatal!,
        :close, :reopen,
        :<<, :add, :debug, :info, :warn, :error, :fatal, :unknown
      ].freeze

      private_constant :ENV_VAR, :REQUIRED_LOGGER_METHODS

      # @param gem_name [String] The name of the gem this logger is for.
      # @param logger [Logger] The custom logger instance to wrap.
      # @param suppress_logger_errors [Boolean] Whether to swallow exceptions in the wrapped logger.
      def initialize gem_name, logger, suppress_logger_errors: true
        unless is_logger_type? logger
          raise ArgumentError, "A valid, compatible logger instance is required."
        end

        super logger
        @gem_name = gem_name
        @suppress_logger_errors = suppress_logger_errors
      end

      # @!group Logging Methods with Filtering

      # Override each logging method to insert the filter check before
      # delegating to the corresponding method on the wrapped logger.

      def << msg
        return true unless logging_enabled?
        suppress_errors { super }
      end

      def add severity, message = nil, progname = nil
        return true unless logging_enabled?
        suppress_errors { super }
      end

      def debug message = nil, &block
        return true unless logging_enabled?
        suppress_errors { super }
      end

      def info message = nil, &block
        return true unless logging_enabled?
        suppress_errors { super }
      end

      def warn message = nil, &block
        return true unless logging_enabled?
        suppress_errors { super }
      end

      def error message = nil, &block
        return true unless logging_enabled?
        suppress_errors { super }
      end

      def fatal message = nil, &block
        return true unless logging_enabled?
        suppress_errors { super }
      end

      def unknown message = nil, &block
        return true unless logging_enabled?
        suppress_errors { super }
      end
      # @!endgroup

      private

      def suppress_errors
        yield
      rescue StandardError
        raise unless @suppress_logger_errors
        true
      end

      def is_logger_type? logger
        return false if logger.nil?
        REQUIRED_LOGGER_METHODS.all? { |m| logger.respond_to? m }
      end

      # Checks if logging is enabled for the current gem.
      def logging_enabled?
        current_env_var = ENV[ENV_VAR]

        # Return the cached result if the ENV var hasn't changed.
        if @cached_env_var_value == current_env_var
          return @cached_logging_enabled_result
        end

        # If the ENV var has changed (or on the first run), re-evaluate.
        new_result = false
        begin
          if current_env_var == "none"
            new_result = false
          elsif current_env_var == "all"
            new_result = true
          else
            packages = current_env_var&.gsub(/\s+/, "")&.split(",") || []
            new_result = packages.include? @gem_name
          end
        rescue StandardError => e
          Kernel.warn "Failed to determine logging configuration for #{@gem_name}. " \
                      "Logging disabled. Error: #{e.class}: #{e.message}"
          new_result = false
        end

        # Update the cache with the new values.
        @cached_env_var_value = current_env_var
        @cached_logging_enabled_result = new_result

        new_result
      end
    end
  end
end
