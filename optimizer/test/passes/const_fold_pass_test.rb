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

  def test_folds_deep_integer_chain_to_single_literal
    src = "def f; 1 + 2 + 3 + 4 + 5; end; f"
    ir = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    log = RubyOpt::Log.new
    RubyOpt::Passes::ConstFoldPass.new.apply(f, type_env: nil, log: log, object_table: ot)
    folded = f.instructions.find { |i| RubyOpt::Passes::LiteralValue.read(i, object_table: ot) == 15 }
    refute_nil folded, "expected the whole chain to fold to 15"
    loaded = RubyVM::InstructionSequence.load_from_binary(RubyOpt::Codec.encode(ir))
    assert_equal 15, loaded.eval
  end

  def test_partial_chain_fold_when_a_non_literal_breaks_it
    src = "def f(x); 1 + 2 + x + 3 + 4; end; f(10)"
    ir = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    RubyOpt::Passes::ConstFoldPass.new.apply(f, type_env: nil, log: RubyOpt::Log.new, object_table: ot)
    values = f.instructions.filter_map { |i| RubyOpt::Passes::LiteralValue.read(i, object_table: ot) }
    # The leading `1 + 2` folds to 3. The trailing `+ 3 + 4` cannot fold further
    # because YARV emits each `+ N` interleaved with its own opt_plus, so no
    # `putobject N; putobject M; opt_plus` triple ever forms after the break.
    assert_includes values, 3
    refute_includes values, 1
    refute_includes values, 2
    loaded = RubyVM::InstructionSequence.load_from_binary(RubyOpt::Codec.encode(ir))
    assert_equal 20, loaded.eval  # 3 + 10 + 3 + 4 == 20
  end

  def test_logs_folded_reason_for_each_successful_fold
    src = "def f; 1 + 2 + 3; end; f"
    ir = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    log = RubyOpt::Log.new
    RubyOpt::Passes::ConstFoldPass.new.apply(find_iseq(ir, "f"), type_env: nil, log: log, object_table: ot)
    folded_entries = log.for_pass(:const_fold).select { |e| e.reason == :folded }
    # 1+2 -> 3, then 3+3 -> 6 (folded triples in sequence)
    assert_operator folded_entries.size, :>=, 2
  end

  def test_logs_would_raise_for_division_by_zero
    src = "def f; 1 / 0; end"
    ir = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    before = f.instructions.map(&:opcode)
    log = RubyOpt::Log.new
    RubyOpt::Passes::ConstFoldPass.new.apply(f, type_env: nil, log: log, object_table: ot)
    # The triple is left alone.
    assert_equal before, f.instructions.map(&:opcode)
    skipped = log.for_pass(:const_fold).select { |e| e.reason == :would_raise }
    assert_operator skipped.size, :>=, 1, "expected a :would_raise skip entry"
  end

  def test_logs_non_integer_literal_when_string_operand_reaches_an_arith_op
    # LiteralValue now recognizes putchilledstring, so both operands resolve
    # as literals but neither is an Integer — triggers :non_integer_literal.
    src = 'def f; "a" + "b"; end'
    ir = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    log = RubyOpt::Log.new
    RubyOpt::Passes::ConstFoldPass.new.apply(f, type_env: nil, log: log, object_table: ot)
    skipped = log.for_pass(:const_fold).select { |e| e.reason == :non_integer_literal }
    assert_operator skipped.size, :>=, 1
  end

  def test_folds_triple_inside_a_then_branch_without_breaking_else_branch_targets
    src = "def f(c); if c; 1 + 2; else; 99; end; end; [f(true), f(false)]"
    ir = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    RubyOpt::Passes::ConstFoldPass.new.apply(find_iseq(ir, "f"), type_env: nil, log: RubyOpt::Log.new, object_table: ot)
    # The encoder used to raise "OFFSET operand X has no corresponding slot" here
    # because the splice shrank `insts` without adjusting the branchunless target.
    loaded = RubyVM::InstructionSequence.load_from_binary(RubyOpt::Codec.encode(ir))
    assert_equal [3, 99], loaded.eval
  end

  def test_folds_string_equality_triple_to_true
    src = 'def f; "abc" == "abc"; end; f'
    ir = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    RubyOpt::Passes::ConstFoldPass.new.apply(f, type_env: nil, log: RubyOpt::Log.new, object_table: ot)
    assert(f.instructions.any? { |i| RubyOpt::Passes::LiteralValue.read(i, object_table: ot) == true })
    loaded = RubyVM::InstructionSequence.load_from_binary(RubyOpt::Codec.encode(ir))
    assert_equal true, loaded.eval
  end

  def test_folds_string_equality_triple_to_false
    src = 'def f; "abc" == "def"; end'
    ir = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    RubyOpt::Passes::ConstFoldPass.new.apply(f, type_env: nil, log: RubyOpt::Log.new, object_table: ot)
    assert(f.instructions.any? { |i| RubyOpt::Passes::LiteralValue.read(i, object_table: ot) == false })
  end

  def test_folds_string_inequality_triple
    src = 'def f; "a" != "b"; end; f'
    ir = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    RubyOpt::Passes::ConstFoldPass.new.apply(f, type_env: nil, log: RubyOpt::Log.new, object_table: ot)
    assert(f.instructions.any? { |i| RubyOpt::Passes::LiteralValue.read(i, object_table: ot) == true })
    loaded = RubyVM::InstructionSequence.load_from_binary(RubyOpt::Codec.encode(ir))
    assert_equal true, loaded.eval
  end

  def test_leaves_mixed_type_equality_alone
    # "a" == 5 — both are literals but types differ; skip fold (not Integer-Integer, not String-String).
    src = 'def f; "a" == 5; end'
    ir = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
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
