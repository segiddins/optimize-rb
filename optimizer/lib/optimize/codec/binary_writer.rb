# frozen_string_literal: true

module Optimize
  module Codec
    class BinaryWriter
      def initialize
        @buffer = String.new(encoding: Encoding::ASCII_8BIT)
      end

      def buffer = @buffer

      def write_u8(v)  = write_int(v, "C")
      def write_u16(v) = write_int(v, "v")
      def write_u32(v) = write_int(v, "V")
      def write_u64(v) = write_int(v, "Q<")

      def write_bytes(bytes) = @buffer << bytes.b
      def write_cstr(s)      = @buffer << s.b << "\x00".b

      def pos = @buffer.bytesize

      # Pad with zero bytes until pos is aligned to +alignment+ bytes.
      def align_to(alignment)
        remainder = @buffer.bytesize % alignment
        write_bytes("\x00" * (alignment - remainder)) if remainder != 0
      end

      # Encode a small_value (variable-length unsigned integer).
      # See research/cruby/ibf-format.md §6 for the encoding.
      #
      # Layout: the first byte carries a unary marker in its trailing bits:
      #   XXXXXXX1  → 1 byte,  value ≤ 0x7f
      #   XXXXXX10  → 2 bytes, value ≤ 0x3fff
      #   XXXXX100  → 3 bytes, value ≤ 0x1fffff
      #   XXXX1000  → 4 bytes, value ≤ 0x0fffffff
      #   00000000  → 9 bytes, full uint64
      # The value bits after the marker are stored big-endian across subsequent bytes.
      def write_small_value(value)
        raise ArgumentError, "small_value must be non-negative, got #{value}" if value.negative?
        if value <= 0x7f
          @buffer << [((value << 1) | 1)].pack("C")
        elsif value <= 0x3fff
          b1 = value & 0xff
          b0 = ((value >> 8) << 2) | 2
          @buffer << [b0, b1].pack("CC")
        elsif value <= 0x1f_ffff
          b2 = value & 0xff
          b1 = (value >> 8) & 0xff
          b0 = ((value >> 16) << 3) | 4
          @buffer << [b0, b1, b2].pack("CCC")
        elsif value <= 0x0fff_ffff
          b3 = value & 0xff
          b2 = (value >> 8) & 0xff
          b1 = (value >> 16) & 0xff
          b0 = ((value >> 24) << 4) | 8
          @buffer << [b0, b1, b2, b3].pack("CCCC")
        else
          # 9-byte form for large values: full uint64 big-endian
          # (ibf_dump_small_value uses the same big-endian shift algorithm as the
          # general case: "value = (value << 8) | byte[i]" for i in [1..8)).
          @buffer << "\x00".b << [value].pack("Q>")
        end
      end

      private

      def write_int(v, directive)
        @buffer << [v].pack(directive)
      end
    end
  end
end
