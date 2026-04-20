# frozen_string_literal: true

require "ruby_opt/codec/iseq_envelope"
require "ruby_opt/codec/instruction_stream"
require "ruby_opt/codec/catch_table"
require "ruby_opt/codec/line_info"
require "ruby_opt/codec/arg_positions"
require "ruby_opt/ir/function"

module RubyOpt
  module Codec
    # Decodes and encodes the iseq list section of a YARB binary.
    #
    # Binary layout (from research/cruby/ibf-format.md §2 and §4):
    #
    #   [40]  Iseq data region — data sections and body records for all iseqs
    #         (interleaved; each iseq written by ibf_dump_iseq_each; body record last)
    #   [X]   Iseq offset array — iseq_list_size × uint32_t at header.iseq_list_offset
    #         Each entry is the absolute offset of that iseq's body record.
    #
    # The ObjectTable follows immediately after the iseq offset array.
    #
    # Decode strategy:
    #   1. Read the iseq offset array (random-access via header.iseq_list_offset).
    #   2. Capture the raw iseq data region (bytes 40 .. iseq_list_offset-1 plus the
    #      offset array itself) for verbatim re-emission.
    #   3. Decode each body record to build IR::Function objects.
    #   4. Wire up parent/child relationships using parent_iseq_index.
    #
    # Encode strategy:
    #   1. Write the raw iseq data region verbatim.
    #   2. Write the iseq offset array (the body record offsets stay the same since we
    #      re-emit the data region byte-for-byte).
    #
    class IseqList
      # @return [Array<IR::Function>] all functions in iseq-list order
      attr_reader :functions

      # @return [IR::Function] the root (top-level) iseq — typically functions[0]
      attr_reader :root

      # Absolute byte offset where the iseq data region begins in the binary.
      ISEQ_REGION_START = 40

      def initialize(functions, root, raw_iseq_region, raw_offset_array, object_table)
        @functions         = functions
        @root              = root
        @raw_iseq_region   = raw_iseq_region   # bytes from pos 40 to iseq_list_offset (exclusive)
        @raw_offset_array  = raw_offset_array  # iseq_list_size × 4 bytes
        @object_table      = object_table
      end

      # Decode the iseq list from +binary+ using +header+ and +object_table+.
      #
      # @param binary       [String]      full YARB binary (ASCII-8BIT)
      # @param header       [Header]      decoded header
      # @param object_table [ObjectTable] decoded object table
      # @return [IseqList]
      def self.decode(binary, header, object_table)
        iseq_count  = header.iseq_list_size
        list_offset = header.iseq_list_offset

        # Capture raw bytes: iseq data region (from pos 40 to list_offset).
        iseq_region_start = 40
        iseq_region_len   = list_offset - iseq_region_start
        raw_iseq_region   = binary.byteslice(iseq_region_start, iseq_region_len)

        # Capture raw offset array bytes.
        raw_offset_array  = binary.byteslice(list_offset, iseq_count * 4)

        # Read the offset array.
        body_offsets = raw_offset_array.unpack("V*")  # V = uint32 little-endian

        # First pass: decode each body record, building IR::Function stubs.
        # all_functions[i] corresponds to iseq-list index i.
        all_functions = Array.new(iseq_count)
        body_offsets.each_with_index do |body_offset, idx|
          all_functions[idx] = IseqEnvelope.decode(
            binary, body_offset, header, object_table, all_functions
          )
        end

        # Second pass: wire up parent/child relationships.
        # Each function's misc[:parent_iseq_index] tells us who its parent is.
        # The sentinel for "no parent" is -1 stored as a huge unsigned int in small_value
        # (CRuby uses ibf_offset_t which is uint32; -1 == 0xFFFFFFFF).
        # We treat any parent_idx >= iseq_count or parent_idx == idx as "no real parent".
        all_functions.each_with_index do |fn, idx|
          parent_idx = fn.misc[:parent_iseq_index]
          # Clamp to signed 32-bit to handle the -1 sentinel (stored as 0xFFFFFFFF).
          # small_value is decoded as unsigned; -1 as uint32 = 4294967295.
          parent_idx_signed = parent_idx > 0x7FFFFFFF ? parent_idx - 0x100000000 : parent_idx
          next if parent_idx_signed < 0          # -1 sentinel: no parent
          next if parent_idx_signed == idx       # root iseq: parent is itself
          next if parent_idx_signed >= iseq_count

          parent_fn = all_functions[parent_idx_signed]
          parent_fn&.children&.push(fn)
        end

        # The root is the top-level iseq (index 0 in the list, or the one with no real parent).
        # Convention: iseq-list index 0 is always the outermost iseq.
        root = all_functions[0]

        new(all_functions, root, raw_iseq_region, raw_offset_array, object_table)
      end

      # Encode the iseq list into +writer+.
      #
      # For each function, re-encodes its instruction stream via InstructionStream.encode
      # and splices the result over the original bytes in the iseq data region.
      # If the re-encoded instruction bytes differ in length from the original,
      # raises RubyOpt::Codec::EncoderSizeChange.
      #
      # Catch table entries are re-encoded from IR::CatchEntry objects and spliced in.
      #
      # @param writer [BinaryWriter]
      def encode(writer)
        # Make a mutable copy of the raw iseq region so we can splice in re-encoded bytes.
        region = @raw_iseq_region.dup

        @functions.each do |fn|
          bytecode_abs  = fn.misc[:bytecode_abs]
          bytecode_size = fn.misc[:bytecode_size]

          # Skip iseqs with no bytecode (e.g. iseq_size == 0).
          next unless bytecode_abs && bytecode_size && bytecode_size > 0
          next unless fn.instructions

          # Re-encode the instruction stream.
          new_bytes = InstructionStream.encode(fn.instructions, @object_table, @functions)
          original_len = bytecode_size
          new_len = new_bytes.bytesize

          if new_len != original_len
            raise Codec::EncoderSizeChange,
              "instruction re-encode changed size: iseq=#{fn.name} was=#{original_len} got=#{new_len}"
          end

          # Splice new_bytes into the region at the correct offset.
          region_offset = bytecode_abs - ISEQ_REGION_START
          region[region_offset, new_len] = new_bytes

          # Re-encode the catch table from IR::CatchEntry objects (if present).
          catch_entries = fn.catch_entries
          catch_table_abs  = fn.misc[:catch_table_abs]
          catch_table_size = fn.misc[:catch_table_size]
          if catch_entries && catch_table_abs && catch_table_size > 0
            # Build inst → slot map from current instructions.
            inst_to_slot = InstructionStream.inst_to_slot_map(fn.instructions)
            ct_writer = BinaryWriter.new
            CatchTable.encode(ct_writer, catch_entries, inst_to_slot)
            new_ct_bytes = ct_writer.buffer

            # Splice the re-encoded catch table into the region.
            ct_region_offset = catch_table_abs - ISEQ_REGION_START
            region[ct_region_offset, new_ct_bytes.bytesize] = new_ct_bytes
          end

          # Re-encode the insns_info (line info) from IR::LineEntry objects (if present).
          # CRuby stores this as two separate sections: body (line_no/node_id/events) and
          # positions (delta-encoded slot positions).
          line_entries = fn.line_entries
          insns_body_abs = fn.misc[:insns_body_abs]
          insns_pos_abs  = fn.misc[:insns_pos_abs]
          insns_info_size = fn.misc[:insns_info_size]
          if line_entries && insns_body_abs && insns_pos_abs && insns_info_size > 0
            inst_to_slot = InstructionStream.inst_to_slot_map(fn.instructions)
            body_writer = BinaryWriter.new
            pos_writer  = BinaryWriter.new
            LineInfo.encode(body_writer, pos_writer, line_entries, inst_to_slot)

            body_region_offset = insns_body_abs - ISEQ_REGION_START
            pos_region_offset  = insns_pos_abs  - ISEQ_REGION_START
            region[body_region_offset, body_writer.buffer.bytesize] = body_writer.buffer
            region[pos_region_offset,  pos_writer.buffer.bytesize]  = pos_writer.buffer
          end

          # Re-encode the opt_table from IR::ArgPositions (if present).
          # opt_table is VALUE[] (8-byte native uint64 YARV slot indices), VALUE-aligned.
          arg_positions = fn.arg_positions
          opt_table_abs = fn.misc[:opt_table_abs]
          if arg_positions && opt_table_abs
            inst_to_slot = InstructionStream.inst_to_slot_map(fn.instructions)
            ArgPositions.encode(region, ISEQ_REGION_START, opt_table_abs, arg_positions, inst_to_slot)
          end
        end

        writer.write_bytes(region)
        writer.write_bytes(@raw_offset_array)
      end
    end
  end
end
