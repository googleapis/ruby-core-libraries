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

require "gapic/config"

module Gapic
  module Rest
    ##
    # @private
    # A specialized Configuration class to use when generating
    # package-level binding override configuration.
    #
    # This configuration is for internal use of the client library classes,
    # and it is not intended that the end-users will read or change it.
    #
    # @attribute [rw] bindings_override
    #  Overrides for http bindings for the RPC of the mixins for the given package.
    #  return [::Hash{::Symbol=>::Array<::Gapic::Rest::GrpcTranscoder::HttpBinding>}]
    #
    class HttpBindingOverrideConfiguration
      extend ::Gapic::Config

      # @private
      # Overrides for http bindings for the RPC of the mixins for the given package.
      # Services in the package should use these when creating clients for the mixin services.
      # @return [::Hash{::Symbol=>::Array<::Gapic::Rest::GrpcTranscoder::HttpBinding>}]
      config_attr :bindings_override, {}, ::Hash, nil

      # @private
      def initialize parent_config = nil
        @parent_config = parent_config unless parent_config.nil?

        yield self if block_given?
      end
    end
  end
end
