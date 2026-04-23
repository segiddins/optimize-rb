# frozen_string_literal: true
require "test_helper"
require "ruby_opt/demo/claude/validator"
require "ruby_opt/ir/instruction"
require "ruby_opt/codec"

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

  def load_envelope(fixture_path)
    source = File.read(fixture_path)
    iseq = RubyVM::InstructionSequence.compile(source, fixture_path, fixture_path)
    RubyOpt::Codec.decode(iseq.to_binary)
  end

  def teardown
    Object.send(:remove_method, :answer) if Object.private_method_defined?(:answer) || Object.method_defined?(:answer)
  rescue NameError
    nil
  end

  def test_semantic_passes_on_clean_envelope
    envelope = load_envelope(FIXTURE_PATH)
    errors = RubyOpt::Demo::Claude::Validator.semantic(envelope, cases: [["answer", 5]])
    assert_equal [], errors
  end

  def test_semantic_reports_wrong_return_value
    envelope = load_envelope(FIXTURE_PATH)
    errors = RubyOpt::Demo::Claude::Validator.semantic(envelope, cases: [["answer", 999]])
    assert_equal 1, errors.size
    assert_includes errors[0], "999"
    assert(errors[0].include?("5") || errors[0].include?("returned"),
           "expected error to include \"5\" or \"returned\", got: #{errors[0].inspect}")
  end

  def test_semantic_reports_runtime_error
    envelope = load_envelope(FIXTURE_PATH)
    answer_child = find_function(envelope, "answer") or raise "no answer fn"
    # Inject an unknown opcode so RubyOpt::Codec.encode raises before we
    # reach the VM. (Deleting :leave, as originally suggested, would segfault
    # this Ruby rather than raise — and a bare rescue cannot catch SEGV.)
    answer_child.instructions << RubyOpt::IR::Instruction.new(opcode: :opt_fastmath, operands: [], line: nil)
    errors = RubyOpt::Demo::Claude::Validator.semantic(envelope, cases: [["answer", 5]])
    assert_equal 1, errors.size, "got: #{errors.inspect}"
    assert(errors[0].start_with?("loader/runtime error"),
           "expected error to start with loader/runtime error, got: #{errors[0].inspect}")
  end

  def test_semantic_reports_one_error_per_failing_case
    envelope = load_envelope(FIXTURE_PATH)
    errors = RubyOpt::Demo::Claude::Validator.semantic(envelope, cases: [
      ["answer", 5],
      ["answer", 999],
      ["answer", 777],
    ])
    assert_equal 2, errors.size, "got: #{errors.inspect}"
    assert(errors.any? { |e| e.include?("999") })
    assert(errors.any? { |e| e.include?("777") })
  end

  def test_semantic_rejects_empty_cases
    envelope = load_envelope(FIXTURE_PATH)
    assert_raises(ArgumentError) do
      RubyOpt::Demo::Claude::Validator.semantic(envelope, cases: [])
    end
  end

  def test_structural_reports_missing_final_leave
    fn = answer_fn
    fn.instructions = [
      RubyOpt::IR::Instruction.new(opcode: :putobject, operands: [5], line: nil),
    ]
    errors = RubyOpt::Demo::Claude::Validator.structural(fn)
    assert errors.any? { |e| e.include?(":leave") }, "got: #{errors.inspect}"
  end

  def test_structural_reports_stack_underflow
    fn = answer_fn
    fn.instructions = [
      RubyOpt::IR::Instruction.new(opcode: :pop, operands: [], line: nil),
      RubyOpt::IR::Instruction.new(opcode: :putobject, operands: [5], line: nil),
      RubyOpt::IR::Instruction.new(opcode: :leave, operands: [], line: nil),
    ]
    errors = RubyOpt::Demo::Claude::Validator.structural(fn)
    assert errors.any? { |e| e.include?("depth") }, "got: #{errors.inspect}"
  end

  def test_structural_reports_leftover_on_stack
    fn = answer_fn
    fn.instructions = [
      # Leaves TWO values on stack before leave (leave only pops 1).
      RubyOpt::IR::Instruction.new(opcode: :putobject, operands: [1], line: nil),
      RubyOpt::IR::Instruction.new(opcode: :putobject, operands: [2], line: nil),
      RubyOpt::IR::Instruction.new(opcode: :leave, operands: [], line: nil),
    ]
    errors = RubyOpt::Demo::Claude::Validator.structural(fn)
    assert errors.any? { |e| e.include?("final stack depth") }, "got: #{errors.inspect}"
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
