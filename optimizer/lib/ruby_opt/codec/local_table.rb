# frozen_string_literal: true
require "ruby_opt/codec/binary_reader"
require "ruby_opt/codec/binary_writer"

module RubyOpt
  module Codec
    # Parse and emit the local_table section of an iseq body.
    #
    # On-disk shape (research/cruby/ibf-format.md §4.1):
    #   local_table_size entries, each an ID-sized (uintptr_t) object-table
    #   index for the Symbol that names the local. ID is 8 bytes on a
    #   64-bit build (little-endian), which is the only configuration we
    #   target for this talk.
    #
    # The raw blob may include trailing alignment zeros that belong to
    # the section *after* this one in the enclosing iseq layout. Decode
    # reads exactly `size` entries; encode returns exactly the content
    # bytes (no padding). The iseq_list encoder re-adds trailing pad.
    module LocalTable
      ID_SIZE = 8 # uintptr_t on 64-bit
      module_function

      # @param bytes [String] ASCII-8BIT local_table blob
      # @param size [Integer] number of entries (from body header)
      # @return [Array<Integer>] object-table indices, one per local
      def decode(bytes, size)
        return [] if size.nil? || size.zero? || bytes.nil? || bytes.empty?
        required = size * ID_SIZE
        if bytes.bytesize < required
          raise ArgumentError,
            "local_table buffer too short: got #{bytes.bytesize} bytes, need #{required} (size=#{size})"
        end
        reader = BinaryReader.new(bytes)
        Array.new(size) { reader.read_u64 }
      end

      # @param entries [Array<Integer>] object-table indices
      # @return [String] ASCII-8BIT byte string
      def encode(entries)
        writer = BinaryWriter.new
        entries.each { |idx| writer.write_u64(idx) }
        writer.buffer
      end
    end
  end
end
