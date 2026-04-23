# frozen_string_literal: true
require "optimize/ir/catch_entry"

module Optimize
  module Codec
    # Decode/encode a single iseq's catch table.
    #
    # The on-disk format uses start/end/cont positions expressed as
    # YARV-slot offsets into the instruction stream. IR expresses them
    # as IR::Instruction references. The caller provides a position <=>
    # instruction mapping since the stream's slot layout is owned by
    # InstructionStream.
    #
    # Binary format per entry (6 small_values, from ibf-format.md §4.4):
    #   iseq_index  — iseq-list index of handler iseq (0xFFFFFFFF = none)
    #   type        — rb_catch_type enum value
    #   start       — YARV slot index (start of guarded range)
    #   end         — YARV slot index (end of guarded range, exclusive)
    #   cont        — YARV slot index (continuation point)
    #   sp          — stack pointer (depth) at catch point
    module CatchTable
      # rb_catch_type enum values. The C enum is defined as INT2FIX(N), i.e. the raw
      # stored value is (N << 1) | 1 — a Ruby Fixnum tag. So:
      #   CATCH_TYPE_RESCUE = INT2FIX(1) = 3
      #   CATCH_TYPE_ENSURE = INT2FIX(2) = 5
      #   CATCH_TYPE_RETRY  = INT2FIX(3) = 7
      #   CATCH_TYPE_BREAK  = INT2FIX(4) = 9
      #   CATCH_TYPE_REDO   = INT2FIX(5) = 11
      #   CATCH_TYPE_NEXT   = INT2FIX(6) = 13
      # (Verified empirically against Ruby 4.0.2 binary output.)
      TYPE_TO_SYM = {
        3  => :rescue,
        5  => :ensure,
        7  => :retry,
        9  => :break,
        11 => :redo,
        13 => :next,
      }.freeze
      SYM_TO_TYPE = TYPE_TO_SYM.invert.freeze

      # Sentinel for "no associated iseq". CRuby stores -1 as a small_value,
      # which decodes to the max uint64 (0xFFFFFFFFFFFFFFFF = 2^64-1).
      NO_ISEQ = 0xFFFFFFFFFFFFFFFF

      module_function

      # Decode catch table entries from +reader+.
      #
      # @param reader      [BinaryReader] positioned at the start of the catch table
      # @param count       [Integer]      number of entries
      # @param slot_to_inst [Hash{Integer=>IR::Instruction}] YARV slot → instruction
      # @return [Array<IR::CatchEntry>]
      def decode(reader, count, slot_to_inst)
        Array.new(count) do
          iseq_index  = reader.read_small_value
          type_num    = reader.read_small_value
          start_pos   = reader.read_small_value
          end_pos     = reader.read_small_value
          cont_pos    = reader.read_small_value
          stack_depth = reader.read_small_value

          # Normalize the iseq_index sentinel. CRuby writes -1 as uint64 max.
          iseq_index = nil if iseq_index == NO_ISEQ

          type_sym = TYPE_TO_SYM.fetch(type_num) do
            raise MalformedBinary, "unknown catch type #{type_num}"
          end

          start_inst = slot_to_inst[start_pos] or
            raise MalformedBinary, "catch table start position #{start_pos} does not align with any instruction"
          end_inst   = slot_to_inst[end_pos] or
            raise MalformedBinary, "catch table end position #{end_pos} does not align with any instruction"
          # cont_pos is always a real slot (never a sentinel); resolve it.
          # When cont_pos == 0 it points to the first instruction of the iseq.
          cont_inst = slot_to_inst[cont_pos] or
            raise MalformedBinary, "catch table cont position #{cont_pos} does not align with any instruction"

          IR::CatchEntry.new(
            type:        type_sym,
            iseq_index:  iseq_index,
            start_inst:  start_inst,
            end_inst:    end_inst,
            cont_inst:   cont_inst,
            stack_depth: stack_depth,
          )
        end
      end

      # Encode catch table entries into +writer+.
      #
      # Entries where any non-nil instruction reference (start_inst, end_inst, cont_inst)
      # is missing from +inst_to_slot+ (dangling ref — the instruction was deleted) are
      # silently dropped from the output.
      #
      # @param writer       [BinaryWriter]
      # @param entries      [Array<IR::CatchEntry>]
      # @param inst_to_slot [Hash{IR::Instruction=>Integer}] instruction → YARV slot
      def encode(writer, entries, inst_to_slot)
        live_entries = entries.select do |e|
          inst_to_slot.key?(e.start_inst) &&
            inst_to_slot.key?(e.end_inst) &&
            (e.cont_inst.nil? || inst_to_slot.key?(e.cont_inst))
        end
        live_entries.each do |e|
          writer.write_small_value(e.iseq_index.nil? ? NO_ISEQ : e.iseq_index)
          writer.write_small_value(SYM_TO_TYPE.fetch(e.type))
          writer.write_small_value(inst_to_slot.fetch(e.start_inst))
          writer.write_small_value(inst_to_slot.fetch(e.end_inst))
          writer.write_small_value(inst_to_slot.fetch(e.cont_inst))
          writer.write_small_value(e.stack_depth)
        end
      end
    end
  end
end
