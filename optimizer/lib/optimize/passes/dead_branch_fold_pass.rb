# frozen_string_literal: true
require "optimize/pass"
require "optimize/ir/instruction"
require "optimize/passes/literal_value"

module Optimize
  module Passes
    # Peephole: fold a literal condition followed by a conditional branch.
    # Window is two instructions: `<literal producer>; branchif|branchunless|branchnil`.
    # If the branch is statically taken, collapse the pair to `jump target`.
    # If it is statically not taken, drop the pair (fall through).
    #
    # Runs after ConstFoldPass / IdentityElim so their folded results
    # (e.g. `"a" == "a"` → `putobject true`) feed this pass in a single
    # pipeline iteration.
    class DeadBranchFoldPass < Optimize::Pass
      BRANCH_OPCODES = %i[branchif branchunless branchnil].freeze

      def name = :dead_branch_fold

      def apply(function, type_env:, log:, object_table: nil, **_extras)
        _ = type_env
        return unless object_table
        insts = function.instructions
        return unless insts

        loop do
          folded_any = false
          i = 0
          while i < insts.size
            if try_fold_short_circuit(function, insts, i, object_table, log)
              folded_any = true
              i = i.positive? ? i - 1 : 0
              next
            end
            if try_fold_simple(function, insts, i, object_table, log)
              folded_any = true
              i = i.positive? ? i - 1 : 0
              next
            end
            i += 1
          end
          break unless folded_any
        end
      end

      private

      # 2-instruction window: `<literal>; branch*`.
      def try_fold_simple(function, insts, i, object_table, log)
        return false if i > insts.size - 2
        a = insts[i]
        b = insts[i + 1]
        return false unless BRANCH_OPCODES.include?(b.opcode) && LiteralValue.literal?(a)
        value = LiteralValue.read(a, object_table: object_table)
        taken = branch_taken?(b.opcode, value)
        replacement = build_replacement(b, taken, a.line)
        function.splice_instructions!(i..(i + 1), replacement)
        log.rewrite(pass: :dead_branch_fold, reason: :branch_folded,
                    file: function.path, line: (b.line || a.line || function.first_lineno))
        true
      end

      # 4-instruction window: `<literal>; dup; branch*; pop` — the short-
      # circuit shape Ruby emits for `LIT && rhs` and `LIT || rhs`. We only
      # fold the NOT-taken case here (short-circuit passes through to rhs),
      # dropping all four instructions. The TAKEN case would require
      # deleting the rhs block up to the branch target, which is CFG-shaped
      # work we're leaving to a future pass.
      def try_fold_short_circuit(function, insts, i, object_table, log)
        return false if i > insts.size - 4
        a = insts[i]
        d = insts[i + 1]
        b = insts[i + 2]
        p = insts[i + 3]
        return false unless d.opcode == :dup && p.opcode == :pop
        return false unless BRANCH_OPCODES.include?(b.opcode) && LiteralValue.literal?(a)
        value = LiteralValue.read(a, object_table: object_table)
        return false if branch_taken?(b.opcode, value) # out of scope
        function.splice_instructions!(i..(i + 3), [])
        log.rewrite(pass: :dead_branch_fold, reason: :short_circuit_folded,
                    file: function.path, line: (b.line || a.line || function.first_lineno))
        true
      end

      def branch_taken?(opcode, value)
        case opcode
        when :branchif      then !value.nil? && value != false
        when :branchunless  then value.nil? || value == false
        when :branchnil     then value.nil?
        end
      end

      def build_replacement(branch, taken, line)
        return [] unless taken
        target = branch.operands[0]
        [Optimize::IR::Instruction.new(
          opcode:   :jump,
          operands: [target],
          line:     branch.line || line,
        )]
      end
    end
  end
end
