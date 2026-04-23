# frozen_string_literal: true

module Optimize
  module IR
    # One YARV instruction after decoding. Operands are Ruby values,
    # not object-table indices — the codec resolves indices on
    # decode and re-interns them on encode.
    #
    # Fields:
    #   opcode   - Symbol, e.g. :putobject, :leave
    #   operands - Array of decoded operand values. For TS_VALUE/TS_ID operands,
    #              these are object-table indices (not resolved Ruby objects) to
    #              enable byte-identical round-trip. For TS_ISEQ, the iseq-list
    #              index. For TS_CALLDATA, no entry is stored. For TS_OFFSET,
    #              the raw slot-count offset. For TS_LINDEX/TS_NUM/TS_ISE/etc.,
    #              the raw index/count.
    #   line     - Integer source line number (from insns_info; nil if absent)
    Instruction = Struct.new(:opcode, :operands, :line, keyword_init: true) do
      def to_s
        "#{opcode} #{operands.inspect}"
      end

      # Use object identity for Hash keys and Set membership.
      # IR instructions must be compared by identity (not by value) because the
      # same logical opcode+operands combination can appear at multiple positions
      # in a single iseq. Value-based equality would cause Hash collisions and
      # incorrect slot lookups in inst_to_slot_map / catch_table / line_info.
      def hash
        object_id.hash
      end

      def eql?(other)
        equal?(other)
      end
    end
  end
end
