# frozen_string_literal: true
require "test_helper"
require "ruby_opt/demo/claude/validator"
require "ruby_opt/ir/instruction"

class ValidatorTest < Minitest::Test
  FIXTURE_PATH = File.expand_path("../../../examples/claude_gag.rb", __dir__)
  FIXTURE = File.read(FIXTURE_PATH)

  def decode_method(source, method_name)
    iseq = RubyVM::InstructionSequence.compile(source)
    root = RubyOpt::Codec.decode(iseq.to_binary)
    object_table = root.misc[:object_table]
    target = find_function(root, method_name.to_s) or
      raise "method #{method_name} not found in iseq tree"
    [target, object_table]
  end

  def find_function(fn, name)
    return fn if fn.name == name
    (fn.children || []).each do |c|
      found = find_function(c, name)
      return found if found
    end
    nil
  end

  def answer_fn
    fn, _ot = decode_method(FIXTURE, :answer)
    fn
  end

  def test_structural_empty_for_clean_ir
    errors = RubyOpt::Demo::Claude::Validator.structural(answer_fn)
    assert_equal [], errors
  end

  def test_structural_reports_unknown_opcode
    fn = answer_fn
    fn.instructions << RubyOpt::IR::Instruction.new(opcode: :opt_fastmath, operands: [], line: nil)
    errors = RubyOpt::Demo::Claude::Validator.structural(fn)
    assert_equal 1, errors.size
    assert_includes errors[0], "opt_fastmath"
    assert_includes errors[0], "unknown"
  end

  def test_structural_reports_wrong_arity_too_few
    fn = answer_fn
    fn.instructions << RubyOpt::IR::Instruction.new(opcode: :putobject, operands: [], line: nil)
    errors = RubyOpt::Demo::Claude::Validator.structural(fn)
    assert_equal 1, errors.size
    assert_includes errors[0], "putobject"
    assert_includes errors[0], "1"
    assert_includes errors[0], "0"
  end

  def test_structural_reports_wrong_arity_too_many
    fn = answer_fn
    fn.instructions << RubyOpt::IR::Instruction.new(opcode: :leave, operands: [99], line: nil)
    errors = RubyOpt::Demo::Claude::Validator.structural(fn)
    assert_equal 1, errors.size
    assert_includes errors[0], "leave"
    assert_includes errors[0], "0"
    assert_includes errors[0], "1"
  end

  def test_structural_collects_multiple_errors
    fn = answer_fn
    fn.instructions << RubyOpt::IR::Instruction.new(opcode: :opt_fastmath, operands: [], line: nil)
    fn.instructions << RubyOpt::IR::Instruction.new(opcode: :putobject, operands: [], line: nil)
    errors = RubyOpt::Demo::Claude::Validator.structural(fn)
    assert_equal 2, errors.size
  end

  def test_structural_skips_arity_for_unknown_opcode
    fn = answer_fn
    fn.instructions << RubyOpt::IR::Instruction.new(opcode: :bogus, operands: [1, 2, 3], line: nil)
    errors = RubyOpt::Demo::Claude::Validator.structural(fn)
    assert_equal 1, errors.size
    assert_includes errors[0], "bogus"
    assert_includes errors[0], "unknown"
  end
end
