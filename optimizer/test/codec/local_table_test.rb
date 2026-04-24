# frozen_string_literal: true
require "test_helper"
require "optimize/codec"
require "optimize/codec/local_table"
require "optimize/ir/function"
require "optimize/ir/instruction"

class LocalTableCodecTest < Minitest::Test
  # For every fixture iseq, decode(local_table_raw, size) → encode → must
  # equal the leading N bytes of raw (raw may include trailing pad that
  # belongs to the next section in the iseq layout).
  def test_round_trip_identity_for_corpus
    Dir[File.expand_path("corpus/*.rb", __dir__)].each do |fixture|
      src = File.read(fixture)
      bin = RubyVM::InstructionSequence.compile(src).to_binary
      ir  = Optimize::Codec.decode(bin)
      assert_each_iseq_local_table_roundtrips(ir)
    end
  end

  def test_decode_produces_indices_for_method_with_one_local
    src = "def take(x); x; end; take(1)"
    bin = RubyVM::InstructionSequence.compile(src).to_binary
    ir  = Optimize::Codec.decode(bin)
    target = find_iseq_named(ir, "take")
    refute_nil target, "expected to find an iseq named 'take'"
    size = target.misc[:local_table_size]
    assert_equal 1, size
    raw  = target.misc[:local_table_raw]
    entries = Optimize::Codec::LocalTable.decode(raw, size)
    assert_equal 1, entries.size
    idx = entries[0]
    assert_kind_of Integer, idx
    assert idx >= 0, "expected non-negative object-table index (got #{idx})"
  end

  def test_decode_raises_on_short_buffer
    assert_raises(ArgumentError) { Optimize::Codec::LocalTable.decode("\x00".b, 1) }
  end

  def test_grow_appends_entry_and_increments_size
    src = "def take(x); x; end; take(1)"
    bin = RubyVM::InstructionSequence.compile(src).to_binary
    ir  = Optimize::Codec.decode(bin)
    take = find_iseq_named(ir, "take")
    refute_nil take
    old_size = take.misc[:local_table_size]
    old_raw  = take.misc[:local_table_raw]
    original_entries = Optimize::Codec::LocalTable.decode(old_raw, old_size)
    sentinel = original_entries[0]

    returned = Optimize::Codec::LocalTable.grow!(take, sentinel)

    assert_equal old_size, returned
    assert_equal old_size + 1, take.misc[:local_table_size]
    new_entries = Optimize::Codec::LocalTable.decode(
      take.misc[:local_table_raw], take.misc[:local_table_size]
    )
    assert_equal original_entries + [sentinel], new_entries
  end

  def test_grow_preserves_encoder_round_trip
    src = "def take(x); x; end; take(1)"
    bin = RubyVM::InstructionSequence.compile(src).to_binary
    ir  = Optimize::Codec.decode(bin)
    take = find_iseq_named(ir, "take")
    refute_nil take
    sentinel = Optimize::Codec::LocalTable.decode(
      take.misc[:local_table_raw], take.misc[:local_table_size]
    )[0]

    Optimize::Codec::LocalTable.grow!(take, sentinel)
    re_encoded = Optimize::Codec.encode(ir)
    # Loading alone proves layout integrity; LINDEX rewrites aren't our job.
    RubyVM::InstructionSequence.load_from_binary(re_encoded)
  end

  def test_grow_preserves_trailing_alignment_pad
    src = "def take(x); x; end; take(1)"
    bin = RubyVM::InstructionSequence.compile(src).to_binary
    ir  = Optimize::Codec.decode(bin)
    take = find_iseq_named(ir, "take")
    refute_nil take
    old_bytesize = take.misc[:local_table_raw].bytesize
    sentinel = Optimize::Codec::LocalTable.decode(
      take.misc[:local_table_raw], take.misc[:local_table_size]
    )[0]

    Optimize::Codec::LocalTable.grow!(take, sentinel)

    assert_equal old_bytesize + Optimize::Codec::LocalTable::ID_SIZE,
                 take.misc[:local_table_raw].bytesize
  end

  def test_grow_sentinel_captures_pre_first_growth_size_only
    src = "def take(x); x; end; take(1)"
    bin = RubyVM::InstructionSequence.compile(src).to_binary
    ir  = Optimize::Codec.decode(bin)
    take = find_iseq_named(ir, "take")
    refute_nil take
    original_size = take.misc[:local_table_size]
    sentinel = Optimize::Codec::LocalTable.decode(
      take.misc[:local_table_raw], take.misc[:local_table_size]
    )[0]

    Optimize::Codec::LocalTable.grow!(take, sentinel)
    Optimize::Codec::LocalTable.grow!(take, sentinel)

    assert_equal original_size, take.misc[:local_table_size_pre_growth]
  end

  def test_shift_level0_lindex_shifts_wc0_operands
    inst = Optimize::IR::Instruction.new(
      opcode: :getlocal_WC_0, operands: [3], line: 1,
    )
    fn = Optimize::IR::Function.new(instructions: [inst], misc: {})
    Optimize::Codec::LocalTable.shift_level0_lindex!(fn, by: 2)
    assert_equal 5, inst.operands[0]
  end

  def test_shift_level0_lindex_shifts_explicit_level_zero
    inst = Optimize::IR::Instruction.new(
      opcode: :getlocal, operands: [3, 0], line: 1,
    )
    fn = Optimize::IR::Function.new(instructions: [inst], misc: {})
    Optimize::Codec::LocalTable.shift_level0_lindex!(fn, by: 3)
    assert_equal 0, inst.operands[1], "level operand unchanged"
    assert_equal 6, inst.operands[0], "LINDEX shifted by 3"
  end

  def test_shift_level0_lindex_leaves_level1_ops_alone
    outer = Optimize::IR::Instruction.new(
      opcode: :getlocal_WC_1, operands: [3], line: 1,
    )
    explicit1 = Optimize::IR::Instruction.new(
      opcode: :setlocal, operands: [4, 1], line: 2,
    )
    fn = Optimize::IR::Function.new(instructions: [outer, explicit1], misc: {})
    Optimize::Codec::LocalTable.shift_level0_lindex!(fn, by: 2)
    assert_equal 3, outer.operands[0]
    assert_equal 4, explicit1.operands[0]
    assert_equal 1, explicit1.operands[1]
  end

  def test_shift_level0_lindex_covers_setlocal_wc0_too
    set = Optimize::IR::Instruction.new(
      opcode: :setlocal_WC_0, operands: [3], line: 1,
    )
    fn = Optimize::IR::Function.new(instructions: [set], misc: {})
    Optimize::Codec::LocalTable.shift_level0_lindex!(fn, by: 4)
    assert_equal 7, set.operands[0]
  end

  private

  def find_iseq_named(fn, name)
    return fn if fn.name.to_s == name
    fn.children&.each do |c|
      found = find_iseq_named(c, name)
      return found if found
    end
    nil
  end

  def assert_each_iseq_local_table_roundtrips(fn)
    raw  = fn.misc[:local_table_raw]
    size = fn.misc[:local_table_size]
    entries    = Optimize::Codec::LocalTable.decode(raw, size)
    re_encoded = Optimize::Codec::LocalTable.encode(entries)
    raw_bytes  = (raw || "".b)
    prefix = raw_bytes.byteslice(0, re_encoded.bytesize) || "".b
    assert_equal prefix.bytes, re_encoded.bytes,
      "local_table round-trip mismatch in #{fn.name} (size=#{size})"
    fn.children&.each { |c| assert_each_iseq_local_table_roundtrips(c) }
  end
end
