# frozen_string_literal: true
require "test_helper"
require "optimize/codec"
require "optimize/log"
require "optimize/passes/identity_elim_pass"
require "optimize/passes/literal_value"

class IdentityElimPassTest < Minitest::Test
  IDENTITY_ARITH_OPCODES = %i[opt_plus opt_mult opt_minus opt_div].freeze

  def test_mult_right_identity_eliminated
    src = "def f(x); x * 1; end; f(7)"
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    log = Optimize::Log.new
    Optimize::Passes::IdentityElimPass.new.apply(f, type_env: nil, log: log, object_table: ot)

    assert_equal 0, f.instructions.count { |i| i.opcode == :opt_mult }
    assert_equal 0, f.instructions.count { |i|
      Optimize::Passes::LiteralValue.literal?(i) &&
        Optimize::Passes::LiteralValue.read(i, object_table: ot) == 1
    }
    assert(log.entries.any? { |e| e.reason == :identity_eliminated })

    loaded = RubyVM::InstructionSequence.load_from_binary(Optimize::Codec.encode(ir))
    assert_equal 7, loaded.eval
  end

  def test_mult_left_identity_eliminated
    assert_collapses_to_x("def f(x); 1 * x; end; f(7)", result: 7)
  end

  def test_plus_right_identity_eliminated
    assert_collapses_to_x("def f(x); x + 0; end; f(7)", result: 7)
  end

  def test_plus_left_identity_eliminated
    assert_collapses_to_x("def f(x); 0 + x; end; f(7)", result: 7)
  end

  def test_minus_right_identity_eliminated
    assert_collapses_to_x("def f(x); x - 0; end; f(7)", result: 7)
  end

  def test_minus_left_identity_not_eliminated
    # 0 - x = -x, NOT x.
    assert_unchanged("def f(x); 0 - x; end; f(7)", expected_eval: -7)
  end

  def test_div_right_identity_eliminated
    assert_collapses_to_x("def f(x); x / 1; end; f(7)", result: 7)
  end

  def test_div_left_identity_not_eliminated
    # 1 / x ≠ x.
    assert_unchanged("def f(x); 1 / x; end; f(7)", expected_eval: 0)
  end

  def test_fixpoint_cascade
    src = "def f(x); x * 1 * 1 * 1; end; f(42)"
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    log = Optimize::Log.new
    Optimize::Passes::IdentityElimPass.new.apply(f, type_env: nil, log: log, object_table: ot)

    assert_equal 0, f.instructions.count { |i| i.opcode == :opt_mult }
    assert_equal 3, log.entries.count { |e| e.reason == :identity_eliminated }

    loaded = RubyVM::InstructionSequence.load_from_binary(Optimize::Codec.encode(ir))
    assert_equal 42, loaded.eval
  end

  def test_float_identity_not_eliminated
    assert_unchanged("def f(x); x * 1.0; end; f(7)", expected_eval: 7.0)
  end

  def test_float_zero_not_eliminated
    assert_unchanged("def f(x); x + 0.0; end; f(7)", expected_eval: 7.0)
  end

  def test_absorbing_zero_not_eliminated
    src = "def f(x); x * 0; end; f(7)"
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    before = f.instructions.map(&:opcode)
    log = Optimize::Log.new
    Optimize::Passes::IdentityElimPass.new.apply(f, type_env: nil, log: log, object_table: ot)
    assert_equal before, f.instructions.map(&:opcode)
    assert(log.entries.none? { |e| e.reason == :identity_eliminated })
  end

  def test_send_producer_not_eliminated
    src = "def f(x); x.succ * 1; end; f(6)"
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    before = f.instructions.map(&:opcode)
    Optimize::Passes::IdentityElimPass.new.apply(f, type_env: nil, log: Optimize::Log.new, object_table: ot)
    assert_equal before, f.instructions.map(&:opcode)
  end

  def test_idempotent_on_already_collapsed
    src = "def f(x); x * 1; end; f(7)"
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    pass = Optimize::Passes::IdentityElimPass.new
    pass.apply(f, type_env: nil, log: Optimize::Log.new, object_table: ot)
    first = f.instructions.map(&:opcode)
    pass.apply(f, type_env: nil, log: Optimize::Log.new, object_table: ot)
    second = f.instructions.map(&:opcode)
    assert_equal first, second
  end

  def test_pipeline_collapses_v4_boundary_fully
    require "optimize/pipeline"
    src = "def f(x); 2 * 3 / 6 * x; end; f(42)"
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    Optimize::Pipeline.default.run(ir, type_env: nil)
    f = find_iseq(ir, "f")

    remaining_arith = f.instructions.count { |i|
      IDENTITY_ARITH_OPCODES.include?(i.opcode)
    }
    assert_equal 0, remaining_arith,
      "expected no arith opcodes after pipeline; got #{f.instructions.map(&:opcode).inspect}"

    loaded = RubyVM::InstructionSequence.load_from_binary(Optimize::Codec.encode(ir))
    assert_equal 42, loaded.eval
  end

  private

  def assert_collapses_to_x(src, result:)
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    log = Optimize::Log.new
    Optimize::Passes::IdentityElimPass.new.apply(f, type_env: nil, log: log, object_table: ot)

    remaining_arith = f.instructions.count { |i| IDENTITY_ARITH_OPCODES.include?(i.opcode) }
    assert_equal 0, remaining_arith, "expected all IDENTITY_OPS opcodes stripped from #{src}"
    assert(log.entries.any? { |e| e.reason == :identity_eliminated })

    loaded = RubyVM::InstructionSequence.load_from_binary(Optimize::Codec.encode(ir))
    assert_equal result, loaded.eval
  end

  def assert_unchanged(src, expected_eval:)
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    before = f.instructions.map(&:opcode)
    log = Optimize::Log.new
    Optimize::Passes::IdentityElimPass.new.apply(f, type_env: nil, log: log, object_table: ot)
    assert_equal before, f.instructions.map(&:opcode)
    assert(log.entries.none? { |e| e.reason == :identity_eliminated })
    loaded = RubyVM::InstructionSequence.load_from_binary(Optimize::Codec.encode(ir))
    assert_equal expected_eval, loaded.eval
  end

  def find_iseq(ir, name)
    return ir if ir.name == name
    ir.children&.each do |c|
      found = find_iseq(c, name)
      return found if found
    end
    nil
  end
end
