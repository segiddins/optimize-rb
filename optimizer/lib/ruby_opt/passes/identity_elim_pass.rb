# frozen_string_literal: true
require "ruby_opt/pass"
require "ruby_opt/passes/literal_value"
require "ruby_opt/passes/arith_reassoc_pass"

module RubyOpt
  module Passes
    # Strip arithmetic identities: x * 1, 1 * x, x + 0, 0 + x, x - 0, x / 1.
    # See docs/superpowers/specs/2026-04-21-pass-identity-elim-design.md.
    class IdentityElimPass < RubyOpt::Pass
      IDENTITY_OPS = {
        opt_plus:  { identity: 0, sides: :either },
        opt_mult:  { identity: 1, sides: :either },
        opt_minus: { identity: 0, sides: :right  },
        opt_div:   { identity: 1, sides: :right  },
      }.freeze

      # Non-literal side must be in this whitelist. Shared with ArithReassocPass:
      # any producer with observable side effects (send, invokesuper, ...) is
      # absent here so that eliding the op never elides a side effect.
      SAFE_PRODUCER_OPCODES = ArithReassocPass::SINGLE_PUSH_OPERAND_OPCODES

      def name = :identity_elim

      def apply(function, type_env:, log:, object_table: nil)
        _ = type_env
        return unless object_table
        insts = function.instructions
        return unless insts

        loop do
          eliminated_any = false
          i = 0
          while i <= insts.size - 3
            a  = insts[i]
            b  = insts[i + 1]
            op = insts[i + 2]
            entry = IDENTITY_OPS[op.opcode]
            if entry && SAFE_PRODUCER_OPCODES.include?(a.opcode) && SAFE_PRODUCER_OPCODES.include?(b.opcode)
              keep = try_eliminate(a, b, entry, object_table)
              if keep
                function.splice_instructions!(i..(i + 2), [keep])
                log.skip(pass: :identity_elim, reason: :identity_eliminated,
                         file: function.path, line: (op.line || a.line || function.first_lineno))
                eliminated_any = true
                i = i - 1 if i.positive?
                next
              end
            end
            i += 1
          end
          break unless eliminated_any
        end
      end

      private

      def try_eliminate(a, b, entry, object_table)
        id = entry[:identity]

        if LiteralValue.literal?(b)
          bv = LiteralValue.read(b, object_table: object_table)
          return a if bv.is_a?(Integer) && bv == id
        end

        if entry[:sides] == :either && LiteralValue.literal?(a)
          av = LiteralValue.read(a, object_table: object_table)
          return b if av.is_a?(Integer) && av == id
        end

        nil
      end
    end
  end
end
