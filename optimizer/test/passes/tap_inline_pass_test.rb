# frozen_string_literal: true
require "test_helper"
require "optimize/codec"
require "optimize/log"
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

  def test_disqualify_callee_for_send_with_block_accepts_tap_body
    src = <<~RUBY
      def tap; yield self; self; end
      5.tap { nil }
    RUBY
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    callee = find_iseq(ir, "tap")
    refute_nil callee
    assert_nil pass.send(:disqualify_callee_for_send_with_block, callee)
  end

  def test_disqualify_callee_for_send_with_block_rejects_invokesuper
    src = <<~RUBY
      class A; def tap; super; end; end
      A.new.tap { nil }
    RUBY
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    callee = find_iseq(ir, "tap")
    refute_nil callee
    assert_equal :callee_uses_super, pass.send(:disqualify_callee_for_send_with_block, callee)
  end

  def test_disqualify_callee_for_send_with_block_rejects_nested_block_send
    src = <<~RUBY
      def tap; yield self; [1].each { |x| x }; end
      5.tap { nil }
    RUBY
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    callee = find_iseq(ir, "tap")
    refute_nil callee
    assert_equal :callee_send_has_block, pass.send(:disqualify_callee_for_send_with_block, callee)
  end

  def test_substitute_invokeblocks_replaces_invokeblock_with_block_body
    src = <<~RUBY
      def tap; yield self; self; end
      5.tap { nil }
    RUBY
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    callee = find_iseq(ir, "tap")
    block  = find_block(ir)
    body   = callee.instructions[0..-2]  # drop trailing leave

    rewritten = pass.send(
      :substitute_invokeblocks,
      body, block, stash_base_lindex: 4,
    )

    # Before: putself; invokeblock argc:1; pop; putself
    # After : putself; setlocal_WC_0 <A0>; putnil; pop; putself
    opcodes = rewritten.map(&:opcode)
    assert_equal [:putself, :setlocal_WC_0, :putnil, :pop, :putself], opcodes
    assert_equal 4, rewritten[1].operands[0], "arg stash must target stash_base_lindex"
  end

  def test_substitute_invokeblocks_remaps_block_param_getlocal
    src = <<~RUBY
      def tap; yield self; self; end
      5.tap { |y| y }
    RUBY
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    callee = find_iseq(ir, "tap")
    block  = find_block(ir)
    body   = callee.instructions[0..-2]

    rewritten = pass.send(
      :substitute_invokeblocks,
      body, block, stash_base_lindex: 4,
    )

    # The block body is `getlocal_WC_0 <y_lindex=3>; leave`. After substitution
    # the leave is dropped and the getlocal is remapped to lindex 4 (the stash).
    opcodes = rewritten.map(&:opcode)
    assert_equal [:putself, :setlocal_WC_0, :getlocal_WC_0, :pop, :putself], opcodes
    assert_equal 4, rewritten[1].operands[0]
    assert_equal 4, rewritten[2].operands[0]
  end

  def test_5_tap_nil_inlines_and_substitutes_block
    src = <<~RUBY
      def tap; yield self; self; end
      5.tap { nil }
    RUBY
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    top = ir.misc[:iseq_list].root  # top-level iseq containing the 5.tap { nil } call
    tap_fn = find_iseq(ir, "tap")
    refute_nil tap_fn

    log = Optimize::Log.new
    Optimize::Passes::InliningPass.new.apply(
      top, type_env: nil, log: log,
      object_table: ot, callee_map: { tap: tap_fn },
      iseq_list: ir.misc[:iseq_list],
    )

    # The caller's :send is gone.
    refute top.instructions.any? { |i| i.opcode == :send },
      "send should have been replaced: #{top.instructions.map(&:opcode).inspect}"

    # Round-trip executes correctly.
    loaded = RubyVM::InstructionSequence.load_from_binary(Optimize::Codec.encode(ir))
    assert_equal 5, loaded.eval
  end

  def test_putself_inside_block_is_not_rewritten_to_receiver
    # The callee's `putself` means "tap's receiver" → must rewrite to the
    # self-stash. The block's `putself` means "caller's self" → must stay
    # as :putself. Easiest way to assert this is via execution: at top-level,
    # caller's self is `main`; tap's receiver is 5. If the block's putself
    # were wrongly rewritten, the block would return 5 instead of main, and
    # then the surrounding tap returns 5 anyway — semantics happen to coincide.
    # Force the distinction by having the block's result observed via a side
    # effect: store self in an array.
    src = <<~RUBY
      def tap; yield self; self; end
      $observed = nil
      5.tap { $observed = self }
      $observed
    RUBY
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    top = ir.misc[:iseq_list].root
    tap_fn = find_iseq(ir, "tap")
    refute_nil tap_fn

    log = Optimize::Log.new
    Optimize::Passes::InliningPass.new.apply(
      top, type_env: nil, log: log,
      object_table: ot, callee_map: { tap: tap_fn },
      iseq_list: ir.misc[:iseq_list],
    )

    loaded = RubyVM::InstructionSequence.load_from_binary(Optimize::Codec.encode(ir))
    result = loaded.eval
    # Caller's self at top-level is the "main" object, NOT the literal 5.
    refute_equal 5, result, "block's putself was wrongly rewritten to tap's receiver"
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

  def find_iseq(fn, name)
    return fn if fn.name == name
    (fn.children || []).each do |c|
      found = find_iseq(c, name)
      return found if found
    end
    nil
  end
end
