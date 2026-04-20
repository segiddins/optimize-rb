# frozen_string_literal: true
require "ruby_opt/pass"
require "ruby_opt/passes/literal_value"

module RubyOpt
  module Passes
    class ConstFoldPass < RubyOpt::Pass
      ARITH_OPS = {
        opt_plus:  :+,
        opt_minus: :-,
        opt_mult:  :*,
        opt_div:   :/,
        opt_mod:   :%,
      }.freeze

      def apply(function, type_env:, log:, object_table: nil)
        _ = type_env
        return unless object_table
        insts = function.instructions
        return unless insts

        i = 0
        while i <= insts.size - 3
          a  = insts[i]
          b  = insts[i + 1]
          op = insts[i + 2]
          new_inst = try_fold_arith(a, b, op, function, log, object_table)
          if new_inst
            # Safe: the two removed instructions are `putobject`-family literal
            # producers — neither is ever a branch target, so absolute-index
            # offsets in the (unshifted) earlier instructions remain valid.
            insts[i, 3] = [new_inst]
            # Step back so we recheck at `i-1` in case the previous
            # instruction is now the first of a new foldable triple.
            i = i - 1 if i.positive?
          else
            i += 1
          end
        end
      end

      def name = :const_fold

      private

      def try_fold_arith(a, b, op, function, log, object_table)
        sym = ARITH_OPS[op.opcode]
        return nil unless sym
        av = LiteralValue.read(a, object_table: object_table)
        bv = LiteralValue.read(b, object_table: object_table)
        return nil unless av.is_a?(Integer) && bv.is_a?(Integer)
        result = av.public_send(sym, bv)
        LiteralValue.emit(result, line: a.line, object_table: object_table)
      rescue ZeroDivisionError
        nil # would raise at runtime — leave the triple alone
      end
    end
  end
end
