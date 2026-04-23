# frozen_string_literal: true

require "optimize/ir/function"

module Optimize
  module Codec
    # Decode/encode the param opt_table for a single iseq.
    #
    # On-disk format (from research/cruby/ibf-format.md §4.1 "param opt table"):
    #   VALUE[] — (param_opt_num + 1) entries, each a native uint64 (little-endian on x86-64)
    #   holding the YARV slot index where execution begins for each entry count of supplied args.
    #
    # Entry semantics:
    #   opt_table[i] = YARV slot at which execution begins when exactly
    #                  (param_lead_num + i) positional arguments were supplied.
    #   opt_table[param_opt_num] = YARV slot after all default-eval code (start of method body).
    #
    # The section is 8-byte aligned (VALUE-aligned) and the absolute offset is stored in the
    # body record as param_opt_table_offset_rel (relative = body_offset - opt_table_abs).
    #
    # The keyword param struct (param_keyword_offset) stores only counts and object-table
    # indices (no instruction-position data), so it is left as raw bytes in misc.
    module ArgPositions
      module_function

      # Decode opt_table from the binary.
      #
      # @param binary        [String]   full YARB binary (ASCII-8BIT)
      # @param opt_table_abs [Integer]  absolute byte offset of the opt_table in the binary
      # @param opt_num       [Integer]  param_opt_num (number of optional args)
      # @param slot_to_inst  [Hash{Integer=>IR::Instruction}]  YARV slot → instruction
      # @return [IR::ArgPositions]
      def decode(binary, opt_table_abs, opt_num, slot_to_inst)
        count = opt_num + 1  # opt_num entries + 1 terminating entry
        opt_table = Array.new(count) do |i|
          slot = binary[opt_table_abs + i * 8, 8].unpack1("Q<")
          inst = slot_to_inst[slot]
          raise MalformedBinary,
            "opt_table[#{i}] slot #{slot} does not align with any instruction" unless inst
          inst
        end
        IR::ArgPositions.new(opt_table: opt_table)
      end

      # Encode opt_table into the iseq data region (splice-into-region form).
      #
      # Writes (opt_num + 1) native uint64 values (little-endian) at the current
      # position of +region+ (which already has space reserved from the original binary).
      # Call this with the same absolute offset used during decode so that the bytes
      # land in the right place.
      #
      # @param region         [String]  mutable copy of the raw iseq data region
      # @param region_start   [Integer] absolute byte offset where region begins (normally 40)
      # @param opt_table_abs  [Integer] absolute byte offset of the opt_table in the file
      # @param arg_positions  [IR::ArgPositions]
      # @param inst_to_slot   [Hash{IR::Instruction=>Integer}]  instruction → YARV slot
      def encode(region, region_start, opt_table_abs, arg_positions, inst_to_slot)
        opt_table = arg_positions.opt_table
        region_offset = opt_table_abs - region_start
        opt_table.each_with_index do |inst, i|
          slot = inst_to_slot.fetch(inst) do
            raise "opt_table[#{i}] instruction #{inst.opcode.inspect} not found in inst_to_slot map"
          end
          # Write as native uint64 little-endian (VALUE on 64-bit).
          region[region_offset + i * 8, 8] = [slot].pack("Q<")
        end
      end

      # Encode opt_table into +writer+ (sequential write form).
      #
      # Writes (opt_num + 1) native uint64 values (little-endian) to the writer at its
      # current position. Returns the encoded bytes for assertion purposes.
      #
      # @param writer         [BinaryWriter]
      # @param arg_positions  [IR::ArgPositions]
      # @param inst_to_slot   [Hash{IR::Instruction=>Integer}]  instruction → YARV slot
      # @return [String]  the encoded bytes (ASCII-8BIT)
      def encode_to_writer(writer, arg_positions, inst_to_slot)
        opt_table = arg_positions.opt_table
        bytes = "".b
        opt_table.each_with_index do |inst, i|
          slot = inst_to_slot.fetch(inst) do
            raise "opt_table[#{i}] instruction #{inst.opcode.inspect} not found in inst_to_slot map"
          end
          bytes << [slot].pack("Q<")
        end
        writer.write_bytes(bytes)
        bytes
      end
    end
  end
end
