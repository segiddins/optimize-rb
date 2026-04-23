# frozen_string_literal: true

module Optimize
  module IR
    # One entry in an iseq's line-info table.
    #
    #   inst         — the IR::Instruction whose start slot is at or before this entry's
    #                  YARV slot position. For most entries this is the instruction annotated
    #                  by this line entry. For "adjust" entries (added by CRuby for continuation
    #                  points after block calls), the slot may fall inside an instruction's
    #                  operand range — in that case inst is the containing instruction and
    #                  slot_offset records the delta from that instruction's start slot.
    #   slot_offset  — delta from inst's YARV start slot to the actual insns_info slot
    #                  position. 0 for the vast majority of entries; >0 only for adjust-
    #                  style entries that point to a mid-instruction YARV slot.
    #   line_no      — source line number (1-based), absolute (not delta-encoded)
    #   node_id      — parser node id (opaque integer; preserved on round-trip)
    #   events       — flags bitmap for tracepoint events (RUBY_EVENT_LINE, etc.)
    LineEntry = Struct.new(:inst, :slot_offset, :line_no, :node_id, :events, keyword_init: true)
  end
end
