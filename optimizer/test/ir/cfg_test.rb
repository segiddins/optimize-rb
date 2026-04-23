# frozen_string_literal: true
require "test_helper"
require "optimize/codec"
require "optimize/ir/cfg"

class CfgTest < Minitest::Test
  def test_straight_line_function_has_one_block
    src = "def f; 1 + 2; end"
    ir = Optimize::Codec.decode(
      RubyVM::InstructionSequence.compile(src).to_binary
    )
    f = ir.children.find { |c| c.name == "f" }
    cfg = f.cfg
    assert_equal 1, cfg.blocks.size
    assert_equal :leave, cfg.blocks.first.terminator.opcode
    assert_empty cfg.successors(cfg.blocks.first)
  end

  def test_conditional_produces_two_successors
    src = "def f(x); if x then 1 else 2 end; end"
    ir = Optimize::Codec.decode(
      RubyVM::InstructionSequence.compile(src).to_binary
    )
    f = ir.children.find { |c| c.name == "f" }
    cfg = f.cfg
    # At least one block whose terminator is a branch, with 2 successors.
    branch_block = cfg.blocks.find { |b|
      b.terminator && %i[branchif branchunless branchnil].include?(b.terminator.opcode)
    }
    refute_nil branch_block, "expected a conditional-branch block, got terminators: #{cfg.blocks.map { |b| b.terminator&.opcode }.inspect}"
    assert_equal 2, cfg.successors(branch_block).size
  end

  def test_predecessors_are_inverse_of_successors
    src = "def f(x); if x then 1 else 2 end; end"
    ir = Optimize::Codec.decode(
      RubyVM::InstructionSequence.compile(src).to_binary
    )
    f = ir.children.find { |c| c.name == "f" }
    cfg = f.cfg
    cfg.blocks.each do |b|
      cfg.successors(b).each do |succ|
        assert_includes cfg.predecessors(succ), b,
          "predecessors(#{succ.id}) missing #{b.id}"
      end
    end
  end
end
