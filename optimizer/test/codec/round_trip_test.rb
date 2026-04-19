# frozen_string_literal: true
require "test_helper"
require "ruby_opt/codec"
require "ruby_opt/codec/header"
require "ruby_opt/codec/object_table"

class RoundTripTest < Minitest::Test
  # The core contract: encode(decode(bin)) == bin, for unmodified iseqs.
  # Each example is a Ruby snippet that #compile can handle.

  EXAMPLES = [
    "1 + 2",
    "def hi; 1 + 2; end",
    "def add(a, b); a + b; end",
    "class Point; def initialize(x,y); @x=x; @y=y; end; end",
    "[1,2,3].map { |n| n * 2 }",
  ]

  EXAMPLES.each_with_index do |src, i|
    define_method(:"test_identity_#{i}_#{src[0,20].gsub(/\W+/,'_')}") do
      original = RubyVM::InstructionSequence.compile(src).to_binary
      ir = RubyOpt::Codec.decode(original)
      re_encoded = RubyOpt::Codec.encode(ir)
      assert_equal original, re_encoded,
        "round-trip mismatch for #{src.inspect}"
    end

    define_method(:"test_executable_#{i}_#{src[0,20].gsub(/\W+/,'_')}") do
      original = RubyVM::InstructionSequence.compile(src).to_binary
      ir = RubyOpt::Codec.decode(original)
      re_encoded = RubyOpt::Codec.encode(ir)
      # The VM must accept it and running must not raise
      loaded = RubyVM::InstructionSequence.load_from_binary(re_encoded)
      assert_kind_of RubyVM::InstructionSequence, loaded
      loaded.eval
    end
  end

  def test_object_table_round_trip
    # Use 256 instead of 1: the integer 1 is encoded via the specialized opcode
    # putobject_INT2FIX_1_ and does not appear as an object-table entry. 256 goes
    # through the normal putobject path and IS stored in the object table.
    original = RubyVM::InstructionSequence.compile(
      '[256, "two", :three, 4.5, /six/]'
    ).to_binary
    reader = RubyOpt::Codec::BinaryReader.new(original)
    header = RubyOpt::Codec::Header.decode(reader)
    table = RubyOpt::Codec::ObjectTable.decode(reader, header)

    # Table should contain literals seen in the snippet
    assert_includes table.objects, 256
    assert_includes table.objects, "two"
    assert_includes table.objects, :three
    assert_includes table.objects, 4.5

    writer = RubyOpt::Codec::BinaryWriter.new
    header.encode(writer)
    table.encode(writer, header)
    table_end = reader.pos
    assert_equal original.byteslice(0, table_end), writer.buffer
  end

  def test_header_round_trip
    original = RubyVM::InstructionSequence.compile("1 + 2").to_binary
    reader = RubyOpt::Codec::BinaryReader.new(original)
    header = RubyOpt::Codec::Header.decode(reader)

    assert_equal "YARB", header.magic
    refute_nil header.major_version
    refute_nil header.platform

    writer = RubyOpt::Codec::BinaryWriter.new
    header.encode(writer)
    # Header section must reproduce its original bytes
    header_len = reader.pos
    assert_equal original.byteslice(0, header_len), writer.buffer
  end
end
