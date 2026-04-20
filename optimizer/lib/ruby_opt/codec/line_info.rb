# frozen_string_literal: true
require "ruby_opt/ir/line_entry"

module RubyOpt
  module Codec
    # Decode/encode an iseq's insns_info table.
    #
    # CRuby serializes insns_info as TWO separate data sections:
    #
    #   insns_info body (at insns_body_abs):
    #     N × (line_no, node_id, events) — each as an absolute small_value,
    #     no delta encoding on line_no.
    #
    #   insns_info positions (at insns_pos_abs):
    #     N × pos_delta — each is a delta from the previous entry's slot position,
    #     accumulated to get the absolute YARV slot index for each entry.
    #
    # This is verified against Ruby 4.0.2 binaries. The plan sketch's single-section
    # delta-encoded form does NOT match CRuby's actual output.
    #
    # References: research/cruby/ibf-format.md §4.1, empirical verification via
    # RubyVM::InstructionSequence.compile(...).to_binary inspection.
    module LineInfo
      module_function

      # Decode insns_info entries.
      #
      # @param body_reader  [BinaryReader] positioned at insns_info body section
      # @param pos_reader   [BinaryReader] positioned at insns_info positions section
      # @param size         [Integer]      number of entries
      # @param slot_to_inst [Hash{Integer=>IR::Instruction}] YARV slot → instruction start
      # @param inst_to_slot [Hash{IR::Instruction=>Integer}] instruction → YARV start slot
      #          (used to compute slot_offset for non-aligned entries)
      # @param slot_to_containing_inst [Hash{Integer=>IR::Instruction}] YARV slot →
      #          instruction that CONTAINS the slot (even if it is a mid-instruction slot).
      #          May be the same as slot_to_inst for well-aligned entries.
      # @return [Array<IR::LineEntry>]
      def decode(body_reader, pos_reader, size, slot_to_inst, slot_to_containing_inst, inst_to_slot = nil)
        return [] if size == 0

        # Read all body entries first (line_no, node_id, events — all absolute).
        bodies = Array.new(size) do
          line_no = body_reader.read_small_value
          node_id = body_reader.read_small_value
          events  = body_reader.read_small_value
          [line_no, node_id, events]
        end

        # Read all position deltas, accumulate to absolute slot positions.
        slot = 0
        slots = Array.new(size) do
          delta = pos_reader.read_small_value
          slot += delta
          slot
        end

        # Zip together and resolve slot → instruction.
        # Most entries align to an instruction start (slot_offset == 0).
        # "Adjust" entries (added by CRuby for continuation points after block calls)
        # may reference a slot inside an instruction's operand range (slot_offset > 0).
        bodies.zip(slots).map do |(line_no, node_id, events), abs_slot|
          inst = slot_to_inst[abs_slot]
          slot_offset = 0

          if inst.nil?
            # Non-aligned slot: find the containing instruction.
            inst = slot_to_containing_inst[abs_slot] or raise MalformedBinary,
              "insns_info position #{abs_slot} does not align with or fall within any instruction"
            # Compute offset from the instruction's start slot.
            if inst_to_slot
              inst_start = inst_to_slot[inst] or raise MalformedBinary,
                "insns_info: cannot find start slot for containing instruction #{inst.opcode}"
            else
              inst_start = slot_to_inst.key(inst) or raise MalformedBinary,
                "insns_info: cannot find start slot for containing instruction #{inst.opcode}"
            end
            slot_offset = abs_slot - inst_start
          end

          IR::LineEntry.new(
            inst:        inst,
            slot_offset: slot_offset,
            line_no:     line_no,
            node_id:     node_id,
            events:      events,
          )
        end
      end

      # Encode insns_info entries into the body and positions sections.
      #
      # Writes to two separate writers that will land at the correct absolute offsets.
      # Entries whose instruction is no longer in +inst_to_slot+ (dangling refs,
      # e.g. the instruction was deleted) are silently dropped from the output.
      #
      # @param body_writer  [BinaryWriter] for the body section
      # @param pos_writer   [BinaryWriter] for the positions section
      # @param entries      [Array<IR::LineEntry>]
      # @param inst_to_slot [Hash{IR::Instruction=>Integer}] instruction → YARV start slot
      def encode(body_writer, pos_writer, entries, inst_to_slot)
        prev_slot = 0
        # Drop entries whose instruction has been removed from the instruction stream.
        live_entries = entries.select { |e| inst_to_slot.key?(e.inst) }
        # Sort by target slot so position deltas are non-negative even when a
        # pass has reordered instructions (e.g. ArithReassocPass). Use the
        # original array index as a stable secondary key to preserve the
        # relative order of entries that land on the same slot.
        live_entries = live_entries.each_with_index.sort_by do |e, i|
          [inst_to_slot.fetch(e.inst) + (e.slot_offset || 0), i]
        end.map(&:first)
        live_entries.each do |e|
          # Body section: absolute values, no delta.
          body_writer.write_small_value(e.line_no)
          body_writer.write_small_value(e.node_id)
          body_writer.write_small_value(e.events)

          # Positions section: delta from previous slot.
          # Add slot_offset to handle "adjust" entries that point mid-instruction.
          slot = inst_to_slot.fetch(e.inst) + (e.slot_offset || 0)
          pos_writer.write_small_value(slot - prev_slot)
          prev_slot = slot
        end
      end
    end
  end
end
