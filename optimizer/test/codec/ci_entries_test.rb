# frozen_string_literal: true
require "test_helper"
require "ruby_opt/codec"
require "ruby_opt/codec/ci_entries"

class CiEntriesCodecTest < Minitest::Test
  # For every fixture iseq, decode(ci_entries_raw) → encode → must equal input.
  def test_round_trip_identity_for_corpus
    Dir[File.expand_path("corpus/*.rb", __dir__)].each do |fixture|
      src = File.read(fixture)
      bin = RubyVM::InstructionSequence.compile(src).to_binary
      ir  = RubyOpt::Codec.decode(bin)
      assert_each_iseq_ci_roundtrips(ir)
    end
  end

  def test_decode_produces_calldata_for_simple_send
    src = "def magic; 42; end; magic"
    bin = RubyVM::InstructionSequence.compile(src).to_binary
    ir  = RubyOpt::Codec.decode(bin)
    # Find the iseq that actually contains the top-level `magic` call.
    # IseqEnvelope nests the compiled body under a synthetic <root>.
    target = find_iseq_with_ci(ir)
    refute_nil target, "expected to find an iseq with ci entries"
    raw      = target.misc[:ci_entries_raw]
    ci_size  = target.misc[:ci_size]
    entries  = RubyOpt::Codec::CiEntries.decode(raw, ci_size)
    assert_equal 1, entries.size
    cd = entries[0]
    assert cd.fcall?, "expected FCALL flag (got 0x#{cd.flag.to_s(16)})"
    assert cd.args_simple?, "expected ARGS_SIMPLE flag (got 0x#{cd.flag.to_s(16)})"
    assert_equal 0, cd.argc
    assert_equal 0, cd.kwlen
  end

  private

  def find_iseq_with_ci(fn)
    cs = fn.misc[:ci_size]
    return fn if cs && cs > 0
    fn.children&.each do |c|
      found = find_iseq_with_ci(c)
      return found if found
    end
    nil
  end

  def assert_each_iseq_ci_roundtrips(fn)
    raw     = fn.misc[:ci_entries_raw]
    ci_size = fn.misc[:ci_size]
    entries = RubyOpt::Codec::CiEntries.decode(raw, ci_size)
    expected_bytes = (raw || "".b).bytes
    assert_equal expected_bytes, RubyOpt::Codec::CiEntries.encode(entries).bytes,
      "ci_entries round-trip mismatch in #{fn.name} (ci_size=#{ci_size})"
    fn.children&.each { |c| assert_each_iseq_ci_roundtrips(c) }
  end
end
