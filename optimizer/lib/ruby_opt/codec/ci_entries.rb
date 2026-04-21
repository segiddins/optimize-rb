# frozen_string_literal: true
require "ruby_opt/codec/binary_reader"
require "ruby_opt/codec/binary_writer"
require "ruby_opt/ir/call_data"

module RubyOpt
  module Codec
    # Parse and emit the ci_entries section of an iseq body.
    #
    # On-disk shape (research/cruby/ibf-format.md §4.1):
    #   per entry: mid_idx, flag, argc, kwlen, kw_indices[kwlen]
    # All values are small_value-encoded.
    module CiEntries
      module_function

      # @param bytes [String] ASCII-8BIT ci_entries blob
      # @param ci_size [Integer] number of entries (from body header)
      # @return [Array<IR::CallData>]
      def decode(bytes, ci_size)
        return [] if ci_size.nil? || ci_size.zero? || bytes.nil? || bytes.empty?
        reader = BinaryReader.new(bytes)
        Array.new(ci_size) do
          mid_idx     = reader.read_small_value
          flag        = reader.read_small_value
          argc        = reader.read_small_value
          kwlen       = reader.read_small_value
          kw_indices  = Array.new(kwlen) { reader.read_small_value }
          IR::CallData.new(
            mid_idx: mid_idx, flag: flag, argc: argc,
            kwlen: kwlen, kw_indices: kw_indices,
          )
        end
      end

      # @param entries [Array<IR::CallData>]
      # @return [String] ASCII-8BIT byte string
      def encode(entries)
        writer = BinaryWriter.new
        entries.each do |cd|
          writer.write_small_value(cd.mid_idx)
          writer.write_small_value(cd.flag)
          writer.write_small_value(cd.argc)
          writer.write_small_value(cd.kwlen)
          cd.kw_indices.each { |i| writer.write_small_value(i) }
        end
        writer.buffer
      end
    end
  end
end
