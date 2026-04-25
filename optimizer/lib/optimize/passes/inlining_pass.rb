# frozen_string_literal: true
require "optimize/pass"
require "optimize/ir/call_data"
require "optimize/ir/instruction"
require "optimize/ir/cfg"
require "optimize/ir/slot_type_table"
require "optimize/codec/local_table"

module Optimize
  module Passes
    # v1: inline zero-arg FCALLs to constant-body callees. See
    # docs/superpowers/specs/2026-04-21-pass-inlining-v1-design.md.
    class InliningPass < Optimize::Pass
      INLINE_BUDGET = 16 # max callee instructions INCLUDING the trailing leave

      SEND_OPCODES = %i[
        send opt_send_without_block
        invokesuper invokesuperforward invokeblock
        opt_str_uminus opt_duparray_send opt_newarray_send
      ].freeze

      CONTROL_FLOW_OPCODES = (IR::CFG::BRANCH_OPCODES + IR::CFG::JUMP_OPCODES + %i[opt_case_dispatch]).freeze

      # Opcodes that prevent block inlining. Branches are forbidden for the
      # same reason callee branches are: a straight-line splice can't preserve
      # branch targets across index shifts. Escape-like opcodes (throw, break,
      # next, redo) would change meaning after splicing out of the block frame.
      BLOCK_FORBIDDEN = (CONTROL_FLOW_OPCODES + %i[
        throw break next redo
        invokesuper invokesuperforward
        getblockparam getblockparamproxy
        definemethod definesmethod defineclass
        once
      ]).freeze

      # Single-instruction arg-push opcodes v2 accepts for the one-arg shape.
      ARG_PUSH_OPCODES = %i[
        putobject putnil putstring
        putobject_INT2FIX_0_ putobject_INT2FIX_1_
        getlocal_WC_0
      ].freeze

      # VM_ENV_DATA_SIZE: the last-appended slot's LINDEX is always 3.
      NEW_SLOT_LINDEX = 3

      def name = :inlining

      def one_shot?
        true
      end

      def apply(function, type_env:, log:, object_table: nil, callee_map: {}, slot_type_map: {}, **_extras)
        _ = type_env
        return unless object_table
        slot_table = slot_type_map[function]
        insts = function.instructions
        return unless insts

        loop do
          changed = false
          i = 0
          while i < insts.size
            b = insts[i]
            if b.opcode == :opt_send_without_block
              cd = b.operands[0]
              if cd.is_a?(IR::CallData) && cd.fcall?
                if try_inline(function, i, callee_map, object_table, log)
                  changed = true
                  insts = function.instructions
                  next
                end
              elsif slot_table
                if try_inline_opt_send(function, i, callee_map, object_table, log, slot_table)
                  changed = true
                  insts = function.instructions
                  next
                end
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
        body = dup_body(callee.instructions, 0..-2)
        function.splice_instructions!(put_self_idx..(put_self_idx + 1), body)
        log.rewrite(pass: :inlining, reason: :inlined,
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
        Codec::LocalTable.shift_level0_lindex!(function, by: 1)

        # 4. Build replacement. Re-read arg_push AFTER the shift so
        #    a getlocal_WC_0 arg push reflects its new LINDEX.
        insts    = function.instructions
        arg_push = insts[send_idx - 1]
        setlocal = IR::Instruction.new(
          opcode: :setlocal_WC_0, operands: [NEW_SLOT_LINDEX],
          line: arg_push.line || line,
        )
        body = dup_body(callee.instructions, 0..-2)
        replacement = [arg_push, setlocal, *body]
        function.splice_instructions!((send_idx - 2)..send_idx, replacement)

        log.rewrite(pass: :inlining, reason: :inlined,
                    file: function.path, line: line)
        true
      end

      def try_inline_opt_send(function, send_idx, callee_map, object_table, log, slot_table)
        insts = function.instructions
        send_inst = insts[send_idx]
        cd = send_inst.operands[0]
        line = send_inst.line || function.first_lineno
        return false unless cd.is_a?(IR::CallData)
        return false unless cd.argc >= 1
        return false unless cd.args_simple? && cd.kwlen.zero? && !cd.blockarg? && !cd.has_splat?

        argc = cd.argc
        return false if send_idx < argc + 1

        recv_inst = insts[send_idx - argc - 1]
        slot, level = decode_getlocal(recv_inst, slot_table)
        return false unless slot

        # Every arg push must be a single-instruction producer.
        (0...argc).each do |k|
          return false unless ARG_PUSH_OPCODES.include?(insts[send_idx - argc + k].opcode)
        end

        type = slot_table.lookup(slot, level)
        return false unless type

        mid = cd.mid_symbol(object_table)
        callee = callee_map[[type, mid]]
        unless callee
          log.skip(pass: :inlining, reason: :callee_unresolved,
                   file: function.path, line: line)
          return false
        end

        reason = disqualify_callee_for_opt_send(callee, argc)
        if reason
          log.skip(pass: :inlining, reason: reason, file: function.path, line: line)
          return false
        end

        body = dup_body(callee.instructions, 0..-2)
        body_uses_self = body.any? { |inst| inst.opcode == :putself }

        callee_arg_obj_indices = Codec::LocalTable.decode(
          callee.misc[:local_table_raw] || "".b,
          callee.misc[:local_table_size] || 0,
        )
        if callee_arg_obj_indices.size != argc
          log.skip(pass: :inlining, reason: :callee_local_table_unreadable,
                   file: function.path, line: line)
          return false
        end

        # Stash layout after N arg-slots (+ optional self-slot) are appended:
        #   LINDEX 3       holds argN (last-pushed, top of stack)
        #   LINDEX 4       holds arg(N-1)
        #   …
        #   LINDEX N+2     holds arg1
        #   LINDEX N+3     holds self  (with-self only)
        # This matches the callee's own arg LINDEXes (which run N+2..3 for
        # lt_size=N), so callee body getlocals need no rewrite. Only
        # putself is replaced with a read of the self-stash.
        if body_uses_self
          grow_count = argc + 1
          (0...grow_count).each do |k|
            Codec::LocalTable.grow!(function, callee_arg_obj_indices[k % argc])
          end
          Codec::LocalTable.shift_level0_lindex!(function, by: grow_count)
          slot_table.refresh_local_table_size!(function.misc[:local_table_size] || 0)

          self_stash_lindex = NEW_SLOT_LINDEX + argc # argc + 3

          rewritten_body = body.map do |inst|
            if inst.opcode == :putself
              IR::Instruction.new(
                opcode: :getlocal_WC_0,
                operands: [self_stash_lindex],
                line: inst.line,
              )
            else
              inst
            end
          end

          insts_now = function.instructions
          recv_in = insts_now[send_idx - argc - 1]
          arg_pushes = (0...argc).map { |k| insts_now[send_idx - argc + k] }
          # Pop args off the stack in reverse: argN → LINDEX 3, ..., arg1 → LINDEX argc+2.
          consume_args = (0...argc).map do |k|
            IR::Instruction.new(
              opcode: :setlocal_WC_0,
              operands: [NEW_SLOT_LINDEX + k],
              line: arg_pushes.last.line || line,
            )
          end
          consume_recv = IR::Instruction.new(
            opcode: :setlocal_WC_0,
            operands: [self_stash_lindex],
            line: recv_in.line || line,
          )
          replacement = [recv_in, *arg_pushes, *consume_args, consume_recv, *rewritten_body]
          function.splice_instructions!((send_idx - argc - 1)..send_idx, replacement)
        else
          argc.times { |k| Codec::LocalTable.grow!(function, callee_arg_obj_indices[k]) }
          Codec::LocalTable.shift_level0_lindex!(function, by: argc)
          slot_table.refresh_local_table_size!(function.misc[:local_table_size] || 0)

          insts_now = function.instructions
          arg_pushes = (0...argc).map { |k| insts_now[send_idx - argc + k] }
          consume_args = (0...argc).map do |k|
            IR::Instruction.new(
              opcode: :setlocal_WC_0,
              operands: [NEW_SLOT_LINDEX + k],
              line: arg_pushes.last.line || line,
            )
          end
          # Drop the receiver producer; its value is unused (no-self body).
          replacement = [*arg_pushes, *consume_args, *body]
          function.splice_instructions!((send_idx - argc - 1)..send_idx, replacement)
        end

        log.rewrite(pass: :inlining, reason: :inlined, file: function.path, line: line)
        true
      end

      def decode_getlocal(inst, slot_table)
        case inst.opcode
        when :getlocal_WC_0
          size = lt_size_at_level(slot_table, 0)
          return [nil, nil] unless size
          [IR::SlotTypeTable.lindex_to_slot(inst.operands[0], size), 0]
        when :getlocal_WC_1
          size = lt_size_at_level(slot_table, 1)
          return [nil, nil] unless size
          [IR::SlotTypeTable.lindex_to_slot(inst.operands[0], size), 1]
        when :getlocal
          level = inst.operands[1]
          size = lt_size_at_level(slot_table, level)
          return [nil, nil] unless size
          [IR::SlotTypeTable.lindex_to_slot(inst.operands[0], size), level]
        else
          [nil, nil]
        end
      end

      def lt_size_at_level(slot_table, level)
        return nil unless slot_table
        slot_table.local_table_size_at(level)
      end

      # Like #disqualify_callee but permits nested plain sends
      # (needed for the OPT_SEND receiver-typed inlining path). Forbidden:
      # branches, catch tables, block setup, ivar ops, mid-body leaves,
      # throw, and block-carrying sends.
      def disqualify_callee_for_opt_send(callee, argc = 1)
        lt_size = (callee.misc && callee.misc[:local_table_size]) || 0
        return :callee_multi_local if lt_size > argc
        return :callee_arg_local_mismatch if lt_size < argc
        return :callee_has_catch if callee.catch_entries && !callee.catch_entries.empty?
        insts = callee.instructions || []
        return :callee_empty if insts.empty?
        return :callee_over_budget if insts.size > INLINE_BUDGET
        return :callee_no_trailing_leave unless insts.last.opcode == :leave

        body = insts[0..-2]
        body.each do |inst|
          return :callee_has_branches    if CONTROL_FLOW_OPCODES.include?(inst.opcode)
          return :callee_has_leave_midway if inst.opcode == :leave
          return :callee_has_throw       if inst.opcode == :throw
          return :callee_uses_ivar       if inst.opcode == :getinstancevariable
          return :callee_uses_ivar       if inst.opcode == :setinstancevariable
          case inst.opcode
          when :invokeblock, :invokesuper, :invokesuperforward, :getblockparam
            return :callee_uses_block
          when :opt_send_without_block, :send
            cd = inst.operands[0]
            if cd.respond_to?(:blockarg?) && cd.blockarg?
              return :callee_send_has_block
            end
            if cd.respond_to?(:flag) && (cd.flag & 0x20) != 0 # FLAG_BLOCKISEQ
              return :callee_send_has_block
            end
          end
        end
        nil
      end

      def disqualify_callee_for_send_with_block(callee)
        return :callee_has_catch if callee.catch_entries && !callee.catch_entries.empty?
        insts = callee.instructions || []
        return :callee_empty if insts.empty?
        return :callee_over_budget if insts.size > INLINE_BUDGET

        # Check super/block-param across all instructions first (the codec
        # may omit a trailing :leave for methods ending in invokesuper).
        insts.each do |inst|
          case inst.opcode
          when :invokesuper, :invokesuperforward
            return :callee_uses_super
          when :getblockparam, :getblockparamproxy
            return :callee_uses_block_param
          end
        end

        return :callee_no_trailing_leave unless insts.last.opcode == :leave

        body = insts[0..-2]
        body.each do |inst|
          return :callee_has_branches     if CONTROL_FLOW_OPCODES.include?(inst.opcode)
          return :callee_has_leave_midway if inst.opcode == :leave
          return :callee_has_throw        if inst.opcode == :throw
          return :callee_uses_ivar        if inst.opcode == :getinstancevariable
          return :callee_uses_ivar        if inst.opcode == :setinstancevariable
          case inst.opcode
          when :opt_send_without_block
            # A nested plain FCALL is allowed; v5 doesn't recurse into it.
            nil
          when :send
            cd = inst.operands[0]
            blk_idx = inst.operands[1]
            if blk_idx.is_a?(Integer) && blk_idx >= 0
              return :callee_send_has_block
            end
            if cd.respond_to?(:blockarg?) && cd.blockarg?
              return :callee_send_has_block
            end
          end
        end
        nil
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

      def disqualify_block(block)
        return :block_has_catch_table if block.catch_entries && !block.catch_entries.empty?
        insts = block.instructions || []
        return :block_empty if insts.empty?
        return :block_no_trailing_leave unless insts.last.opcode == :leave
        body = insts[0..-2]
        body.each do |inst|
          return :block_nested_leave if inst.opcode == :leave
          return :block_escapes if BLOCK_FORBIDDEN.include?(inst.opcode)
          case inst.opcode
          when :getlocal_WC_1
            return :block_captures_level1
          when :getlocal, :setlocal
            return :block_captures_level1 if inst.operands[1] && inst.operands[1] != 0
          when :send, :opt_send_without_block
            cd = inst.operands[0]
            if cd.respond_to?(:flag) && (cd.flag & 0x20) != 0
              return :block_escapes
            end
          end
        end
        nil
      end

      # Deep-copy a slice of source_insts so that the returned Array holds
      # freshly allocated Instruction structs with independent operand arrays.
      # Without this, the slice shares struct references with the callee's
      # canonical instruction list; subsequent shift-step mutations during a
      # second inline corrupt the callee's instructions in place.
      def dup_body(source_insts, range)
        source_insts[range].map do |i|
          IR::Instruction.new(opcode: i.opcode, operands: i.operands.dup, line: i.line)
        end
      end
    end
  end
end
