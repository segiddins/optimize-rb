# frozen_string_literal: true
require "test_helper"
require "optimize/codec/binary_reader"

class BinaryReaderTest < Minitest::Test
  def test_read_u32_little_endian
    reader = Optimize::Codec::BinaryReader.new("\x04\x00\x00\x00".b)
    assert_equal 4, reader.read_u32
    assert_equal 4, reader.pos
  end

  def test_read_bytes
    reader = Optimize::Codec::BinaryReader.new("YARB".b)
    assert_equal "YARB".b, reader.read_bytes(4)
  end

  def test_seek_and_peek
    reader = Optimize::Codec::BinaryReader.new("\x00\x01\x02\x03".b)
    reader.seek(2)
    assert_equal 2, reader.read_u8
  end

  def test_reads_past_end_raise
    reader = Optimize::Codec::BinaryReader.new("\x00".b)
    reader.read_u8
    assert_raises(RangeError) { reader.read_u8 }
  end
end
