# frozen_string_literal: true
require "psych"
require "ruby_opt/demo"
require "ruby_opt/pipeline"

module RubyOpt
  module Demo
    class Walkthrough
      class InvalidSidecar < StandardError; end

      REQUIRED_FIELDS = %w[fixture entry_setup entry_call walkthrough].freeze

      attr_reader :fixture, :entry_setup, :entry_call, :walkthrough, :sidecar_path

      def self.load(path)
        data = Psych.safe_load_file(path, permitted_classes: [])
        raise InvalidSidecar, "sidecar is not a mapping: #{path}" unless data.is_a?(Hash)

        missing = REQUIRED_FIELDS - data.keys
        raise InvalidSidecar, "missing fields #{missing.inspect} in #{path}" unless missing.empty?

        wt_names = Array(data["walkthrough"]).map(&:to_sym)
        valid = Pipeline.default.passes.map(&:name)
        unknown = wt_names - valid
        unless unknown.empty?
          raise InvalidSidecar,
                "unknown pass name(s) in #{path}: #{unknown.inspect}; valid: #{valid.inspect}"
        end

        new(
          sidecar_path: path,
          fixture: data["fixture"],
          entry_setup: data["entry_setup"].to_s,
          entry_call: data["entry_call"],
          walkthrough: wt_names,
        )
      end

      def initialize(sidecar_path:, fixture:, entry_setup:, entry_call:, walkthrough:)
        @sidecar_path = sidecar_path
        @fixture = fixture
        @entry_setup = entry_setup
        @entry_call = entry_call
        @walkthrough = walkthrough
      end

      def fixture_path
        File.expand_path(@fixture, File.dirname(@sidecar_path))
      end
    end
  end
end
