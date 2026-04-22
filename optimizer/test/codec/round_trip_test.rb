# frozen_string_literal: true
require "test_helper"
require "ruby_opt/codec"
require "ruby_opt/codec/header"
require "ruby_opt/codec/object_table"
require "ruby_opt/codec/iseq_envelope"
require "ruby_opt/ir/function"
require "ruby_opt/ir/instruction"

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

  def test_iseq_envelope_round_trip
    src = "def hi(name, times: 1); times.times { puts name }; end"
    original = RubyVM::InstructionSequence.compile(src).to_binary
    ir = RubyOpt::Codec.decode(original)

    # Outer Function has a child for `hi`, which has a child for the block.
    hi = ir.children.find { |f| f.name == "hi" }
    refute_nil hi
    block = hi.children.find { |f| f.type == :block }
    refute_nil block

    re_encoded = RubyOpt::Codec.encode(ir)
    assert_equal original, re_encoded
  end

  def test_object_table_round_trip
    # Use 256 instead of 1: the integer 1 is encoded via the specialized opcode
    # putobject_INT2FIX_1_ and does not appear as an object-table entry. 256 goes
    # through the normal putobject path and IS stored in the object table.
    original = RubyVM::InstructionSequence.compile(
      '[256, "two", :three, 4.5, /six/]'
    ).to_binary

    # Decode via full Codec (ObjectTable now only covers its own region; iseq region
    # is handled by IseqList).
    ir = RubyOpt::Codec.decode(original)
    table = ir.misc[:object_table]

    # Table should contain literals seen in the snippet
    assert_includes table.objects, 256
    assert_includes table.objects, "two"
    assert_includes table.objects, :three
    assert_includes table.objects, 4.5

    # Full round-trip must be byte-identical
    re_encoded = RubyOpt::Codec.encode(ir)
    assert_equal original, re_encoded
  end

  def test_instruction_stream_decode_shape
    src = "def add(a, b); a + b; end"
    ir = RubyOpt::Codec.decode(
      RubyVM::InstructionSequence.compile(src).to_binary
    )
    add = ir.children.find { |f| f.name == "add" }
    refute_nil add
    opcodes = add.instructions.map(&:opcode)
    assert_includes opcodes, :opt_plus
    assert_includes opcodes, :leave
    # At least one getlocal-family op (exact opcode varies by arg position)
    assert opcodes.any? { |op| op.to_s.start_with?("getlocal") }, "expected getlocal-family opcode, got #{opcodes.inspect}"
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

  def test_u64_to_i64_boundaries
    assert_equal 0,                 RubyOpt::Codec::InstructionStream.u64_to_i64(0)
    assert_equal 1,                 RubyOpt::Codec::InstructionStream.u64_to_i64(1)
    assert_equal (1 << 63) - 1,     RubyOpt::Codec::InstructionStream.u64_to_i64((1 << 63) - 1)
    assert_equal(-(1 << 63),        RubyOpt::Codec::InstructionStream.u64_to_i64(1 << 63))
    assert_equal(-1,                RubyOpt::Codec::InstructionStream.u64_to_i64((1 << 64) - 1))
    assert_equal(-2,                RubyOpt::Codec::InstructionStream.u64_to_i64((1 << 64) - 2))
  end

  def test_i64_to_u64_boundaries
    assert_equal 0,             RubyOpt::Codec::InstructionStream.i64_to_u64(0)
    assert_equal (1 << 63) - 1, RubyOpt::Codec::InstructionStream.i64_to_u64((1 << 63) - 1)
    assert_equal (1 << 64) - 1, RubyOpt::Codec::InstructionStream.i64_to_u64(-1)
    assert_equal (1 << 64) - 2, RubyOpt::Codec::InstructionStream.i64_to_u64(-2)
    assert_equal 1 << 63,       RubyOpt::Codec::InstructionStream.i64_to_u64(-(1 << 63))
    assert_raises(ArgumentError) { RubyOpt::Codec::InstructionStream.i64_to_u64(1 << 63) }
    assert_raises(ArgumentError) { RubyOpt::Codec::InstructionStream.i64_to_u64(-(1 << 63) - 1) }
  end

  def test_decode_backward_branch_in_while_loop
    # A minimal method with a while loop. The while body loops back via
    # branchif or branchunless with a NEGATIVE relative slot offset.
    src = "def loop_me(n); i = 0; while i < n; i += 1; end; i; end"
    original = RubyVM::InstructionSequence.compile(src).to_binary

    # Before the fix: this decode raises with
    #   "OFFSET raw=<huge> in branch* targets slot <huge> with no corresponding instruction"
    ir = RubyOpt::Codec.decode(original)
    refute_nil ir

    # Sanity: at least one branch instruction must point backward (target index
    # strictly less than the branch's own index).
    loop_me = ir.children.find { |f| f.name == "loop_me" }
    refute_nil loop_me
    insns = loop_me.instructions
    has_backward_branch = insns.each_with_index.any? do |insn, idx|
      %i[branchif branchunless branchnil jump].include?(insn.opcode) &&
        insn.operands[0].is_a?(Integer) && insn.operands[0] < idx
    end
    assert has_backward_branch, "expected at least one backward branch in while loop"
  end

  def test_round_trip_helpers_compose
    [-5, -1, 0, 1, 5, (1 << 62), -(1 << 62)].each do |i|
      u = RubyOpt::Codec::InstructionStream.i64_to_u64(i)
      assert_equal i, RubyOpt::Codec::InstructionStream.u64_to_i64(u),
        "round-trip failed for i=#{i} via u=#{u}"
    end
  end

  def test_encode_backward_branch_byte_identity
    src = "def loop_me(n); i = 0; while i < n; i += 1; end; i; end"
    original = RubyVM::InstructionSequence.compile(src).to_binary

    ir = RubyOpt::Codec.decode(original)
    re_encoded = RubyOpt::Codec.encode(ir)
    assert_equal original, re_encoded,
      "round-trip byte mismatch for while-loop iseq"

    loaded = RubyVM::InstructionSequence.load_from_binary(re_encoded)
    assert_kind_of RubyVM::InstructionSequence, loaded
  end

  def test_while_loop_executes_after_round_trip
    src = <<~RUBY
      def sum_to(n)
        s = 0
        i = 1
        while i <= n
          s += i
          i += 1
        end
        s
      end
      sum_to(10)
    RUBY
    original = RubyVM::InstructionSequence.compile(src).to_binary

    ir = RubyOpt::Codec.decode(original)
    re_encoded = RubyOpt::Codec.encode(ir)

    loaded = RubyVM::InstructionSequence.load_from_binary(re_encoded)
    assert_equal 55, loaded.eval, "round-tripped while loop must still compute 1+2+...+10"
  end

  def test_encode_rejects_out_of_range_offset
    # Computed offsets wider than INT64_MAX are rejected by the helper, not
    # deep in write_small_value with a misleading "must be non-negative" message.
    assert_raises(ArgumentError) do
      RubyOpt::Codec::InstructionStream.i64_to_u64((1 << 63))
    end
  end
end
