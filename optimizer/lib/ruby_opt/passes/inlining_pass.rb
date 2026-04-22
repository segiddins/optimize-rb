# frozen_string_literal: true
require "ruby_opt/pass"
require "ruby_opt/ir/call_data"
require "ruby_opt/ir/instruction"
require "ruby_opt/ir/cfg"
require "ruby_opt/codec/local_table"

module RubyOpt
  module Passes
    # v1: inline zero-arg FCALLs to constant-body callees. See
    # docs/superpowers/specs/2026-04-21-pass-inlining-v1-design.md.
    class InliningPass < RubyOpt::Pass
      INLINE_BUDGET = 8  # max callee instructions INCLUDING the trailing leave

      SEND_OPCODES = %i[
        send opt_send_without_block
        invokesuper invokesuperforward invokeblock
        opt_str_uminus opt_duparray_send opt_newarray_send
      ].freeze

      CONTROL_FLOW_OPCODES = (IR::CFG::BRANCH_OPCODES + IR::CFG::JUMP_OPCODES + %i[opt_case_dispatch]).freeze

      # Single-instruction arg-push opcodes v2 accepts for the one-arg shape.
      ARG_PUSH_OPCODES = %i[
        putobject putnil putstring
        putobject_INT2FIX_0_ putobject_INT2FIX_1_
        getlocal_WC_0
      ].freeze

      # VM_ENV_DATA_SIZE: the last-appended slot's LINDEX is always 3.
      NEW_SLOT_LINDEX = 3

      def name = :inlining

      def apply(function, type_env:, log:, object_table: nil, callee_map: {}, **_extras)
        _ = type_env
        return unless object_table
        insts = function.instructions
        return unless insts

        loop do
          changed = false
          i = 0
          while i < insts.size
            b = insts[i]
            if b.opcode == :opt_send_without_block
              if try_inline(function, i, callee_map, object_table, log)
                changed = true
                insts = function.instructions
                # Do not step back; v1 disallows nested calls in the callee,
                # so the spliced region cannot contain new inline candidates.
                next
              end
            end
            i += 1
          end
          break unless changed
        end
      end

      private

      # Returns true if an inline happened (splice performed).
      def try_inline(function, send_idx, callee_map, object_table, log)
        insts = function.instructions
        send_inst = insts[send_idx]
        cd = send_inst.operands[0]
        line = send_inst.line || function.first_lineno

        return false unless cd.is_a?(IR::CallData)

        mid = cd.mid_symbol(object_table)
        callee = callee_map[mid]
        unless callee
          log.skip(pass: :inlining, reason: :callee_unresolved,
                   file: function.path, line: line)
          return false
        end

        reason = disqualify_callee(callee)
        if reason
          log.skip(pass: :inlining, reason: reason,
                   file: function.path, line: line)
          return false
        end

        case cd.argc
        when 0 then try_inline_zero_arg(function, send_idx, cd, callee, log, line)
        when 1 then try_inline_one_arg(function, send_idx, cd, callee, log, line)
        else
          log.skip(pass: :inlining, reason: :unsupported_call_shape,
                   file: function.path, line: line)
          false
        end
      end

      def try_inline_zero_arg(function, send_idx, cd, callee, log, line)
        insts = function.instructions
        unless cd.fcall? && cd.args_simple? && cd.kwlen.zero? &&
               !cd.blockarg? && !cd.has_splat? &&
               send_idx >= 1 && insts[send_idx - 1].opcode == :putself
          log.skip(pass: :inlining, reason: :unsupported_call_shape,
                   file: function.path, line: line)
          return false
        end
        put_self_idx = send_idx - 1
        body = callee.instructions[0..-2]
        function.splice_instructions!(put_self_idx..(put_self_idx + 1), body)
        log.skip(pass: :inlining, reason: :inlined,
                 file: function.path, line: line)
        true
      end

      # The IR stores raw YARV EP offsets:
      #   LINDEX = VM_ENV_DATA_SIZE (3) + (local_table_size - 1 - table_index)
      # Two invariants drive this method:
      #   - The last-appended slot (what `grow!` returns) always has LINDEX 3,
      #     regardless of the new size. So the callee's `getlocal_WC_0 3`
      #     arg-read lands at the right LINDEX post-splice with no rewrite.
      #   - Growing local_table_size by 1 shifts every pre-existing level-0
      #     LINDEX up by 1. Level-1 ops reference the outer EP and are
      #     untouched. The loop below enforces that.
      # Example, caller going from size 1 → 2: old slot 0 moves from LINDEX 3
      # to LINDEX 4; new slot (table index 1) gets LINDEX 3.
      def try_inline_one_arg(function, send_idx, cd, callee, log, line)
        insts = function.instructions
        unless cd.fcall? && cd.args_simple? && cd.kwlen.zero? &&
               !cd.blockarg? && !cd.has_splat? && send_idx >= 2 &&
               insts[send_idx - 2].opcode == :putself &&
               ARG_PUSH_OPCODES.include?(insts[send_idx - 1].opcode)
          log.skip(pass: :inlining, reason: :unsupported_call_shape,
                   file: function.path, line: line)
          return false
        end

        # 1. The callee's single local-table entry is the arg's Symbol
        #    object-table index. Reuse it as the new caller slot's name.
        callee_local_idx = Codec::LocalTable.decode(
          callee.misc[:local_table_raw] || "".b,
          callee.misc[:local_table_size] || 0,
        ).first
        if callee_local_idx.nil?
          log.skip(pass: :inlining, reason: :callee_local_table_unreadable,
                   file: function.path, line: line)
          return false
        end

        # 2. Grow the caller's local_table. Every existing level-0 LINDEX
        #    must shift by +1 since local_table_size grew.
        Codec::LocalTable.grow!(function, callee_local_idx)

        # 3. Shift every existing caller level-0 LINDEX by +1.
        function.instructions.each do |inst|
          case inst.opcode
          when :getlocal_WC_0, :setlocal_WC_0
            inst.operands[0] = inst.operands[0] + 1
          when :getlocal, :setlocal
            if inst.operands[1] == 0
              inst.operands[0] = inst.operands[0] + 1
            end
          end
        end

        # 4. Build replacement. Re-read arg_push AFTER the shift so
        #    a getlocal_WC_0 arg push reflects its new LINDEX.
        insts    = function.instructions
        arg_push = insts[send_idx - 1]
        setlocal = IR::Instruction.new(
          opcode: :setlocal_WC_0, operands: [NEW_SLOT_LINDEX],
          line: arg_push.line || line,
        )
        body = callee.instructions[0..-2]
        replacement = [arg_push, setlocal, *body]
        function.splice_instructions!((send_idx - 2)..send_idx, replacement)

        log.skip(pass: :inlining, reason: :inlined,
                 file: function.path, line: line)
        true
      end

      def disqualify_callee(callee)
        as = callee.arg_spec || {}
        # v2: lead_num may be 0 or 1. Anything else (2+) still rejects as args.
        return :callee_has_args if (as[:lead_num] || 0) > 1
        return :callee_has_args if (as[:opt_num]  || 0).positive?
        return :callee_has_args if (as[:post_num] || 0).positive?
        return :callee_has_args if as[:has_rest]
        return :callee_has_args if as[:has_block]
        return :callee_has_args if as[:has_kw]
        return :callee_has_args if as[:has_kwrest]

        lt_size = (callee.misc && callee.misc[:local_table_size]) || 0
        return :callee_multi_local if lt_size > 1
        if (as[:lead_num] || 0) == 1 && lt_size != 1
          return :callee_arg_local_mismatch
        end

        return :callee_has_catch if callee.catch_entries && !callee.catch_entries.empty?

        insts = callee.instructions || []
        return :callee_empty if insts.empty?
        return :callee_over_budget if insts.size > INLINE_BUDGET
        return :callee_no_trailing_leave unless insts.last.opcode == :leave

        body = insts[0..-2]
        body.each do |inst|
          return :callee_has_branches if CONTROL_FLOW_OPCODES.include?(inst.opcode)
          return :callee_makes_call   if SEND_OPCODES.include?(inst.opcode)
          return :callee_has_leave_midway if inst.opcode == :leave
          return :callee_has_throw if inst.opcode == :throw
          case inst.opcode
          when :setlocal, :setlocal_WC_0, :setlocal_WC_1
            return :callee_writes_local
          when :getlocal_WC_1
            return :callee_reads_outer_scope
          when :getlocal, :getlocal_WC_0
            idx = inst.operands[0]
            # IR preserves YARV's raw EP offset:
            #   LINDEX = VM_ENV_DATA_SIZE (3) + (local_table_size - 1 - table_index)
            # For lt_size == 1, the sole local (arg at table idx 0) has LINDEX 3.
            return :callee_reads_unknown_slot unless idx == 3
          end
        end
        nil
      end
    end
  end
end
