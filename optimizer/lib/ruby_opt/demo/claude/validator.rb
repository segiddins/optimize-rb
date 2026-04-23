# frozen_string_literal: true
require "ruby_opt/demo/claude/serializer"
require "ruby_opt/codec"

module RubyOpt
  module Demo
    module Claude
      # Structural validator for IR::Function instruction streams coming back
      # from the "gag pass" (LLM rewrite). Checks that every instruction has
      # a known opcode and the arity matches the YARV operand schema.
      module Validator
        module_function

        # @param function [IR::Function]
        # @return [Array<String>] one human-readable error per problematic
        #   instruction; empty when the stream is structurally valid.
        def structural(function)
          errors = []
          function.instructions.each_with_index do |insn, idx|
            op_types = Serializer::OPCODE_OPERAND_TYPES[insn.opcode]
            if op_types.nil?
              errors << "instruction #{idx}: unknown opcode :#{insn.opcode}"
              next
            end
            expected = op_types.size
            actual = insn.operands.size
            if expected != actual
              errors << "instruction #{idx}: opcode :#{insn.opcode} expects #{expected} operand(s), got #{actual}"
            end
          end
          errors
        end

        # Encode the envelope, load it as an iseq, run it (which defines any
        # top-level methods), then evaluate +entry+ in TOPLEVEL_BINDING and
        # compare against +expected+ with ==.
        #
        # @param envelope [IR::Function] a root-level function (as returned by
        #   RubyOpt::Codec.decode) with any mutations already spliced in.
        # @param entry [String] Ruby source evaluated in TOPLEVEL_BINDING to
        #   produce the value under test.
        # @param expected [Object] expected value, compared with ==.
        # @return [Array<String>] empty on success; otherwise one error.
        def semantic(envelope, entry:, expected:)
          binary = RubyOpt::Codec.encode(envelope)
          RubyVM::InstructionSequence.load_from_binary(binary).eval
          result = TOPLEVEL_BINDING.eval(entry)
          if result == expected
            []
          else
            ["iseq returned #{result.inspect}; expected #{expected.inspect}"]
          end
        rescue => e
          ["loader/runtime error: #{e.class}: #{e.message}"]
        end
      end
    end
  end
end
