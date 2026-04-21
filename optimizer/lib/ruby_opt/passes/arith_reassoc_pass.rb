# frozen_string_literal: true
require "set"
require "ruby_opt/pass"
require "ruby_opt/passes/literal_value"
require "ruby_opt/ir/cfg"
require "ruby_opt/ir/instruction"

module RubyOpt
  module Passes
    # Arithmetic reassociation within a basic block, driven by REASSOC_GROUPS.
    # See docs/superpowers/specs/2026-04-21-pass-arith-reassoc-v3-design.md.
    class ArithReassocPass < RubyOpt::Pass
      # Each entry describes one commutative-associative group of operators:
      #   ops:        opcode => Symbol method used to combine that op's RHS
      #               literal into the running accumulator. Insertion-ordered.
      #   identity:   neutral element for the group (0 for +, 1 for *).
      #   primary_op: opcode used to emit the single literal-carrying trailing
      #               op after a rewrite. Must be a key in `ops`.
      REASSOC_GROUPS = [
        { ops: { opt_plus: :+ }, identity: 0, primary_op: :opt_plus },
        { ops: { opt_mult: :* }, identity: 1, primary_op: :opt_mult },
      ].freeze

      # ObjectTable#intern accepts integers with bit_length < 62
      # (i.e. values in -(2^61)..(2^61)-1). Results outside this range
      # cannot be interned and must be skipped.
      INTERN_BIT_LENGTH_LIMIT = 62

      # Opcodes that each push exactly one value, pop zero, and have no
      # side effects relevant to reordering literals past them. Shared across
      # all REASSOC_GROUPS entries. Widening this list without re-examining the
      # "all entries are side-effect-free w.r.t. each other" invariant would
      # break the non-literal reordering rule used by the additive group.
      SINGLE_PUSH_OPERAND_OPCODES = (
        LiteralValue::LITERAL_OPCODES + %i[
          getlocal
          getlocal_WC_0
          getlocal_WC_1
          getinstancevariable
          getclassvariable
          getglobal
          putself
        ]
      ).freeze

      def name = :arith_reassoc

      def apply(function, type_env:, log:, object_table: nil)
        _ = type_env
        return unless object_table
        insts = function.instructions
        return unless insts

        # Outer any-rewrite fixpoint: a rewrite in one group can expose chains
        # in another group (e.g. mult folding `2 * 3 → 6` exposes a + chain
        # that plus missed on its first visit). See spec "Two-level fixpoint".
        loop do
          any_outer = false
          REASSOC_GROUPS.each do |group|
            loop do
              break unless rewrite_once(insts, function, log, object_table, group: group)
              any_outer = true
            end
          end
          break unless any_outer
        end
      end

      private

      def rewrite_once(insts, function, log, object_table, group:)
        any = false
        leader_set = Set.new(IR::CFG.compute_leaders(insts))
        i = 0
        while i < insts.size
          if group[:ops].key?(insts[i].opcode)
            chain = detect_chain(insts, i, leader_set, group: group)
            if chain && try_rewrite_chain(insts, chain, function, log, object_table, group: group)
              any = true
              i = chain[:first_idx]
              leader_set = Set.new(IR::CFG.compute_leaders(insts))
            else
              i += 1
            end
          else
            i += 1
          end
        end
        any
      end

      def detect_chain(insts, end_idx, leader_set, group:)
        prod_indices = []
        op_positions = [{ idx: end_idx, opcode: insts[end_idx].opcode }]
        j = end_idx - 1
        return nil unless j >= 0 && single_push?(insts[j])
        prod_indices.unshift(j)

        loop do
          op_j = j - 1
          prod_j = j - 2
          break if op_j < 0 || prod_j < 0
          break unless group[:ops].key?(insts[op_j].opcode)
          break unless single_push?(insts[prod_j])
          op_positions.unshift({ idx: op_j, opcode: insts[op_j].opcode })
          prod_indices.unshift(prod_j)
          j = prod_j
        end

        first_candidate = prod_indices.first - 1
        return nil if first_candidate < 0
        return nil unless single_push?(insts[first_candidate])
        prod_indices.unshift(first_candidate)

        chain_start = prod_indices.first
        breaker = nil
        (chain_start + 1..end_idx).each do |k|
          if leader_set.include?(k)
            breaker = k
            break
          end
        end
        if breaker
          new_first = prod_indices.find { |p| p >= breaker }
          return nil unless new_first
          keep_from = prod_indices.index(new_first)
          prod_indices = prod_indices[keep_from..]
          op_positions = op_positions.last(prod_indices.size - 1) if prod_indices.size >= 1
        end

        return nil if prod_indices.size < 2
        {
          first_idx: prod_indices.first,
          producer_indices: prod_indices,
          op_positions: op_positions,
          end_idx: end_idx,
        }
      end

      def single_push?(inst)
        SINGLE_PUSH_OPERAND_OPCODES.include?(inst.opcode)
      end

      def try_rewrite_chain(insts, chain, function, log, object_table, group:)
        producer_insts = chain[:producer_indices].map { |k| insts[k] }

        # Combiner for each producer is the combiner of the op immediately to
        # its left in the chain. The leftmost producer uses the primary op's
        # combiner (equivalent to being preceded by an identity-friendly op).
        primary_combiner = group[:ops].fetch(group[:primary_op])
        producer_combiners = producer_insts.each_with_index.map do |_p, k|
          if k == 0
            primary_combiner
          else
            op_opcode = chain[:op_positions][k - 1][:opcode]
            group[:ops].fetch(op_opcode)
          end
        end

        classified = producer_insts.each_with_index.map do |p, k|
          v = LiteralValue.read(p, object_table: object_table)
          is_lit = LiteralValue.literal?(p)
          { inst: p, value: v, is_literal: is_lit, combiner: producer_combiners[k] }
        end

        integer_literals = classified.select { |c| c[:is_literal] && c[:value].is_a?(Integer) }
        non_integer_literals = classified.select { |c| c[:is_literal] && !c[:value].is_a?(Integer) }
        non_literals = classified.reject { |c| c[:is_literal] }

        chain_line = insts[chain[:op_positions].first[:idx]].line || function.first_lineno

        unless non_integer_literals.empty?
          log.skip(pass: :arith_reassoc, reason: :mixed_literal_types,
                   file: function.path, line: chain_line)
          return false
        end
        if integer_literals.size < 2
          log.skip(pass: :arith_reassoc, reason: :chain_too_short,
                   file: function.path, line: chain_line)
          return false
        end

        reduced = integer_literals.inject(group[:identity]) do |acc, c|
          acc.send(c[:combiner], c[:value])
        end
        unless fits_intern_range?(reduced)
          log.skip(pass: :arith_reassoc, reason: :would_exceed_intern_range,
                   file: function.path, line: chain_line)
          return false
        end

        first_op_inst = insts[chain[:op_positions].first[:idx]]
        literal_inst = LiteralValue.emit(reduced, line: first_op_inst.line, object_table: object_table)

        replacement = build_replacement(non_literals, literal_inst, first_op_inst, group)

        range = chain[:first_idx]..chain[:end_idx]
        function.splice_instructions!(range, replacement)
        log.skip(pass: :arith_reassoc, reason: :reassociated,
                 file: function.path, line: chain_line)
        true
      end

      # Task-1 behavior: every producer in the group uses the same combiner
      # (the primary op's), so non-literal order is preserved and every
      # intermediate op is the primary op. Task 2 overrides this logic for
      # the additive group (sign-aware partition + reorder).
      def build_replacement(non_literals, literal_inst, first_op_inst, group)
        replacement = non_literals.map { |c| c[:inst] }
        replacement << literal_inst
        op_count_out = replacement.size - 1
        op_count_out.times do
          replacement << IR::Instruction.new(
            opcode: group[:primary_op],
            operands: first_op_inst.operands,
            line: first_op_inst.line,
          )
        end
        replacement
      end

      def fits_intern_range?(n)
        n.is_a?(Integer) && n.bit_length < INTERN_BIT_LENGTH_LIMIT
      end
    end
  end
end
