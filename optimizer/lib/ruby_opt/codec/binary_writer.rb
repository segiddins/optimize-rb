# frozen_string_literal: true

module RubyOpt
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

      private

      def write_int(v, directive)
        @buffer << [v].pack(directive)
      end
    end
  end
end
