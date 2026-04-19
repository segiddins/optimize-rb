# frozen_string_literal: true
require "ruby_opt/rbs_parser"

module RubyOpt
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
  end
end
