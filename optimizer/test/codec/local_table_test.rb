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
