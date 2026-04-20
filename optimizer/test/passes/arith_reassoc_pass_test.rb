# frozen_string_literal: true
require "test_helper"
require "ruby_opt/codec"
require "ruby_opt/log"
require "ruby_opt/passes/arith_reassoc_pass"
require "ruby_opt/passes/literal_value"

class ArithReassocPassTest < Minitest::Test
  def test_collapses_leading_non_literal_chain_to_single_literal_tail
    src = "def f(x); x + 1 + 2 + 3; end; f(10)"
    ir = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    RubyOpt::Passes::ArithReassocPass.new.apply(f, type_env: nil, log: RubyOpt::Log.new, object_table: ot)

    opt_plus_count = f.instructions.count { |i| i.opcode == :opt_plus }
    assert_equal 1, opt_plus_count, "expected a single opt_plus after reassoc"
    lit_six = f.instructions.find { |i| RubyOpt::Passes::LiteralValue.read(i, object_table: ot) == 6 }
    refute_nil lit_six, "expected a literal 6 in the rewritten instructions"

    loaded = RubyVM::InstructionSequence.load_from_binary(RubyOpt::Codec.encode(ir))
    assert_equal 16, loaded.eval
  end

  def test_reorders_around_mid_chain_non_literal
    src = "def f(x); 1 + x + 2; end; f(10)"
    ir = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    RubyOpt::Passes::ArithReassocPass.new.apply(f, type_env: nil, log: RubyOpt::Log.new, object_table: ot)

    opt_plus_count = f.instructions.count { |i| i.opcode == :opt_plus }
    assert_equal 1, opt_plus_count
    refute_nil f.instructions.find { |i| RubyOpt::Passes::LiteralValue.read(i, object_table: ot) == 3 }

    loaded = RubyVM::InstructionSequence.load_from_binary(RubyOpt::Codec.encode(ir))
    assert_equal 13, loaded.eval
  end

  def test_multiple_non_literals_preserved_in_original_order
    src = "def f(x, y); 1 + x + 2 + y + 3; end; f(10, 20)"
    ir = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    RubyOpt::Passes::ArithReassocPass.new.apply(f, type_env: nil, log: RubyOpt::Log.new, object_table: ot)

    opt_plus_count = f.instructions.count { |i| i.opcode == :opt_plus }
    assert_equal 2, opt_plus_count, "3 operands after reassoc => 2 opt_pluses"
    refute_nil f.instructions.find { |i| RubyOpt::Passes::LiteralValue.read(i, object_table: ot) == 6 }

    producers = f.instructions.select { |i| %i[getlocal getlocal_WC_0 getlocal_WC_1].include?(i.opcode) }
    assert_equal 2, producers.size
    loaded = RubyVM::InstructionSequence.load_from_binary(RubyOpt::Codec.encode(ir))
    assert_equal 36, loaded.eval
  end

  def test_single_literal_chain_is_left_alone
    src = "def f(x); x + 1; end; f(10)"
    ir = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    before = f.instructions.map(&:opcode)
    RubyOpt::Passes::ArithReassocPass.new.apply(f, type_env: nil, log: RubyOpt::Log.new, object_table: ot)
    assert_equal before, f.instructions.map(&:opcode)
  end

  def test_no_literals_chain_is_left_alone
    src = "def f(x, y, z); x + y + z; end; f(1, 2, 3)"
    ir = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    before = f.instructions.map(&:opcode)
    RubyOpt::Passes::ArithReassocPass.new.apply(f, type_env: nil, log: RubyOpt::Log.new, object_table: ot)
    assert_equal before, f.instructions.map(&:opcode)
  end

  def test_all_literal_chain_is_left_to_const_fold
    src = "def f; 1 + 2 + 3; end; f"
    ir = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    RubyOpt::Passes::ArithReassocPass.new.apply(f, type_env: nil, log: RubyOpt::Log.new, object_table: ot)
    assert_equal 0, f.instructions.count { |i| i.opcode == :opt_plus }
    refute_nil f.instructions.find { |i| RubyOpt::Passes::LiteralValue.read(i, object_table: ot) == 6 }
    loaded = RubyVM::InstructionSequence.load_from_binary(RubyOpt::Codec.encode(ir))
    assert_equal 6, loaded.eval
  end

  def test_non_opt_plus_chains_untouched
    src = "def f(x); x * 2 * 3; end; f(4)"
    ir = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    before = f.instructions.map(&:opcode)
    RubyOpt::Passes::ArithReassocPass.new.apply(f, type_env: nil, log: RubyOpt::Log.new, object_table: ot)
    assert_equal before, f.instructions.map(&:opcode)
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
