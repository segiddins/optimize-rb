# frozen_string_literal: true
require "test_helper"
require "ruby_opt/codec"
require "ruby_opt/codec/local_table"

class LocalTableCodecTest < Minitest::Test
  # For every fixture iseq, decode(local_table_raw, size) → encode → must
  # equal the leading N bytes of raw (raw may include trailing pad that
  # belongs to the next section in the iseq layout).
  def test_round_trip_identity_for_corpus
    Dir[File.expand_path("corpus/*.rb", __dir__)].each do |fixture|
      src = File.read(fixture)
      bin = RubyVM::InstructionSequence.compile(src).to_binary
      ir  = RubyOpt::Codec.decode(bin)
      assert_each_iseq_local_table_roundtrips(ir)
    end
  end

  def test_decode_produces_indices_for_method_with_one_local
    src = "def take(x); x; end; take(1)"
    bin = RubyVM::InstructionSequence.compile(src).to_binary
    ir  = RubyOpt::Codec.decode(bin)
    target = find_iseq_named(ir, "take")
    refute_nil target, "expected to find an iseq named 'take'"
    size = target.misc[:local_table_size]
    assert_equal 1, size
    raw  = target.misc[:local_table_raw]
    entries = RubyOpt::Codec::LocalTable.decode(raw, size)
    assert_equal 1, entries.size
    idx = entries[0]
    assert_kind_of Integer, idx
    assert idx >= 0, "expected non-negative object-table index (got #{idx})"
  end

  def test_decode_raises_on_short_buffer
    assert_raises(ArgumentError) { RubyOpt::Codec::LocalTable.decode("\x00".b, 1) }
  end

  def test_grow_appends_entry_and_increments_size
    src = "def take(x); x; end; take(1)"
    bin = RubyVM::InstructionSequence.compile(src).to_binary
    ir  = RubyOpt::Codec.decode(bin)
    take = find_iseq_named(ir, "take")
    refute_nil take
    old_size = take.misc[:local_table_size]
    old_raw  = take.misc[:local_table_raw]
    original_entries = RubyOpt::Codec::LocalTable.decode(old_raw, old_size)
    sentinel = original_entries[0]

    returned = RubyOpt::Codec::LocalTable.grow!(take, sentinel)

    assert_equal old_size, returned
    assert_equal old_size + 1, take.misc[:local_table_size]
    new_entries = RubyOpt::Codec::LocalTable.decode(
      take.misc[:local_table_raw], take.misc[:local_table_size]
    )
    assert_equal original_entries + [sentinel], new_entries
  end

  def test_grow_preserves_encoder_round_trip
    src = "def take(x); x; end; take(1)"
    bin = RubyVM::InstructionSequence.compile(src).to_binary
    ir  = RubyOpt::Codec.decode(bin)
    take = find_iseq_named(ir, "take")
    refute_nil take
    sentinel = RubyOpt::Codec::LocalTable.decode(
      take.misc[:local_table_raw], take.misc[:local_table_size]
    )[0]

    RubyOpt::Codec::LocalTable.grow!(take, sentinel)
    re_encoded = RubyOpt::Codec.encode(ir)
    # Loading alone proves layout integrity; LINDEX rewrites aren't our job.
    RubyVM::InstructionSequence.load_from_binary(re_encoded)
  end

  def test_grow_preserves_trailing_alignment_pad
    src = "def take(x); x; end; take(1)"
    bin = RubyVM::InstructionSequence.compile(src).to_binary
    ir  = RubyOpt::Codec.decode(bin)
    take = find_iseq_named(ir, "take")
    refute_nil take
    old_bytesize = take.misc[:local_table_raw].bytesize
    sentinel = RubyOpt::Codec::LocalTable.decode(
      take.misc[:local_table_raw], take.misc[:local_table_size]
    )[0]

    RubyOpt::Codec::LocalTable.grow!(take, sentinel)

    assert_equal old_bytesize + RubyOpt::Codec::LocalTable::ID_SIZE,
                 take.misc[:local_table_raw].bytesize
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
    entries    = RubyOpt::Codec::LocalTable.decode(raw, size)
    re_encoded = RubyOpt::Codec::LocalTable.encode(entries)
    raw_bytes  = (raw || "".b)
    prefix = raw_bytes.byteslice(0, re_encoded.bytesize) || "".b
    assert_equal prefix.bytes, re_encoded.bytes,
      "local_table round-trip mismatch in #{fn.name} (size=#{size})"
    fn.children&.each { |c| assert_each_iseq_local_table_roundtrips(c) }
  end
end
