# frozen_string_literal: true
require "optimize/pass"
require "optimize/ir/instruction"

module Optimize
  module Passes
    # Peephole: drop adjacent `setlocal X; getlocal X` pairs where slot X has
    # no other references at the matching level in the same function.
    #
    # The producer that fed the setlocal has already pushed its value onto
    # the operand stack; the getlocal was just reading it back. Dropping
    # both leaves the value where subsequent instructions expect it.
    #
    # Additional peepholes (all level-0 only):
    #
    # Peephole A — Literal forwarding: if slot X has exactly 1 writer and the
    # instruction immediately preceding that writer is a pure literal pusher,
    # replace every reader with a fresh copy of the literal pusher and drop
    # the writer + its literal producer.
    #
    # Peephole B — Dead write-only stash: if slot X has exactly 1 writer and
    # 0 readers, and the immediately preceding instruction is a pure value
    # producer, drop both the producer and the writer.
    #
    # Peephole C — Adjacent pure-push + pop: drop `<pure pusher>; pop` pairs.
    class DeadStashElimPass < Optimize::Pass
      SETLOCAL_OPCODES = %i[setlocal setlocal_WC_0].freeze
      GETLOCAL_OPCODES = %i[getlocal getlocal_WC_0].freeze
      LOCAL_OPCODES    = (SETLOCAL_OPCODES + GETLOCAL_OPCODES).freeze

      # Pure literal pushers — deterministic, no side effects, stack-neutral (push 1).
      PURE_LITERAL_OPCODES = %i[
        putnil putobject putstring
        putobject_INT2FIX_0_ putobject_INT2FIX_1_
      ].freeze

      # Pure value producers — side-effect-free (includes local reads).
      PURE_PRODUCER_OPCODES = (PURE_LITERAL_OPCODES + %i[getlocal_WC_0 getlocal]).freeze

      def name
        :dead_stash_elim
      end

      def apply(function, type_env:, log:, **_extras)
        insts = function.instructions
        return unless insts && insts.size >= 2

        peephole_a_literal_forwarding(function, log)
        peephole_b_dead_write_only_stash(function, log)
        peephole_c_pure_push_pop(function, log)
        peephole_adjacent_stash(function, log)
      end

      private

      # ---------------------------------------------------------------------------
      # Peephole A: single-writer literal forwarding
      # ---------------------------------------------------------------------------
      def peephole_a_literal_forwarding(function, log)
        insts = function.instructions

        # Collect writer/reader info for every level-0 slot.
        # writers[slot] = [[index, inst], ...]; readers[slot] = [[index, inst], ...]
        writers = Hash.new { |h, k| h[k] = [] }
        readers = Hash.new { |h, k| h[k] = [] }
        insts.each_with_index do |inst, i|
          case inst.opcode
          when :setlocal_WC_0
            writers[inst.operands[0]] << [i, inst]
          when :setlocal
            writers[inst.operands[0]] << [i, inst] if inst.operands[1] == 0
          when :getlocal_WC_0
            readers[inst.operands[0]] << [i, inst]
          when :getlocal
            readers[inst.operands[0]] << [i, inst] if inst.operands[1] == 0
          end
        end

        # Find candidate slots: exactly 1 writer, preceded by a pure literal.
        to_drop   = []   # indices to remove
        rewrites  = []   # [reader_index, new_opcode, new_operands] triples

        writers.each do |slot, writer_entries|
          next unless writer_entries.size == 1
          writer_idx, writer_inst = writer_entries[0]
          next unless writer_inst.opcode == :setlocal_WC_0
          next unless writer_idx >= 1

          producer = insts[writer_idx - 1]
          next unless PURE_LITERAL_OPCODES.include?(producer.opcode)

          reader_entries = readers[slot] || []

          # Only fire when there is at least one reader; zero-reader case is
          # handled by peephole B.
          next if reader_entries.empty?

          # Schedule readers for replacement with fresh copies of the producer.
          reader_entries.each do |ridx, rinst|
            rewrites << [ridx, producer.opcode, producer.operands.dup, rinst.line]
          end

          # Drop the producer and the writer.
          to_drop << (writer_idx - 1)
          to_drop << writer_idx
        end

        return if rewrites.empty? && to_drop.empty?

        # Apply reader rewrites first (indices still valid).
        rewrites.each do |ridx, opcode, operands, line|
          insts[ridx] = IR::Instruction.new(opcode: opcode, operands: operands, line: line)
        end

        # Drop producer+writer pairs from the end to avoid index invalidation.
        to_drop.sort.reverse_each do |idx|
          line = insts[idx]&.line || function.first_lineno || 0
          function.splice_instructions!(idx..idx, [])
          log.rewrite(
            pass: :dead_stash_elim, reason: :literal_forwarded,
            file: function.path, line: line,
          )
        end
      end

      # ---------------------------------------------------------------------------
      # Peephole B: dead write-only stash
      # ---------------------------------------------------------------------------
      def peephole_b_dead_write_only_stash(function, log)
        insts = function.instructions

        # Re-scan after peephole A may have mutated insts.
        writers = Hash.new { |h, k| h[k] = [] }
        readers = Hash.new { |h, k| h[k] = [] }
        insts.each_with_index do |inst, i|
          case inst.opcode
          when :setlocal_WC_0
            writers[inst.operands[0]] << [i, inst]
          when :setlocal
            writers[inst.operands[0]] << [i, inst] if inst.operands[1] == 0
          when :getlocal_WC_0
            readers[inst.operands[0]] << [i, inst]
          when :getlocal
            readers[inst.operands[0]] << [i, inst] if inst.operands[1] == 0
          end
        end

        to_drop = []

        writers.each do |slot, writer_entries|
          next unless writer_entries.size == 1
          writer_idx, writer_inst = writer_entries[0]
          next unless writer_inst.opcode == :setlocal_WC_0
          next unless (readers[slot] || []).empty?
          next unless writer_idx >= 1

          producer = insts[writer_idx - 1]
          next unless PURE_PRODUCER_OPCODES.include?(producer.opcode)

          to_drop << (writer_idx - 1)
          to_drop << writer_idx
        end

        return if to_drop.empty?

        to_drop.sort.reverse_each do |idx|
          line = insts[idx]&.line || function.first_lineno || 0
          function.splice_instructions!(idx..idx, [])
          log.rewrite(
            pass: :dead_stash_elim, reason: :dead_stash_eliminated,
            file: function.path, line: line,
          )
        end
      end

      # ---------------------------------------------------------------------------
      # Peephole C: adjacent pure-push + pop
      # ---------------------------------------------------------------------------
      def peephole_c_pure_push_pop(function, log)
        insts = function.instructions
        candidates = []
        i = 0
        while i < insts.size - 1
          a = insts[i]
          b = insts[i + 1]
          if PURE_PRODUCER_OPCODES.include?(a.opcode) && b.opcode == :pop
            candidates << i
            i += 2
          else
            i += 1
          end
        end

        return if candidates.empty?

        candidates.reverse_each do |idx|
          line = insts[idx]&.line || function.first_lineno || 0
          function.splice_instructions!(idx..idx + 1, [])
          log.rewrite(
            pass: :dead_stash_elim, reason: :dead_push_pop_eliminated,
            file: function.path, line: line,
          )
        end
      end

      # ---------------------------------------------------------------------------
      # Existing peephole: adjacent setlocal X; getlocal X with no other refs
      # ---------------------------------------------------------------------------
      def peephole_adjacent_stash(function, log)
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
