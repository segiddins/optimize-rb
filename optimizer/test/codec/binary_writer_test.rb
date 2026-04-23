# frozen_string_literal: true
require "test_helper"
require "optimize/codec/binary_writer"
require "optimize/codec/binary_reader"

class BinaryWriterTest < Minitest::Test
  def test_write_u32_little_endian
    writer = Optimize::Codec::BinaryWriter.new
    writer.write_u32(4)
    assert_equal "\x04\x00\x00\x00".b, writer.buffer
  end

  def test_write_bytes
    writer = Optimize::Codec::BinaryWriter.new
    writer.write_bytes("YARB".b)
    assert_equal "YARB".b, writer.buffer
  end

  def test_write_cstr
    writer = Optimize::Codec::BinaryWriter.new
    writer.write_cstr("hi")
    assert_equal "hi\x00".b, writer.buffer
  end

  def test_round_trip_with_reader
    writer = Optimize::Codec::BinaryWriter.new
    writer.write_u32(0xdeadbeef)
    writer.write_bytes("YARB".b)
    writer.write_cstr("hello")

    reader = Optimize::Codec::BinaryReader.new(writer.buffer)
    assert_equal 0xdeadbeef, reader.read_u32
    assert_equal "YARB".b, reader.read_bytes(4)
    assert_equal "hello".b, reader.read_cstr
  end
end
