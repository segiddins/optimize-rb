# frozen_string_literal: true
require "set"
require "ruby_opt/pass"
require "ruby_opt/passes/literal_value"
require "ruby_opt/ir/cfg"

module RubyOpt
  module Passes
    # Arithmetic reassociation within a basic block, driven by REASSOC_OPS.
    # See docs/superpowers/specs/2026-04-20-pass-arith-reassoc-v2-design.md.
    class ArithReassocPass < RubyOpt::Pass
      # Each entry describes one commutative-associative operator:
      #   opcode:   the YARV opcode whose chains we fold
      #   identity: the neutral element for `reducer` (0 for +, 1 for *)
      #   reducer:  the Symbol method used to combine Integer literals
      REASSOC_OPS = [
        { opcode: :opt_plus, identity: 0, reducer: :+ },
      ].freeze

      # Opcodes that each push exactly one value, pop zero, and have no
      # side effects relevant to reordering literals past them. Shared across
      # all REASSOC_OPS entries.
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

        REASSOC_OPS.each do |op_spec|
          loop do
            break unless rewrite_once(insts, function, log, object_table, op_spec: op_spec)
          end
        end
      end

      private

      def rewrite_once(insts, function, log, object_table, op_spec:)
        any = false
        leader_set = Set.new(IR::CFG.compute_leaders(insts))
        i = 0
        while i < insts.size
          if insts[i].opcode == op_spec[:opcode]
            chain = detect_chain(insts, i, leader_set, op_spec: op_spec)
            if chain && try_rewrite_chain(insts, chain, function, log, object_table, op_spec: op_spec)
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

      def detect_chain(insts, end_idx, leader_set, op_spec:)
        prod_indices = []
        op_indices = [end_idx]
        j = end_idx - 1
        return nil unless j >= 0 && single_push?(insts[j])
        prod_indices.unshift(j)

        loop do
          op_j = j - 1
          prod_j = j - 2
          break if op_j < 0 || prod_j < 0
          break unless insts[op_j].opcode == op_spec[:opcode]
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
          op_indices: op_indices,
          end_idx: end_idx,
        }
      end

      def single_push?(inst)
        SINGLE_PUSH_OPERAND_OPCODES.include?(inst.opcode)
      end

      def try_rewrite_chain(insts, chain, function, log, object_table, op_spec:)
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

        chain_line = insts[chain[:op_indices].first].line || function.first_lineno

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

        reduced = integer_literals.inject(op_spec[:identity], op_spec[:reducer])
        first_op_inst = insts[chain[:op_indices].first]
        literal_inst = LiteralValue.emit(reduced, line: first_op_inst.line, object_table: object_table)

        replacement = non_literals.dup
        replacement << literal_inst
        op_count_out = replacement.size - 1
        original_ops = chain[:op_indices].map { |k| insts[k] }
        op_count_out.times do |k|
          replacement << original_ops[k]
        end

        range = chain[:first_idx]..chain[:end_idx]
        function.splice_instructions!(range, replacement)
        log.skip(pass: :arith_reassoc, reason: :reassociated,
                 file: function.path, line: chain_line)
        true
      end
    end
  end
end
