# frozen_string_literal: true

module RubyOpt
  module Codec
    class BinaryReader
      attr_reader :pos

      def initialize(buffer)
        @buffer = buffer.b
        @pos = 0
      end

      def read_u8  = read_int(1, "C")
      def read_u16 = read_int(2, "v")
      def read_u32 = read_int(4, "V")
      def read_u64 = read_int(8, "Q<")

      def read_bytes(n)
        raise RangeError, "read past end" if @pos + n > @buffer.bytesize
        bytes = @buffer.byteslice(@pos, n)
        @pos += n
        bytes
      end

      def read_cstr
        nul = @buffer.index("\x00".b, @pos)
        raise RangeError, "unterminated cstr" unless nul
        s = @buffer.byteslice(@pos, nul - @pos)
        @pos = nul + 1
        s
      end

      def seek(offset)
        raise RangeError if offset.negative? || offset > @buffer.bytesize
        @pos = offset
      end

      # Returns a slice of the underlying buffer without advancing pos.
      def peek_bytes(offset, length)
        raise RangeError, "peek past end" if offset + length > @buffer.bytesize
        @buffer.byteslice(offset, length)
      end

      # Total byte length of the underlying buffer.
      def bytesize = @buffer.bytesize

      # Decode a small_value (variable-length unsigned integer) from the current position.
      # See research/cruby/ibf-format.md §6 for the encoding.
      def read_small_value
        b0 = read_u8
        if b0 == 0
          # 9-byte form: full uint64 in next 8 bytes (little-endian)
          read_bytes(8).unpack1("Q<")
        else
          # Count trailing zero bits of b0 to determine total byte count
          n = 0
          tmp = b0
          while tmp & 1 == 0
            n += 1
            tmp >>= 1
          end
          n_bytes = n + 1  # total bytes including b0
          value = b0 >> n_bytes
          (1...n_bytes).each { |_| value = (value << 8) | read_u8 }
          value
        end
      end

      private

      def read_int(n, directive)
        read_bytes(n).unpack1(directive)
      end
    end
  end
end
