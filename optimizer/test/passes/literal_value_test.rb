# frozen_string_literal: true
require "test_helper"
require "ruby_opt/codec"
require "ruby_opt/passes/literal_value"

class LiteralValueTest < Minitest::Test
  def test_read_plain_putobject_resolves_via_object_table
    ir = RubyOpt::Codec.decode(
      RubyVM::InstructionSequence.compile("def f; 2; end; f").to_binary
    )
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    po = f.instructions.find { |i| i.opcode == :putobject }
    refute_nil po, "expected a plain putobject for literal 2"
    assert_equal 2, RubyOpt::Passes::LiteralValue.read(po, object_table: ot)
  end

  def test_read_handles_dedicated_0_and_1_opcodes
    ir = RubyOpt::Codec.decode(
      RubyVM::InstructionSequence.compile("def f; 0; end; def g; 1; end").to_binary
    )
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    g = find_iseq(ir, "g")
    zero = f.instructions.find { |i| i.opcode == :putobject_INT2FIX_0_ }
    one  = g.instructions.find { |i| i.opcode == :putobject_INT2FIX_1_ }
    refute_nil zero, "expected a putobject_INT2FIX_0_"
    refute_nil one,  "expected a putobject_INT2FIX_1_"
    assert_equal 0, RubyOpt::Passes::LiteralValue.read(zero, object_table: ot)
    assert_equal 1, RubyOpt::Passes::LiteralValue.read(one, object_table: ot)
  end

  def test_read_returns_nil_for_non_literal_producer
    ir = RubyOpt::Codec.decode(
      RubyVM::InstructionSequence.compile("def f; x = 1; x; end").to_binary
    )
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    getlocal = f.instructions.find { |i| i.opcode.to_s.start_with?("getlocal") }
    refute_nil getlocal
    assert_nil RubyOpt::Passes::LiteralValue.read(getlocal, object_table: ot)
  end

  def test_read_putchilledstring_resolves_to_string
    # YARV 4.0.2 emits putchilledstring for frozen-by-default string literals.
    ir = RubyOpt::Codec.decode(
      RubyVM::InstructionSequence.compile('def f; "hello"; end; f').to_binary
    )
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    sp = f.instructions.find { |i| i.opcode == :putchilledstring || i.opcode == :putstring }
    refute_nil sp, "expected a string-pushing opcode for \"hello\""
    assert_equal "hello", RubyOpt::Passes::LiteralValue.read(sp, object_table: ot)
    assert RubyOpt::Passes::LiteralValue.literal?(sp)
  end

  def test_read_putnil_returns_nil_value
    ir = RubyOpt::Codec.decode(
      RubyVM::InstructionSequence.compile("def f; nil; end").to_binary
    )
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    pn = f.instructions.find { |i| i.opcode == :putnil }
    refute_nil pn, "expected a putnil"
    # putnil's pushed value is nil — indistinguishable by return value from
    # "unrecognized opcode". The literal? predicate disambiguates.
    assert_nil RubyOpt::Passes::LiteralValue.read(pn, object_table: ot)
    assert RubyOpt::Passes::LiteralValue.literal?(pn)
  end

  def test_literal_predicate_false_for_non_literal_producer
    ir = RubyOpt::Codec.decode(
      RubyVM::InstructionSequence.compile("def f; x = 1; x; end").to_binary
    )
    f = find_iseq(ir, "f")
    getlocal = f.instructions.find { |i| i.opcode.to_s.start_with?("getlocal") }
    refute_nil getlocal
    refute RubyOpt::Passes::LiteralValue.literal?(getlocal)
  end

  def test_emit_prefers_dedicated_opcodes_for_0_and_1
    ir = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile("nil").to_binary)
    ot = ir.misc[:object_table]
    zero = RubyOpt::Passes::LiteralValue.emit(0, line: 42, object_table: ot)
    one  = RubyOpt::Passes::LiteralValue.emit(1, line: 42, object_table: ot)
    assert_equal :putobject_INT2FIX_0_, zero.opcode
    assert_equal :putobject_INT2FIX_1_, one.opcode
    assert_empty zero.operands
    assert_empty one.operands
    assert_equal 42, zero.line
    assert_equal 42, one.line
  end

  def test_emit_interns_arbitrary_integer_and_is_readable
    ir = RubyOpt::Codec.decode(
      RubyVM::InstructionSequence.compile("def f; 2 + 3; end; f").to_binary
    )
    ot = ir.misc[:object_table]
    inst = RubyOpt::Passes::LiteralValue.emit(42, line: 7, object_table: ot)
    assert_equal :putobject, inst.opcode
    assert_equal 1, inst.operands.size
    assert_equal 42, ot.objects[inst.operands[0]]
    assert_equal 42, RubyOpt::Passes::LiteralValue.read(inst, object_table: ot)
    assert_equal 7, inst.line
  end

  def test_emit_true_and_false_via_intern
    ir = RubyOpt::Codec.decode(
      RubyVM::InstructionSequence.compile("def f; 1; end").to_binary
    )
    ot = ir.misc[:object_table]
    t = RubyOpt::Passes::LiteralValue.emit(true,  line: 1, object_table: ot)
    f = RubyOpt::Passes::LiteralValue.emit(false, line: 1, object_table: ot)
    assert_equal :putobject, t.opcode
    assert_equal :putobject, f.opcode
    assert_equal true,  RubyOpt::Passes::LiteralValue.read(t, object_table: ot)
    assert_equal false, RubyOpt::Passes::LiteralValue.read(f, object_table: ot)
  end

  def test_emit_reuses_existing_index_when_value_already_in_table
    ir = RubyOpt::Codec.decode(
      RubyVM::InstructionSequence.compile("def f; 2 + 3; end; f").to_binary
    )
    ot = ir.misc[:object_table]
    before_size = ot.objects.size
    inst = RubyOpt::Passes::LiteralValue.emit(3, line: 1, object_table: ot)
    assert_equal before_size, ot.objects.size
    assert_equal 3, ot.objects[inst.operands[0]]
  end

  def test_emit_round_trips_through_codec
    src = "def f; 2 + 3; end; f"
    ir = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    assert_equal(
      RubyVM::InstructionSequence.compile(src).to_binary,
      RubyOpt::Codec.encode(ir),
    )
    _unused = RubyOpt::Passes::LiteralValue.emit(99, line: 1, object_table: ot)
    loaded = RubyVM::InstructionSequence.load_from_binary(RubyOpt::Codec.encode(ir))
    assert_kind_of RubyVM::InstructionSequence, loaded
  end

  private

  def find_iseq(ir, name)
    return ir if ir.name == name
    ir.children&.each do |c|
      found = find_iseq(c, name)
      return found if found
    end
    nil
  end
end
