# frozen_string_literal: true
require "test_helper"
require "ruby_opt/codec"
require "ruby_opt/log"
require "ruby_opt/passes/const_fold_pass"

class ConstFoldPassTest < Minitest::Test
  def test_folds_single_arithmetic_triple
    ir = RubyOpt::Codec.decode(
      RubyVM::InstructionSequence.compile("def f; 2 + 3; end; f").to_binary
    )
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    before_count = f.instructions.size
    log = RubyOpt::Log.new
    RubyOpt::Passes::ConstFoldPass.new.apply(f, type_env: nil, log: log, object_table: ot)
    assert_equal before_count - 2, f.instructions.size
    folded = f.instructions.find { |i| RubyOpt::Passes::LiteralValue.read(i, object_table: ot) == 5 }
    refute_nil folded, "expected a literal producer for 5 after the fold"
  end

  def test_folded_iseq_runs_and_returns_expected_value
    src = "def f; 2 + 3; end; f"
    ir = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    RubyOpt::Passes::ConstFoldPass.new.apply(find_iseq(ir, "f"), type_env: nil, log: RubyOpt::Log.new, object_table: ot)
    loaded = RubyVM::InstructionSequence.load_from_binary(RubyOpt::Codec.encode(ir))
    assert_equal 5, loaded.eval
  end

  def test_leaves_non_literal_operands_alone
    ir = RubyOpt::Codec.decode(
      RubyVM::InstructionSequence.compile("def f(x); x + 2; end").to_binary
    )
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    before = f.instructions.map(&:opcode)
    RubyOpt::Passes::ConstFoldPass.new.apply(f, type_env: nil, log: RubyOpt::Log.new, object_table: ot)
    assert_equal before, f.instructions.map(&:opcode)
  end

  def test_folds_integer_comparison_to_boolean
    ir = RubyOpt::Codec.decode(
      RubyVM::InstructionSequence.compile("def f; 5 < 10; end; f").to_binary
    )
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    RubyOpt::Passes::ConstFoldPass.new.apply(f, type_env: nil, log: RubyOpt::Log.new, object_table: ot)
    folded = f.instructions.find { |i| RubyOpt::Passes::LiteralValue.read(i, object_table: ot) == true }
    refute_nil folded
    loaded = RubyVM::InstructionSequence.load_from_binary(RubyOpt::Codec.encode(ir))
    assert_equal true, loaded.eval
  end

  def test_folds_integer_equality
    ir = RubyOpt::Codec.decode(
      RubyVM::InstructionSequence.compile("def f; 5 == 5; end; def g; 5 == 6; end").to_binary
    )
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    g = find_iseq(ir, "g")
    pass = RubyOpt::Passes::ConstFoldPass.new
    pass.apply(f, type_env: nil, log: RubyOpt::Log.new, object_table: ot)
    pass.apply(g, type_env: nil, log: RubyOpt::Log.new, object_table: ot)
    assert(f.instructions.any? { |i| RubyOpt::Passes::LiteralValue.read(i, object_table: ot) == true })
    assert(g.instructions.any? { |i| RubyOpt::Passes::LiteralValue.read(i, object_table: ot) == false })
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
