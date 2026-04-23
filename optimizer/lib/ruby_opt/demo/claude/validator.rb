# frozen_string_literal: true
require "ruby_opt/demo/claude/serializer"

module RubyOpt
  module Demo
    module Claude
      # Structural validator for IR::Function instruction streams coming back
      # from the "gag pass" (LLM rewrite). Checks that every instruction has
      # a known opcode and the arity matches the YARV operand schema.
      #
      # Semantic checks (stack balance, branch targets, etc.) are Task 5.
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
      end
    end
  end
end
