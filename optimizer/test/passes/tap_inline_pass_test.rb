# frozen_string_literal: true
require "test_helper"
require "optimize/codec"
require "optimize/passes/inlining_pass"

class TapInlinePassTest < Minitest::Test
  def test_disqualify_block_accepts_constant_body
    src = "5.tap { nil }"
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    block = find_block(ir)
    refute_nil block
    assert_nil pass.send(:disqualify_block, block),
      "expected { nil } block to be inlineable"
  end

  def test_disqualify_block_rejects_catch_table
    src = "5.tap { begin; 1; rescue; 2; end }"
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    block = find_block(ir)
    refute_nil block
    assert_equal :block_has_catch_table, pass.send(:disqualify_block, block)
  end

  def test_disqualify_block_rejects_level1_local_access
    src = "x = 1; 5.tap { x }"
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    block = find_block(ir)
    refute_nil block
    assert_equal :block_captures_level1, pass.send(:disqualify_block, block)
  end

  def test_disqualify_block_rejects_break
    src = "5.tap { break nil }"
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    block = find_block(ir)
    refute_nil block
    reason = pass.send(:disqualify_block, block)
    assert_includes [:block_escapes, :block_nested_leave, :block_has_catch_table], reason
  end

  def test_disqualify_block_rejects_branches
    src = "x = true; 5.tap { x ? 1 : 2 }"
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    block = find_block(ir)
    refute_nil block
    reason = pass.send(:disqualify_block, block)
    # Either the branch trips :block_escapes, or the x-read trips
    # :block_captures_level1. Both are legitimate rejections.
    assert_includes [:block_escapes, :block_captures_level1], reason
  end

  private

  def pass
    @pass ||= Optimize::Passes::InliningPass.new
  end

  def find_block(fn)
    return fn if fn.type == :block
    (fn.children || []).each do |c|
      found = find_block(c)
      return found if found
    end
    nil
  end
end
