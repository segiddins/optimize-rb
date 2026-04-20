# frozen_string_literal: true
require "ruby_opt/ir/instruction"

module RubyOpt
  module Passes
    # Reads and emits Integer and boolean literal-producer instructions.
    #
    # Ruby 4.0.2 has three literal-producer shapes:
    #   putobject_INT2FIX_0_     — pushes 0 (no operand)
    #   putobject_INT2FIX_1_     — pushes 1 (no operand)
    #   putobject <index>        — pushes object_table.objects[index]
    module LiteralValue
      module_function

      # @param inst         [IR::Instruction]
      # @param object_table [Codec::ObjectTable]
      # @return [Integer, true, false, nil] the pushed value, or nil if
      #   the instruction is not a recognized literal producer
      def read(inst, object_table:)
        case inst.opcode
        when :putobject_INT2FIX_0_ then 0
        when :putobject_INT2FIX_1_ then 1
        when :putobject
          idx = inst.operands[0]
          return nil unless idx.is_a?(Integer)
          object_table.objects[idx]
        end
      end

      # @param value        [Integer, true, false]
      # @param line         [Integer, nil]
      # @param object_table [Codec::ObjectTable]
      # @return [IR::Instruction]
      def emit(value, line:, object_table:)
        case value
        when 0
          IR::Instruction.new(opcode: :putobject_INT2FIX_0_, operands: [], line: line)
        when 1
          IR::Instruction.new(opcode: :putobject_INT2FIX_1_, operands: [], line: line)
        else
          idx = object_table.intern(value)
          IR::Instruction.new(opcode: :putobject, operands: [idx], line: line)
        end
      end
    end
  end
end
