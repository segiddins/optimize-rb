# frozen_string_literal: true
require "ruby_opt/pass"
require "ruby_opt/passes/literal_value"

module RubyOpt
  module Passes
    class ConstFoldPass < RubyOpt::Pass
      FOLDABLE_OPS = {
        opt_plus:  :+,
        opt_minus: :-,
        opt_mult:  :*,
        opt_div:   :/,
        opt_mod:   :%,
        opt_lt:    :<,
        opt_le:    :<=,
        opt_gt:    :>,
        opt_ge:    :>=,
        opt_eq:    :==,
        opt_neq:   :"!=",
      }.freeze

      def apply(function, type_env:, log:, object_table: nil)
        _ = type_env
        return unless object_table
        insts = function.instructions
        return unless insts

        # Outer fixpoint loop: defense-in-depth around the inner step-back
        # scan. The step-back already catches the common left-associative
        # chain shape (`putobject N; putobject N; opt_plus` after one fold),
        # but the outer loop makes the "fold to a fixed point" invariant
        # explicit and covers any triple-shape the step-back misses.
        # Termination: each iteration either folds (strictly decreasing
        # `insts.size` by 2) or sets `folded_any = false` and breaks.
        loop do
          folded_any = false
          i = 0
          while i <= insts.size - 3
            a  = insts[i]
            b  = insts[i + 1]
            op = insts[i + 2]
            new_inst = try_fold_triple(a, b, op, function, log, object_table)
            if new_inst
              # Safe: the two removed instructions are `putobject`-family literal
              # producers — neither is ever a branch target, so absolute-index
              # offsets in the (unshifted) earlier instructions remain valid.
              insts[i, 3] = [new_inst]
              folded_any = true
              # Step back so we recheck at `i-1` in case the previous
              # instruction is now the first of a new foldable triple.
              i = i - 1 if i.positive?
            else
              i += 1
            end
          end
          break unless folded_any
        end
      end

      def name = :const_fold

      private

      def try_fold_triple(a, b, op, function, log, object_table)
        sym = FOLDABLE_OPS[op.opcode]
        return nil unless sym
        av = LiteralValue.read(a, object_table: object_table)
        bv = LiteralValue.read(b, object_table: object_table)

        # Only fold Integer-on-Integer. A triple that LOOKS foldable but has at
        # least one non-Integer literal gets a log entry so the talk can show it.
        # A triple where one side isn't a literal at all (read -> nil) is silent —
        # it's the common "variable + literal" case.
        unless av.is_a?(Integer) && bv.is_a?(Integer)
          both_literals = LiteralValue.literal?(a) && LiteralValue.literal?(b)
          if both_literals
            log.skip(pass: :const_fold, reason: :non_integer_literal,
                     file: function.path, line: (op.line || a.line || function.first_lineno))
          end
          return nil
        end

        result = av.public_send(sym, bv)
        log.skip(pass: :const_fold, reason: :folded,
                 file: function.path, line: (op.line || a.line || function.first_lineno))
        LiteralValue.emit(result, line: a.line, object_table: object_table)
      rescue ZeroDivisionError
        log.skip(pass: :const_fold, reason: :would_raise,
                 file: function.path, line: (op.line || a.line || function.first_lineno))
        nil # would raise at runtime — leave the triple alone
      end
    end
  end
end
