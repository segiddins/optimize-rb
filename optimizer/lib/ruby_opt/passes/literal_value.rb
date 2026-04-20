# frozen_string_literal: true
require "ruby_opt/ir/instruction"

module RubyOpt
  module Passes
    # Reads and emits literal-producer instructions.
    #
    # Ruby 4.0.2 literal-producer shapes we recognize (confirmed via
    # RubyVM::InstructionSequence disassembly on Ruby 4.0.2):
    #   putobject_INT2FIX_0_     — pushes 0 (no operand)
    #   putobject_INT2FIX_1_     — pushes 1 (no operand)
    #   putobject <index>        — pushes object_table.objects[index]
    #   putchilledstring <index> — default string literal in 4.0.2; pushes the
    #                              String at object_table.objects[index]
    #   putstring <index>        — mutable-string variant; same operand shape
    #   putnil                   — pushes nil (no operand)
    #
    # `read` returning nil is ambiguous (putnil legitimately reads as nil, and
    # an unrecognized opcode also returns nil). Callers that need to
    # distinguish "literal nil" from "not a literal" must use `literal?`.
    #
    # `emit` is unchanged from the Integer/boolean tier — it only knows how to
    # emit putobject-family opcodes.
    module LiteralValue
      module_function

      LITERAL_OPCODES = %i[
        putobject
        putobject_INT2FIX_0_
        putobject_INT2FIX_1_
        putchilledstring
        putstring
        putnil
      ].freeze

      # @param inst [IR::Instruction]
      # @return [Boolean] true iff `inst` is a recognized literal producer.
      def literal?(inst)
        LITERAL_OPCODES.include?(inst.opcode)
      end

      # @param inst         [IR::Instruction]
      # @param object_table [Codec::ObjectTable]
      # @return [Object, nil] the pushed value. Returns nil for :putnil AND
      #   for unrecognized opcodes — use `literal?` to disambiguate.
      def read(inst, object_table:)
        case inst.opcode
        when :putobject_INT2FIX_0_ then 0
        when :putobject_INT2FIX_1_ then 1
        when :putnil               then nil
        when :putobject, :putchilledstring, :putstring
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
