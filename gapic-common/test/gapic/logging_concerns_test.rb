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

require "test_helper"

require "gapic/logging_concerns"
require "gapic/rest"

module NormalizeServiceFixtures
  module V1
    module ExampleService
      class Stub; end

      module Service
        def self.service_name
          "example.v1.ExampleService"
        end
      end

      module Rest
        class ServiceStub; end
      end
    end
  end

  module Plain
    class Stub; end
  end
end

describe Gapic::LoggingConcerns do
  describe ".normalize_service" do
    def with_toplevel_constant name, klass
      name = name.to_sym
      existed = Object.const_defined? name, false
      original = Object.const_get name, false if existed
      Object.send :remove_const, name if existed
      Object.const_set name, klass
      yield
    ensure
      Object.send :remove_const, name if Object.const_defined? name, false
      Object.const_set name, original if existed
    end

    it "returns a string unchanged" do
      input = "google.example.v1.Foo"
      assert_equal input, Gapic::LoggingConcerns.normalize_service(input)
    end

    it "returns nil for an unrecognized input" do
      assert_nil Gapic::LoggingConcerns.normalize_service(nil)
      assert_nil Gapic::LoggingConcerns.normalize_service(:symbol)
    end

    it "uses a sibling Service.service_name for gRPC stubs" do
      result = Gapic::LoggingConcerns.normalize_service NormalizeServiceFixtures::V1::ExampleService::Stub
      assert_equal "example.v1.ExampleService", result
    end

    it "falls back to a dotted name for REST stubs" do
      result = Gapic::LoggingConcerns.normalize_service(
        NormalizeServiceFixtures::V1::ExampleService::Rest::ServiceStub
      )
      assert_equal "NormalizeServiceFixtures.V1.ExampleService", result
    end

    it "ignores an unrelated top-level Service when resolving REST stubs" do
      with_toplevel_constant :Service, Class.new do
        result = Gapic::LoggingConcerns.normalize_service(
          NormalizeServiceFixtures::V1::ExampleService::Rest::ServiceStub
        )
        assert_equal "NormalizeServiceFixtures.V1.ExampleService", result
      end
    end

    it "still uses a sibling Service when an unrelated top-level Service exists" do
      with_toplevel_constant :Service, Class.new do
        result = Gapic::LoggingConcerns.normalize_service NormalizeServiceFixtures::V1::ExampleService::Stub
        assert_equal "example.v1.ExampleService", result
      end
    end

    it "does not treat a top-level Rest as a REST namespace" do
      with_toplevel_constant :Rest, Class.new do
        result = Gapic::LoggingConcerns.normalize_service NormalizeServiceFixtures::Plain::Stub
        assert_nil result
      end
    end

    it "does not raise when constructing a REST client stub if a top-level Service exists" do
      rest_stub = NormalizeServiceFixtures::V1::ExampleService::Rest::ServiceStub
      with_toplevel_constant :Service, Class.new do
        stub = Gapic::Rest::ClientStub.new endpoint: "google.example.com",
                                           credentials: :dummy_credentials,
                                           service_name: rest_stub,
                                           logger: nil
        assert_nil stub.logger
      end
    end
  end

  describe "random_uuid4" do
    it "outputs the correct format" do
      output = Gapic::LoggingConcerns.random_uuid4
      assert_match(/[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}/, output)
    end

    it "doesn't repeat" do
      output1 = Gapic::LoggingConcerns.random_uuid4
      output2 = Gapic::LoggingConcerns.random_uuid4
      refute_equal output1, output2
    end
  end
end
