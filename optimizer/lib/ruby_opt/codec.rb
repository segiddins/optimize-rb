# frozen_string_literal: true
require "ruby_opt/codec/binary_reader"
require "ruby_opt/codec/binary_writer"
require "ruby_opt/codec/header"
require "ruby_opt/codec/object_table"

module RubyOpt
  module Codec
    # Raised when a binary blob does not conform to the YARB format.
    class MalformedBinary < StandardError; end

    # Decodes a YARB binary blob (from RubyVM::InstructionSequence#to_binary)
    # into an IR::Function.
    def self.decode(binary)
      raise NotImplementedError
    end

    # Encodes an IR::Function back into YARB binary form accepted by
    # RubyVM::InstructionSequence.load_from_binary.
    def self.encode(ir)
      raise NotImplementedError
    end
  end
end
