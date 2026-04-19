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

      private

      def read_int(n, directive)
        read_bytes(n).unpack1(directive)
      end
    end
  end
end
