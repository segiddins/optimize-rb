# frozen_string_literal: true
require "ruby_opt/pass"

module RubyOpt
  module Passes
    # Peephole: drop adjacent `setlocal X; getlocal X` pairs where slot X has
    # no other references at the matching level in the same function.
    #
    # The producer that fed the setlocal has already pushed its value onto
    # the operand stack; the getlocal was just reading it back. Dropping
    # both leaves the value where subsequent instructions expect it.
    class DeadStashElimPass < RubyOpt::Pass
      SETLOCAL_OPCODES = %i[setlocal setlocal_WC_0].freeze
      GETLOCAL_OPCODES = %i[getlocal getlocal_WC_0].freeze
      LOCAL_OPCODES    = (SETLOCAL_OPCODES + GETLOCAL_OPCODES).freeze

      def name
        :dead_stash_elim
      end

      def apply(function, type_env:, log:, **_extras)
        insts = function.instructions
        return unless insts && insts.size >= 2

        candidates = []
        i = 0
        while i < insts.size - 1
          a = insts[i]
          b = insts[i + 1]
          if matching_pair?(a, b) && slot_has_no_other_refs?(insts, i, a)
            candidates << i
            i += 2
          else
            i += 1
          end
        end

        return if candidates.empty?

        candidates.reverse_each do |idx|
          line = (function.instructions[idx]&.line) || function.first_lineno || 0
          function.splice_instructions!(idx..idx + 1, [])
          log.rewrite(
            pass: :dead_stash_elim, reason: :dead_stash_eliminated,
            file: function.path, line: line,
          )
        end
      end

      private

      def matching_pair?(a, b)
        return false unless SETLOCAL_OPCODES.include?(a.opcode)
        return false unless GETLOCAL_OPCODES.include?(b.opcode)
        return false unless a.operands[0] == b.operands[0]

        a_wc0 = a.opcode == :setlocal_WC_0
        b_wc0 = b.opcode == :getlocal_WC_0
        if a_wc0 && b_wc0
          true
        elsif !a_wc0 && !b_wc0
          a.operands[1] == b.operands[1]
        else
          false
        end
      end

      def slot_has_no_other_refs?(insts, pair_idx, pair_first)
        slot = pair_first.operands[0]
        level = pair_first.opcode == :setlocal_WC_0 ? 0 : pair_first.operands[1]
        insts.each_with_index.none? do |inst, j|
          next false if j == pair_idx || j == pair_idx + 1
          next false unless LOCAL_OPCODES.include?(inst.opcode)
          inst_slot  = inst.operands[0]
          inst_level = inst.opcode.to_s.end_with?("_WC_0") ? 0 : inst.operands[1]
          inst_slot == slot && inst_level == level
        end
      end
    end
  end
end
