# frozen_string_literal: true
require "optimize/rbs_parser"

module Optimize
  class TypeEnv
    def self.from_source(source, file)
      new(RbsParser.parse(source, file))
    end

    def initialize(signatures)
      @by_key = {}
      signatures.each do |s|
        @by_key[[s.receiver_class, s.method_name]] = s
      end
    end

    def signature_for(receiver_class:, method_name:)
      @by_key[[receiver_class, method_name]]
    end

    def empty?
      @by_key.empty?
    end

    def signature_for_function(function, class_context:)
      return nil unless function.type == :method && function.name
      @by_key[[class_context, function.name.to_sym]]
    end

    def new_returns?(class_name)
      class_name
    end
  end
end
