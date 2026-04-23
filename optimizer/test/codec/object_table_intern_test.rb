# frozen_string_literal: true
require "test_helper"
require "optimize/codec"

class ObjectTableInternTest < Minitest::Test
  def test_index_for_finds_existing_literal_from_source
    ir = Optimize::Codec.decode(
      RubyVM::InstructionSequence.compile("def f; 2 + 3; end; f").to_binary
    )
    ot = ir.misc[:object_table]
    refute_nil ot.index_for(2), "expected existing index for 2"
    refute_nil ot.index_for(3), "expected existing index for 3"
    assert_nil ot.index_for(9999)
  end

  def test_intern_returns_existing_index_without_growing_the_table
    ir = Optimize::Codec.decode(
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
    ir = Optimize::Codec.decode(original)
    ot = ir.misc[:object_table]
    before_size = ot.objects.size
    new_idx = ot.intern(6)
    assert_equal before_size, new_idx, "new index should be the previous end-of-table"
    assert_equal before_size + 1, ot.objects.size
    assert_equal 6, ot.objects[new_idx]

    modified = Optimize::Codec.encode(ir)
    loaded = RubyVM::InstructionSequence.load_from_binary(modified)
    assert_kind_of RubyVM::InstructionSequence, loaded
    assert_equal 5, loaded.eval
  end

  def test_intern_appends_true_and_false_when_absent
    src = "def f; 1 + 2; end; f"
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]

    t_idx = ot.intern(true)
    f_idx = ot.intern(false)
    assert_equal true,  ot.objects[t_idx]
    assert_equal false, ot.objects[f_idx]

    modified = Optimize::Codec.encode(ir)
    loaded = RubyVM::InstructionSequence.load_from_binary(modified)
    assert_kind_of RubyVM::InstructionSequence, loaded
  end

  def test_unmodified_round_trip_still_byte_identical
    src = "def f; 2 + 3; end; f"
    original = RubyVM::InstructionSequence.compile(src).to_binary
    ir = Optimize::Codec.decode(original)
    assert_equal original, Optimize::Codec.encode(ir)
  end

  def test_intern_negative_integer_round_trips
    src = "def f; 2 + 3; end; f"
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    idx = ot.intern(-6)
    assert_equal(-6, ot.objects[idx])
    modified = Optimize::Codec.encode(ir)
    loaded = RubyVM::InstructionSequence.load_from_binary(modified)
    assert_kind_of RubyVM::InstructionSequence, loaded
  end

  def test_intern_appends_string_and_round_trips
    src = "def f; 2 + 3; end; f"
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    before_size = ot.objects.size

    idx = ot.intern("hello")
    assert_equal before_size, idx, "new index should be end-of-table"
    assert_equal "hello", ot.objects[idx]
    assert_predicate ot.objects[idx], :frozen?

    modified = Optimize::Codec.encode(ir)
    reloaded = Optimize::Codec.decode(modified)
    assert_equal "hello", reloaded.misc[:object_table].objects[idx]
    loaded = RubyVM::InstructionSequence.load_from_binary(modified)
    assert_kind_of RubyVM::InstructionSequence, loaded
    assert_equal 5, loaded.eval
  end

  def test_intern_string_returns_existing_index_when_literal_present
    src = 'def f; "already_here"; end; f'
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    existing = ot.index_for("already_here")
    refute_nil existing, "literal must exist in the table"
    before_size = ot.objects.size
    assert_equal existing, ot.intern("already_here")
    assert_equal before_size, ot.objects.size
  end

  def test_intern_still_rejects_arrays_and_hashes
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile("def f; 1; end; f").to_binary)
    ot = ir.misc[:object_table]
    assert_raises(ArgumentError) { ot.intern([1, 2]) }
    assert_raises(ArgumentError) { ot.intern({ a: 1 }) }
  end
end
