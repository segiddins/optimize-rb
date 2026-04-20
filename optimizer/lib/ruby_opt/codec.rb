# frozen_string_literal: true

# RubyOpt::Codec — decode and encode the YARB ("YARV Binary Format")
# produced by RubyVM::InstructionSequence#to_binary.
#
# Public API:
#
#   RubyOpt::Codec.decode(binary) -> IR::Function
#     Parses a YARB blob into an IR::Function whose #children lists
#     the outer iseqs.
#
#   RubyOpt::Codec.encode(ir) -> String
#     Serializes back to YARB bytes suitable for
#     RubyVM::InstructionSequence.load_from_binary.
#
# Raises:
#   - MalformedBinary — magic bytes don't match "YARB" or input is
#     structurally invalid
#   - UnsupportedOpcode — instruction stream contains an opcode number
#     not in INSN_TABLE
#   - UnsupportedObjectKind — object table contains a Ruby type not
#     modeled by the codec
#
# The round-trip is identity: encode(decode(bin)) == bin, verified
# across a corpus of realistic snippets.
require "ruby_opt/codec/binary_reader"
require "ruby_opt/codec/binary_writer"
require "ruby_opt/codec/header"
require "ruby_opt/codec/object_table"
require "ruby_opt/codec/iseq_list"
require "ruby_opt/ir/function"

module RubyOpt
  module Codec
    # Raised when a binary blob does not conform to the YARB format.
    class MalformedBinary < StandardError; end

    # Raised when an unknown opcode is encountered in the bytecode stream.
    class UnsupportedOpcode < StandardError
      attr_reader :opcode_num, :offset

      def initialize(opcode_num, offset)
        @opcode_num = opcode_num
        @offset     = offset
        super("Unsupported opcode #{opcode_num} at byte offset #{offset}")
      end
    end

    # Raised when an object kind in the IBF object table is not yet implemented.
    class UnsupportedObjectKind < StandardError; end

    # Deprecated. The encoder now supports length-changing edits via IR-driven
    # re-serialization (see Task 5 of the codec length-changes plan). Kept for
    # backwards compatibility with callers that rescue it; no code in this repo
    # raises it anymore.
    class EncoderSizeChange < StandardError; end

    # Decodes a YARB binary blob (from RubyVM::InstructionSequence#to_binary)
    # into an IR::Function tree.
    #
    # The returned IR::Function is a synthetic "root container" whose children
    # are the iseq-list functions. For binaries with a single top-level iseq,
    # root.children[0] is that iseq; its children are nested iseqs.
    #
    # @param binary [String] raw YARB binary (ASCII-8BIT or BINARY encoding)
    # @return [IR::Function] root container holding decoded state
    def self.decode(binary)
      binary = binary.b  # force ASCII-8BIT

      reader = BinaryReader.new(binary)
      header = Header.decode(reader)

      # Decode the object table (uses full binary for random-access seeks).
      object_table = ObjectTable.decode(binary, header)

      # Decode the iseq list (also uses full binary).
      iseq_list = IseqList.decode(binary, header, object_table)

      # Build a synthetic root IR::Function that carries the full decode state.
      # The actual top-level iseq is iseq_list.root; its children are nested iseqs.
      IR::Function.new(
        name:          "<root>",
        path:          "",
        absolute_path: nil,
        first_lineno:  0,
        type:          :root,
        arg_spec:      {},
        local_table:   nil,
        catch_table:   nil,
        line_info:     nil,
        instructions:  nil,
        children:      iseq_list.functions,
        misc: {
          header:       header,
          object_table: object_table,
          iseq_list:    iseq_list,
          raw_binary:   binary,
        }
      )
    end

    # Encodes an IR::Function (as returned by decode) back into YARB binary form.
    #
    # Uses byte-identical (identity) encoding for unmodified IR. When IR has been
    # mutated in ways that change bytecode size, the iseq data region grows or
    # shrinks; in that case the header fields iseq_list_offset,
    # global_object_list_offset, and size are patched in the output buffer to
    # reflect the fresh layout. All other header fields are unchanged.
    #
    # @param ir [IR::Function] root container as returned by Codec.decode
    # @return [String] YARB binary (ASCII-8BIT)
    def self.encode(ir)
      header       = ir.misc[:header]
      object_table = ir.misc[:object_table]
      iseq_list    = ir.misc[:iseq_list]

      writer = BinaryWriter.new
      # Write header first (its offset fields may be stale if iseq region changed size).
      header.encode(writer)

      # Encode the iseq list; it returns the fresh absolute offset of the iseq offset
      # array (the value that belongs in header.iseq_list_offset).
      fresh_iseq_list_offset = iseq_list.encode(writer)

      # Compute how much the iseq region grew or shrank. The object offset array stores
      # absolute positions that all shift by the same delta.
      iseq_list_delta = fresh_iseq_list_offset - header.iseq_list_offset

      fresh_object_list_offset_from_encode =
        object_table.encode(writer, iseq_list_delta: iseq_list_delta)

      fresh_total_size = writer.pos
      fresh_object_list_offset =
        fresh_object_list_offset_from_encode ||
          (header.global_object_list_offset + iseq_list_delta)

      # Patch the three header fields that depend on layout.
      # Header layout: size@12(4 bytes), iseq_list_offset@28(4 bytes),
      # global_object_list_offset@32(4 bytes).
      buf = writer.buffer
      buf[12, 4] = [fresh_total_size].pack("V")
      buf[28, 4] = [fresh_iseq_list_offset].pack("V")
      buf[32, 4] = [fresh_object_list_offset].pack("V")

      appended = object_table.appended_count
      if appended.positive?
        fresh_object_list_size = header.global_object_list_size + appended
        buf[24, 4] = [fresh_object_list_size].pack("V")
      end

      buf
    end
  end
end
