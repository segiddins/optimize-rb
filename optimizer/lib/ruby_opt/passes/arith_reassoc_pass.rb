# frozen_string_literal: true
require "set"
require "ruby_opt/pass"
require "ruby_opt/passes/literal_value"
require "ruby_opt/ir/cfg"

module RubyOpt
  module Passes
    # v1: literal-only opt_plus chain reassociation within a basic block.
    # See docs/superpowers/specs/2026-04-20-pass-arith-reassoc-v1-design.md.
    class ArithReassocPass < RubyOpt::Pass
      # Opcodes that each push exactly one value, pop zero, and have no
      # side effects relevant to reordering literals past them.
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

        rewrite_once(insts, function, log, object_table)
      end

      private

      def rewrite_once(insts, function, log, object_table)
        any = false
        leader_set = Set.new(IR::CFG.compute_leaders(insts))
        i = 0
        while i < insts.size
          if insts[i].opcode == :opt_plus
            chain = detect_chain(insts, i, leader_set)
            if chain && try_rewrite_chain(insts, chain, function, log, object_table)
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

      def detect_chain(insts, end_idx, leader_set)
        prod_indices = []
        op_indices = [end_idx]
        j = end_idx - 1
        return nil unless j >= 0 && single_push?(insts[j])
        prod_indices.unshift(j)

        loop do
          op_j = j - 1
          prod_j = j - 2
          break if op_j < 0 || prod_j < 0
          break unless insts[op_j].opcode == :opt_plus
          break unless single_push?(insts[prod_j])
          op_indices.unshift(op_j)
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
          op_indices = op_indices.last(prod_indices.size - 1) if prod_indices.size >= 1
        end

        return nil if prod_indices.size < 2
        {
          first_idx: prod_indices.first,
          producer_indices: prod_indices,
          opt_plus_indices: op_indices,
          end_idx: end_idx,
        }
      end

      def single_push?(inst)
        SINGLE_PUSH_OPERAND_OPCODES.include?(inst.opcode)
      end

      def try_rewrite_chain(insts, chain, function, log, object_table)
        producer_insts = chain[:producer_indices].map { |k| insts[k] }
        classified = producer_insts.map do |p|
          v = LiteralValue.read(p, object_table: object_table)
          is_lit = LiteralValue.literal?(p)
          [p, v, is_lit]
        end

        literal_values = classified.filter_map { |_, v, is_lit| v if is_lit }
        integer_literals = literal_values.select { |v| v.is_a?(Integer) }
        non_integer_literals = literal_values.reject { |v| v.is_a?(Integer) }
        non_literals = classified.reject { |_, _, is_lit| is_lit }.map(&:first)

        return false unless non_integer_literals.empty?
        return false if integer_literals.size < 2

        sum = integer_literals.inject(0, :+)
        first_opt_plus = insts[chain[:opt_plus_indices].first]
        literal_inst = LiteralValue.emit(sum, line: first_opt_plus.line, object_table: object_table)

        replacement = non_literals.dup
        replacement << literal_inst
        opt_plus_count_out = replacement.size - 1
        original_opt_pluses = chain[:opt_plus_indices].map { |k| insts[k] }
        opt_plus_count_out.times do |k|
          replacement << original_opt_pluses[k]
        end

        start = chain[:first_idx]
        length = chain[:end_idx] - chain[:first_idx] + 1
        insts[start, length] = replacement
        function.invalidate_cfg
        true
      end
    end
  end
end
