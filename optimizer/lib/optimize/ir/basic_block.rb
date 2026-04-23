# frozen_string_literal: true

module Optimize
  module IR
    # One basic block in a function's CFG: a maximal straight-line
    # sequence of instructions with one entry (first instruction) and
    # one exit (last instruction is a branch, leave, or falls through).
    class BasicBlock
      attr_reader :id
      attr_accessor :instructions

      def initialize(id:, instructions: [])
        @id = id
        @instructions = instructions
      end

      def terminator
        @instructions.last
      end

      def empty?
        @instructions.empty?
      end
    end
  end
end
