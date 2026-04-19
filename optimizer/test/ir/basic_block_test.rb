# frozen_string_literal: true
require "test_helper"
require "ruby_opt/ir/basic_block"
require "ruby_opt/ir/instruction"

class BasicBlockTest < Minitest::Test
  def test_holds_instructions_in_order
    insns = [
      RubyOpt::IR::Instruction.new(opcode: :putobject, operands: [1], line: 1),
      RubyOpt::IR::Instruction.new(opcode: :leave, operands: [], line: 1),
    ]
    bb = RubyOpt::IR::BasicBlock.new(id: 0, instructions: insns)
    assert_equal 0, bb.id
    assert_equal 2, bb.instructions.size
    assert_equal :leave, bb.terminator.opcode
  end

  def test_terminator_is_last_instruction
    insns = [
      RubyOpt::IR::Instruction.new(opcode: :putobject, operands: [1], line: 1),
      RubyOpt::IR::Instruction.new(opcode: :branchif, operands: [10], line: 1),
    ]
    bb = RubyOpt::IR::BasicBlock.new(id: 1, instructions: insns)
    assert_equal :branchif, bb.terminator.opcode
  end

  def test_empty_block_has_nil_terminator
    bb = RubyOpt::IR::BasicBlock.new(id: 2, instructions: [])
    assert_nil bb.terminator
  end
end
