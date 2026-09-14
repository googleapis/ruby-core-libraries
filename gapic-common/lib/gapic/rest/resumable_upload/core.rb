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

require "gapic/rest/resumable_upload/data_types"
require "gapic/rest/resumable_upload/rules"

module Gapic
  module Rest
    module ResumableUpload
      ##
      # @private
      # State machine container holding the immutable State snapshot.
      # Contains zero protocol branching logic and zero side-effects.
      #
      # The middle tier of the three-tier design: `Driver` executes side effects, {Rules} decides transitions,
      # and Core holds the {State} between the two. See {Rules} for the protocol narrative and state graph, and
      # `design/implementation-guide.md` section 1 for the tier boundaries.
      #
      class Core
        # @private
        # @return [State] Current immutable state snapshot
        attr_reader :state

        # @private
        # @return [Decision, nil] Decision emitted during the last dispatch
        attr_reader :last_decision

        ##
        # @private
        # Initializes a Core state machine container.
        #
        # @param config [StartUploadConfig, ResumeUploadConfig] Upload session configuration
        #
        def initialize config
          @config = config
          @last_decision = nil
          @state = State.new(
            status:            :initializing,
            upload_url:        nil,
            offset:            0,
            chunk_size:        config.chunk_size || Rules::DEFAULT_CHUNK_SIZE,
            chunk_granularity: nil,
            in_flight_length:  0,
            last_error:        nil
          )
        end

        ##
        # @private
        # Dispatches event to Rules and updates internal state snapshot.
        #
        # @param event [Object] Input event
        # @return [Array<Object>] Driver instructions
        #
        def dispatch event
          decision = Rules.decide @state, event, @config
          @state = decision.next_state
          @last_decision = decision
          decision.instructions
        end
      end
    end
  end
end
