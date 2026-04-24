# frozen_string_literal: true

require "optimize/codec/binary_reader"
require "optimize/codec/binary_writer"
require "optimize/codec"

module Optimize
  module Codec
    # IBF header — the fixed-size 40-byte record at offset 0 of every YARB binary.
    #
    # Layout (from research/cruby/ibf-format.md §1):
    #   Offset  Size  Field
    #        0     4  magic                    — b"YARB"
    #        4     4  major_version            — uint32_t
    #        8     4  minor_version            — uint32_t
    #       12     4  size                     — uint32_t, total binary size (excl. extra)
    #       16     4  extra_size               — uint32_t
    #       20     4  iseq_list_size           — uint32_t, number of iseq records
    #       24     4  global_object_list_size  — uint32_t
    #       28     4  iseq_list_offset         — uint32_t, absolute byte offset
    #       32     4  global_object_list_offset — uint32_t, absolute byte offset
    #       36     1  endian                   — uint8_t ('l' or 'b')
    #       37     1  wordsize                 — uint8_t (sizeof VALUE, typically 8)
    #       38     2  (padding)                — implicit C struct padding, always zero
    #   Total: 40 bytes
    Header = Struct.new(
      :magic, :major_version, :minor_version, :size,
      :extra_size, :iseq_list_size, :global_object_list_size,
      :iseq_list_offset, :global_object_list_offset,
      :endian, :wordsize, :padding,
      keyword_init: true
    ) do
      BYTE_SIZE = 40

      # Decode a Header from the current position of +reader+.
      # Raises Optimize::Codec::MalformedBinary if the magic bytes are wrong,
      # or Optimize::Codec::UnmatchedIBFVersion if the version stamp doesn't
      # match the version this codec targets.
      def self.decode(reader)
        magic                    = reader.read_bytes(4)
        unless magic == "YARB".b
          raise Codec::MalformedBinary, "invalid magic bytes: expected 'YARB', got #{magic.inspect}"
        end
        major_version            = reader.read_u32
        minor_version            = reader.read_u32
        if major_version != Header::IBF_EXPECTED_MAJOR_VERSION ||
           minor_version != Header::IBF_EXPECTED_MINOR_VERSION
          raise Codec::UnmatchedIBFVersion.new(
            expected_major: Header::IBF_EXPECTED_MAJOR_VERSION,
            expected_minor: Header::IBF_EXPECTED_MINOR_VERSION,
            actual_major:   major_version,
            actual_minor:   minor_version,
          )
        end
        size                     = reader.read_u32
        extra_size               = reader.read_u32
        iseq_list_size           = reader.read_u32
        global_object_list_size  = reader.read_u32
        iseq_list_offset         = reader.read_u32
        global_object_list_offset = reader.read_u32
        endian                   = reader.read_u8
        wordsize                 = reader.read_u8
        padding                  = reader.read_bytes(2)

        new(
          magic: magic,
          major_version: major_version,
          minor_version: minor_version,
          size: size,
          extra_size: extra_size,
          iseq_list_size: iseq_list_size,
          global_object_list_size: global_object_list_size,
          iseq_list_offset: iseq_list_offset,
          global_object_list_offset: global_object_list_offset,
          endian: endian,
          wordsize: wordsize,
          padding: padding,
        )
      end

      # Returns a human-readable platform descriptor derived from endian and wordsize.
      # The YARB header does not store a platform string; this is synthesized.
      def platform
        endian_name = endian == 108 ? "little-endian" : "big-endian"  # 108 = 'l'.ord
        "#{endian_name}/#{wordsize * 8}-bit"
      end

      # Encode this header into +writer+, producing the original 40 bytes.
      def encode(writer)
        writer.write_bytes(magic)
        writer.write_u32(major_version)
        writer.write_u32(minor_version)
        writer.write_u32(size)
        writer.write_u32(extra_size)
        writer.write_u32(iseq_list_size)
        writer.write_u32(global_object_list_size)
        writer.write_u32(iseq_list_offset)
        writer.write_u32(global_object_list_offset)
        writer.write_u8(endian)
        writer.write_u8(wordsize)
        writer.write_bytes(padding)
      end
    end

    # The IBF version this codec was written against. CRuby defines
    # IBF_MAJOR_VERSION / IBF_MINOR_VERSION as ruby_api_version[0] / [1];
    # for Ruby 4.0.x that's (4, 0). The CRuby loader rejects any binary
    # whose stamps don't match exactly — mirror that here so a
    # cross-version blob fails at decode instead of producing nonsense.
    # Defined outside the Struct.new block because constants declared
    # inside it land on the enclosing module, not on the struct itself.
    Header::IBF_EXPECTED_MAJOR_VERSION = 4
    Header::IBF_EXPECTED_MINOR_VERSION = 0
  end
end
