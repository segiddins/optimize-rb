# frozen_string_literal: true
require "test_helper"
require "optimize/codec"
require "optimize/log"
require "optimize/passes/const_fold_tier2_pass"
require "optimize/pipeline"

class ConstFoldTier2PassTest < Minitest::Test
  def test_folds_bare_integer_constant_reference
    src = 'FOO = 42; def f; FOO; end'
    ir = decode(src)
    ot = ir.misc[:object_table]
    run_pass(ir, ot)

    f = find_iseq(ir, "f")
    opcodes = f.instructions.map(&:opcode)
    refute_includes opcodes, :opt_getconstant_path, "FOO should be folded away"
    # Must leave a literal 42 — either putobject with value 42 or an INT2FIX
    # shortcut (42 has no shortcut; expect putobject).
    putobj = f.instructions.find { |i| i.opcode == :putobject }
    refute_nil putobj
    assert_equal 42, ot.objects[putobj.operands[0]]
  end

  def test_folds_bare_string_constant_reference
    src = 'BAR = "hello"; def g; BAR; end'
    ir = decode(src)
    ot = ir.misc[:object_table]
    run_pass(ir, ot)

    g = find_iseq(ir, "g")
    refute_includes g.instructions.map(&:opcode), :opt_getconstant_path
    putobj = g.instructions.find { |i| i.opcode == :putobject }
    refute_nil putobj
    assert_equal "hello", ot.objects[putobj.operands[0]]
  end

  def test_folds_boolean_and_nil_constants
    src = 'T = true; F = false; N = nil; def f; T; end; def g; F; end; def h; N; end'
    ir = decode(src)
    ot = ir.misc[:object_table]
    run_pass(ir, ot)

    %w[f g h].each do |name|
      fn = find_iseq(ir, name)
      refute_includes fn.instructions.map(&:opcode), :opt_getconstant_path,
        "#{name} should be folded"
    end
  end

  def test_reassigned_constant_not_folded
    src = 'FOO = 1; FOO = 2; def f; FOO; end'
    ir = decode(src)
    ot = ir.misc[:object_table]
    log = Optimize::Log.new
    run_pass(ir, ot, log: log)

    f = find_iseq(ir, "f")
    assert_includes f.instructions.map(&:opcode), :opt_getconstant_path,
      "reassigned FOO must not fold"
    assert(log.for_pass(:const_fold_tier2).any? { |e| e.reason == :reassigned },
      "should log :reassigned")
  end

  def test_non_literal_rhs_not_folded
    # Dynamic RHS: cannot know the value at optimize time.
    src = 'def self.make; 99; end; FOO = make; def f; FOO; end'
    ir = decode(src)
    ot = ir.misc[:object_table]
    log = Optimize::Log.new
    run_pass(ir, ot, log: log)

    f = find_iseq(ir, "f")
    assert_includes f.instructions.map(&:opcode), :opt_getconstant_path,
      "non-literal RHS must not fold"
  end

  def test_nested_module_constant_not_folded
    src = 'module M; NESTED = 99; end; def h; M::NESTED; end'
    ir = decode(src)
    ot = ir.misc[:object_table]
    run_pass(ir, ot)

    h = find_iseq(ir, "h")
    # Multi-element path must stay untouched.
    assert_includes h.instructions.map(&:opcode), :opt_getconstant_path
  end

  def test_cascades_through_const_fold_pass
    # Tier 2 folds FOO → 42, then Tier 1 folds 42 + 1 → 43 in one pipeline run.
    src = 'FOO = 42; def f; FOO + 1; end; f'
    ir = decode(src)

    Optimize::Pipeline.default.run(ir, type_env: nil)

    f = find_iseq(ir, "f")
    opcodes = f.instructions.map(&:opcode)
    refute_includes opcodes, :opt_getconstant_path
    refute_includes opcodes, :opt_plus
    # Result 43 lives as putobject <idx=43>.
    putobj = f.instructions.find { |i| i.opcode == :putobject }
    refute_nil putobj
    assert_equal 43, ir.misc[:object_table].objects[putobj.operands[0]]
  end

  def test_roundtrips_through_codec_encode_after_fold
    # Regression: Tier 2 replaces `opt_getconstant_path` (1 operand)
    # with `putobject` (1 operand), leaving the bytecode byte-size
    # unchanged. The codec's body-record identity check then fires and
    # compares `insns_info_size`. If splice_instructions! leaves stale
    # `line_entries.inst` references, LineInfo.encode filters those
    # entries out and the emitted count is smaller than the original
    # header's stored value — raising a body-record field mismatch.
    src = 'FOO = 7; FOO + 1'
    ir = decode(src)
    ot = ir.misc[:object_table]
    run_pass(ir, ot)
    # Must not raise.
    Optimize::Codec.encode(ir)
  end

  def test_logs_folded_for_each_rewrite
    src = 'FOO = 7; def a; FOO; end; def b; FOO; end'
    ir = decode(src)
    ot = ir.misc[:object_table]
    log = Optimize::Log.new
    run_pass(ir, ot, log: log)

    folded = log.for_pass(:const_fold_tier2).select { |e| e.reason == :folded }
    assert_equal 2, folded.size
  end

  private

  def decode(src)
    Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
  end

  def run_pass(ir, ot, log: Optimize::Log.new)
    pass = Optimize::Passes::ConstFoldTier2Pass.new
    each_function(ir) do |fn|
      pass.apply(fn, type_env: nil, log: log, object_table: ot)
    end
    log
  end

  def each_function(fn, &blk)
    yield fn
    fn.children&.each { |c| each_function(c, &blk) }
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
