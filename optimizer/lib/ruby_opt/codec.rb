# frozen_string_literal: true
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
    # Uses byte-identical (identity) encoding: all regions are re-emitted verbatim
    # from the raw bytes captured during decode.
    #
    # @param ir [IR::Function] root container as returned by Codec.decode
    # @return [String] YARB binary (ASCII-8BIT)
    def self.encode(ir)
      header       = ir.misc[:header]
      object_table = ir.misc[:object_table]
      iseq_list    = ir.misc[:iseq_list]

      writer = BinaryWriter.new
      header.encode(writer)
      iseq_list.encode(writer)
      object_table.encode(writer)
      writer.buffer
    end
  end
end
