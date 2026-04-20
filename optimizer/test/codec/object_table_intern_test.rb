# frozen_string_literal: true
require "test_helper"
require "ruby_opt/codec"

class ObjectTableInternTest < Minitest::Test
  def test_index_for_finds_existing_literal_from_source
    ir = RubyOpt::Codec.decode(
      RubyVM::InstructionSequence.compile("def f; 2 + 3; end; f").to_binary
    )
    ot = ir.misc[:object_table]
    refute_nil ot.index_for(2), "expected existing index for 2"
    refute_nil ot.index_for(3), "expected existing index for 3"
    assert_nil ot.index_for(9999)
  end

  def test_intern_returns_existing_index_without_growing_the_table
    ir = RubyOpt::Codec.decode(
      RubyVM::InstructionSequence.compile("def f; 2 + 3; end; f").to_binary
    )
    ot = ir.misc[:object_table]
    before_size = ot.objects.size
    idx = ot.intern(2)
    assert_equal ot.index_for(2), idx
    assert_equal before_size, ot.objects.size, "intern of existing value must not grow table"
  end

  def test_intern_appends_new_integer_and_binary_round_trips
    src = "def f; 2 + 3; end; f"
    original = RubyVM::InstructionSequence.compile(src).to_binary
    ir = RubyOpt::Codec.decode(original)
    ot = ir.misc[:object_table]
    before_size = ot.objects.size
    new_idx = ot.intern(6)
    assert_equal before_size, new_idx, "new index should be the previous end-of-table"
    assert_equal before_size + 1, ot.objects.size
    assert_equal 6, ot.objects[new_idx]

    modified = RubyOpt::Codec.encode(ir)
    loaded = RubyVM::InstructionSequence.load_from_binary(modified)
    assert_kind_of RubyVM::InstructionSequence, loaded
    assert_equal 5, loaded.eval
  end

  def test_intern_appends_true_and_false_when_absent
    src = "def f; 1 + 2; end; f"
    ir = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]

    t_idx = ot.intern(true)
    f_idx = ot.intern(false)
    assert_equal true,  ot.objects[t_idx]
    assert_equal false, ot.objects[f_idx]

    modified = RubyOpt::Codec.encode(ir)
    loaded = RubyVM::InstructionSequence.load_from_binary(modified)
    assert_kind_of RubyVM::InstructionSequence, loaded
  end

  def test_unmodified_round_trip_still_byte_identical
    src = "def f; 2 + 3; end; f"
    original = RubyVM::InstructionSequence.compile(src).to_binary
    ir = RubyOpt::Codec.decode(original)
    assert_equal original, RubyOpt::Codec.encode(ir)
  end
end
