# frozen_string_literal: true

require "ruby_opt/codec/iseq_envelope"
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

      def initialize(functions, root, raw_iseq_region, raw_offset_array)
        @functions         = functions
        @root              = root
        @raw_iseq_region   = raw_iseq_region   # bytes from pos 40 to iseq_list_offset (exclusive)
        @raw_offset_array  = raw_offset_array  # iseq_list_size × 4 bytes
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

        new(all_functions, root, raw_iseq_region, raw_offset_array)
      end

      # Encode the iseq list into +writer+.
      # Uses raw bytes for byte-identical round-trip.
      #
      # @param writer [BinaryWriter]
      def encode(writer)
        writer.write_bytes(@raw_iseq_region)
        writer.write_bytes(@raw_offset_array)
      end
    end
  end
end
