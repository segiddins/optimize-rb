# frozen_string_literal: true
require "test_helper"
require "ruby_opt/codec"
require "ruby_opt/log"
require "ruby_opt/passes/identity_elim_pass"
require "ruby_opt/passes/literal_value"

class IdentityElimPassTest < Minitest::Test
  IDENTITY_ARITH_OPCODES = %i[opt_plus opt_mult opt_minus opt_div].freeze

  def test_mult_right_identity_eliminated
    src = "def f(x); x * 1; end; f(7)"
    ir = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    log = RubyOpt::Log.new
    RubyOpt::Passes::IdentityElimPass.new.apply(f, type_env: nil, log: log, object_table: ot)

    assert_equal 0, f.instructions.count { |i| i.opcode == :opt_mult }
    assert_equal 0, f.instructions.count { |i|
      RubyOpt::Passes::LiteralValue.literal?(i) &&
        RubyOpt::Passes::LiteralValue.read(i, object_table: ot) == 1
    }
    assert(log.entries.any? { |e| e.reason == :identity_eliminated })

    loaded = RubyVM::InstructionSequence.load_from_binary(RubyOpt::Codec.encode(ir))
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
    ir = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    log = RubyOpt::Log.new
    RubyOpt::Passes::IdentityElimPass.new.apply(f, type_env: nil, log: log, object_table: ot)

    assert_equal 0, f.instructions.count { |i| i.opcode == :opt_mult }
    assert_equal 3, log.entries.count { |e| e.reason == :identity_eliminated }

    loaded = RubyVM::InstructionSequence.load_from_binary(RubyOpt::Codec.encode(ir))
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
    ir = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    before = f.instructions.map(&:opcode)
    log = RubyOpt::Log.new
    RubyOpt::Passes::IdentityElimPass.new.apply(f, type_env: nil, log: log, object_table: ot)
    assert_equal before, f.instructions.map(&:opcode)
    assert(log.entries.none? { |e| e.reason == :identity_eliminated })
  end

  def test_send_producer_not_eliminated
    src = "def f(x); x.succ * 1; end; f(6)"
    ir = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    before = f.instructions.map(&:opcode)
    RubyOpt::Passes::IdentityElimPass.new.apply(f, type_env: nil, log: RubyOpt::Log.new, object_table: ot)
    assert_equal before, f.instructions.map(&:opcode)
  end

  def test_idempotent_on_already_collapsed
    src = "def f(x); x * 1; end; f(7)"
    ir = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    pass = RubyOpt::Passes::IdentityElimPass.new
    pass.apply(f, type_env: nil, log: RubyOpt::Log.new, object_table: ot)
    first = f.instructions.map(&:opcode)
    pass.apply(f, type_env: nil, log: RubyOpt::Log.new, object_table: ot)
    second = f.instructions.map(&:opcode)
    assert_equal first, second
  end

  private

  def assert_collapses_to_x(src, result:)
    ir = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    log = RubyOpt::Log.new
    RubyOpt::Passes::IdentityElimPass.new.apply(f, type_env: nil, log: log, object_table: ot)

    remaining_arith = f.instructions.count { |i| IDENTITY_ARITH_OPCODES.include?(i.opcode) }
    assert_equal 0, remaining_arith, "expected all IDENTITY_OPS opcodes stripped from #{src}"
    assert(log.entries.any? { |e| e.reason == :identity_eliminated })

    loaded = RubyVM::InstructionSequence.load_from_binary(RubyOpt::Codec.encode(ir))
    assert_equal result, loaded.eval
  end

  def assert_unchanged(src, expected_eval:)
    ir = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    before = f.instructions.map(&:opcode)
    log = RubyOpt::Log.new
    RubyOpt::Passes::IdentityElimPass.new.apply(f, type_env: nil, log: log, object_table: ot)
    assert_equal before, f.instructions.map(&:opcode)
    assert(log.entries.none? { |e| e.reason == :identity_eliminated })
    loaded = RubyVM::InstructionSequence.load_from_binary(RubyOpt::Codec.encode(ir))
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
