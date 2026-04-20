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
