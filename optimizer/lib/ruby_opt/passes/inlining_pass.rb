# frozen_string_literal: true
require "ruby_opt/pass"
require "ruby_opt/ir/call_data"
require "ruby_opt/ir/cfg"

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

        # 1. Resolve callee by mid symbol. Do this first so we can report
        #    callee-level reasons when the call shape is otherwise uninlinable.
        mid = cd.mid_symbol(object_table)
        callee = callee_map[mid]
        unless callee
          log.skip(pass: :inlining, reason: :callee_unresolved,
                   file: function.path, line: line)
          return false
        end

        # 2. Callee shape: no args, no locals, no catch, no branches,
        #    no nested sends, ends in `leave`, under budget.
        reason = disqualify_callee(callee)
        if reason
          log.skip(pass: :inlining, reason: reason,
                   file: function.path, line: line)
          return false
        end

        # 3. Call-site shape: FCALL, ARGS_SIMPLE, zero-arg, no kwargs, no splat,
        #    no blockarg. Also requires an immediately-preceding `putself`.
        unless cd.fcall? && cd.args_simple? && cd.argc.zero? &&
               cd.kwlen.zero? && !cd.blockarg? && !cd.has_splat? &&
               send_idx >= 1 && insts[send_idx - 1].opcode == :putself
          log.skip(pass: :inlining, reason: :unsupported_call_shape,
                   file: function.path, line: line)
          return false
        end

        # Transformation. Splice [putself, opt_send] -> callee body minus trailing leave.
        put_self_idx = send_idx - 1
        body = callee.instructions[0..-2] # drop trailing `leave`
        function.splice_instructions!(put_self_idx..(put_self_idx + 1), body)

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
          # v2: slot 1 is the sole arg; anything else means a local we can't yet handle.
          case inst.opcode
          when :setlocal, :setlocal_WC_0, :setlocal_WC_1
            return :callee_writes_local
          when :getlocal_WC_1
            return :callee_reads_outer_scope
          when :getlocal, :getlocal_WC_0
            idx = inst.operands[0]
            # Slot 1 is the single arg. Anything else rejects.
            return :callee_reads_unknown_slot unless idx == 1
          end
        end
        nil
      end
    end
  end
end
