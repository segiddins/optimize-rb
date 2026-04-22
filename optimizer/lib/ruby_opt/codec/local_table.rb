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

      # Append a new local slot to `fn`'s local table.
      #
      # Mutates `fn.misc[:local_table_size]` (+1) and `fn.misc[:local_table_raw]`
      # (re-encoded content followed by the same number of trailing alignment
      # pad bytes that the original raw carried — the iseq_list encoder uses
      # `raw.bytesize` for downstream section positioning).
      #
      # Does NOT mutate getlocal/setlocal LINDEX operands in `fn.instructions`;
      # that rewrite is the inlining pass's responsibility.
      #
      # @param fn [Object] function/iseq IR node with a `misc` Hash
      # @param object_table_index [Integer] index into the object table
      #   naming the new local's Symbol
      # @return [Integer] the new entry's local-table index
      #   (post-growth `local_table_size - 1`, i.e. the prior size)
      def grow!(fn, object_table_index)
        misc = fn.misc
        old_size = (misc[:local_table_size] || 0)
        old_raw  = (misc[:local_table_raw]  || "".b)
        entries  = decode(old_raw, old_size)
        entries << object_table_index
        new_content = encode(entries)
        old_content_size = old_size * ID_SIZE
        pad_bytes = [old_raw.bytesize - old_content_size, 0].max
        # Preserve the original size once, so the iseq_list encoder can detect
        # that the body record's local_table_size / relative offsets have
        # legitimately changed and skip byte-identity assertions.
        misc[:local_table_size_original] ||= old_size
        misc[:local_table_raw]  = new_content + ("\x00".b * pad_bytes)
        misc[:local_table_size] = old_size + 1
        old_size
      end
    end
  end
end
