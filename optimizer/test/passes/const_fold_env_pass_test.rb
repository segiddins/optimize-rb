# frozen_string_literal: true
require "test_helper"
require "ruby_opt/codec"
require "ruby_opt/log"
require "ruby_opt/passes/const_fold_env_pass"

class ConstFoldEnvPassTest < Minitest::Test
  def test_no_snapshot_is_noop
    ir = RubyOpt::Codec.decode(
      RubyVM::InstructionSequence.compile('def f; ENV["FOO"]; end').to_binary
    )
    f = find_iseq(ir, "f")
    before = f.instructions.map(&:opcode)
    RubyOpt::Passes::ConstFoldEnvPass.new.apply(
      f, type_env: nil, log: RubyOpt::Log.new,
      object_table: ir.misc[:object_table], env_snapshot: nil,
    )
    assert_equal before, f.instructions.map(&:opcode)
  end

  def test_env_write_in_tree_taints_and_disables_folds
    # Use ENV.store (opt_send_without_block) instead of ENV[]= (opt_aset)
    # because opt_aset carries two CALLDATA operands and hits a codec limitation.
    src = <<~RUBY
      def r; ENV["A"]; end
      def w; ENV.store("B", "x"); end
    RUBY
    ir = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    snap = { "A" => "1", "B" => "2" }.freeze
    log = RubyOpt::Log.new
    r = find_iseq(ir, "r")
    w = find_iseq(ir, "w")
    before_r = r.instructions.map(&:opcode)
    before_w = w.instructions.map(&:opcode)

    pass = RubyOpt::Passes::ConstFoldEnvPass.new
    each_function(ir) do |fn|
      pass.apply(fn, type_env: nil, log: log, object_table: ot, env_snapshot: snap)
    end

    assert_equal before_r, r.instructions.map(&:opcode), "read should not fold when tree is tainted"
    assert_equal before_w, w.instructions.map(&:opcode)
    tainted = log.for_pass(:const_fold_env).select { |e| e.reason == :env_write_observed }
    assert_operator tainted.size, :>=, 1
  end

  def test_env_fetch_taints_tree
    src = 'def r; ENV["A"]; end; def g; ENV.fetch("B"); end'
    ir = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    snap = { "A" => "1", "B" => "2" }.freeze
    log = RubyOpt::Log.new
    r = find_iseq(ir, "r")
    before_r = r.instructions.map(&:opcode)

    pass = RubyOpt::Passes::ConstFoldEnvPass.new
    each_function(ir) do |fn|
      pass.apply(fn, type_env: nil, log: log, object_table: ot, env_snapshot: snap)
    end

    assert_equal before_r, r.instructions.map(&:opcode)
    assert_operator log.for_pass(:const_fold_env).count { |e| e.reason == :env_write_observed }, :>=, 1
  end

  def test_env_with_dynamic_key_does_not_taint
    # ENV[name] — opt_aref with a getlocal key. Safe use (i+2 is opt_aref).
    # Must NOT emit :env_write_observed.
    src = 'def f; x = "FOO"; ENV[x]; end'
    ir = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    log = RubyOpt::Log.new
    snap = { "FOO" => "1" }.freeze

    pass = RubyOpt::Passes::ConstFoldEnvPass.new
    each_function(ir) do |fn|
      pass.apply(fn, type_env: nil, log: log, object_table: ot, env_snapshot: snap)
    end

    refute(log.for_pass(:const_fold_env).any? { |e| e.reason == :env_write_observed },
           "opt_aref with non-literal key is a safe use, not a taint")
  end

  def test_folds_env_aref_when_value_already_interned
    # "hello" appears as the RHS literal so it's in the object table.
    src = 'def f; ENV["K"] == "hello"; end; f'
    ir = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    snap = { "K" => "hello" }.freeze
    log = RubyOpt::Log.new

    pass = RubyOpt::Passes::ConstFoldEnvPass.new
    each_function(ir) do |fn|
      pass.apply(fn, type_env: nil, log: log, object_table: ot, env_snapshot: snap)
    end

    opcodes = f.instructions.map(&:opcode)
    refute_includes opcodes, :opt_getconstant_path, "ENV producer should be gone"
    refute_includes opcodes, :opt_aref, "opt_aref should be gone"
  end

  def test_folds_missing_key_to_putnil
    src = 'def f; ENV["MISSING"]; end; f'
    ir = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    snap = {}.freeze
    log = RubyOpt::Log.new

    pass = RubyOpt::Passes::ConstFoldEnvPass.new
    each_function(ir) do |fn|
      pass.apply(fn, type_env: nil, log: log, object_table: ot, env_snapshot: snap)
    end

    opcodes = f.instructions.map(&:opcode)
    refute_includes opcodes, :opt_getconstant_path
    refute_includes opcodes, :opt_aref
    assert_includes opcodes, :putnil
    loaded = RubyVM::InstructionSequence.load_from_binary(RubyOpt::Codec.encode(ir))
    assert_nil loaded.eval
  end

  def test_skips_fold_when_snapshot_value_not_in_object_table
    # "xyzzy" is in the snapshot but NOT anywhere in the compiled program.
    # intern() can't add strings → skip this fold site, log.
    src = 'def f; ENV["K"]; end; f'
    ir = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    snap = { "K" => "xyzzy" }.freeze
    log = RubyOpt::Log.new
    before = f.instructions.map(&:opcode)

    pass = RubyOpt::Passes::ConstFoldEnvPass.new
    each_function(ir) do |fn|
      pass.apply(fn, type_env: nil, log: log, object_table: ot, env_snapshot: snap)
    end

    assert_equal before, f.instructions.map(&:opcode)
    not_interned = log.for_pass(:const_fold_env).count { |e| e.reason == :env_value_not_interned }
    assert_operator not_interned, :>=, 1
  end

  def test_logs_folded_for_each_successful_fold
    src = 'def f; ENV["K"] == "hello"; end; f'
    ir = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    snap = { "K" => "hello" }.freeze
    log = RubyOpt::Log.new

    pass = RubyOpt::Passes::ConstFoldEnvPass.new
    each_function(ir) do |fn|
      pass.apply(fn, type_env: nil, log: log, object_table: ot, env_snapshot: snap)
    end

    folded = log.for_pass(:const_fold_env).select { |e| e.reason == :folded }
    assert_operator folded.size, :>=, 1
  end

  private

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
