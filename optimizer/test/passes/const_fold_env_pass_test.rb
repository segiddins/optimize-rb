# frozen_string_literal: true
require "test_helper"
require "optimize/codec"
require "optimize/log"
require "optimize/passes/const_fold_env_pass"

class ConstFoldEnvPassTest < Minitest::Test
  def test_no_snapshot_is_noop
    ir = Optimize::Codec.decode(
      RubyVM::InstructionSequence.compile('def f; ENV["FOO"]; end').to_binary
    )
    f = find_iseq(ir, "f")
    before = f.instructions.map(&:opcode)
    Optimize::Passes::ConstFoldEnvPass.new.apply(
      f, type_env: nil, log: Optimize::Log.new,
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
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    snap = { "A" => "1", "B" => "2" }.freeze
    log = Optimize::Log.new
    r = find_iseq(ir, "r")
    w = find_iseq(ir, "w")
    before_r = r.instructions.map(&:opcode)
    before_w = w.instructions.map(&:opcode)

    pass = Optimize::Passes::ConstFoldEnvPass.new
    each_function(ir) do |fn|
      pass.apply(fn, type_env: nil, log: log, object_table: ot, env_snapshot: snap)
    end

    assert_equal before_r, r.instructions.map(&:opcode), "read should not fold when tree is tainted"
    assert_equal before_w, w.instructions.map(&:opcode)
    tainted = log.for_pass(:const_fold_env).select { |e| e.reason == :env_write_observed }
    assert_operator tainted.size, :>=, 1
  end

  def test_env_fetch_does_not_taint_tree
    src = 'def r; ENV["A"]; end; def g; ENV.fetch("B"); end'
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    snap = { "A" => "1", "B" => "2" }.freeze
    log = Optimize::Log.new
    r = find_iseq(ir, "r")

    pass = Optimize::Passes::ConstFoldEnvPass.new
    each_function(ir) do |fn|
      pass.apply(fn, type_env: nil, log: log, object_table: ot, env_snapshot: snap)
    end

    opcodes = r.instructions.map(&:opcode)
    refute_includes opcodes, :opt_aref, "r should fold — ENV.fetch sibling must not taint"
    refute(log.for_pass(:const_fold_env).any? { |e| e.reason == :env_write_observed },
           "read-only ENV.fetch should not taint the tree")
  end

  def test_env_to_h_does_not_taint_tree
    src = 'def r; ENV["A"]; end; def g; ENV.to_h; end'
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    snap = { "A" => "1" }.freeze
    log = Optimize::Log.new
    r = find_iseq(ir, "r")

    pass = Optimize::Passes::ConstFoldEnvPass.new
    each_function(ir) do |fn|
      pass.apply(fn, type_env: nil, log: log, object_table: ot, env_snapshot: snap)
    end

    refute_includes r.instructions.map(&:opcode), :opt_aref
    refute(log.for_pass(:const_fold_env).any? { |e| e.reason == :env_write_observed })
  end

  def test_env_key_question_does_not_taint_tree
    src = 'def r; ENV["A"]; end; def g; ENV.key?("B"); end'
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    snap = { "A" => "1" }.freeze
    log = Optimize::Log.new
    r = find_iseq(ir, "r")

    pass = Optimize::Passes::ConstFoldEnvPass.new
    each_function(ir) do |fn|
      pass.apply(fn, type_env: nil, log: log, object_table: ot, env_snapshot: snap)
    end

    refute_includes r.instructions.map(&:opcode), :opt_aref
    refute(log.for_pass(:const_fold_env).any? { |e| e.reason == :env_write_observed })
  end

  def test_env_values_at_two_args_does_not_taint_tree
    src = 'def r; ENV["A"]; end; def g; ENV.values_at("A", "B"); end'
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    snap = { "A" => "1", "B" => "2" }.freeze
    log = Optimize::Log.new
    r = find_iseq(ir, "r")

    pass = Optimize::Passes::ConstFoldEnvPass.new
    each_function(ir) do |fn|
      pass.apply(fn, type_env: nil, log: log, object_table: ot, env_snapshot: snap)
    end

    refute_includes r.instructions.map(&:opcode), :opt_aref,
      "r should fold — ENV.values_at (argc=2) sibling must not taint in v2"
    refute(log.for_pass(:const_fold_env).any? { |e| e.reason == :env_write_observed },
           "argc=2 safe sends should not taint the tree in v2")
  end

  def test_env_values_at_three_args_does_not_taint_tree
    src = 'def r; ENV["A"]; end; def g; ENV.values_at("A", "B", "C"); end'
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    snap = { "A" => "1", "B" => "2", "C" => "3" }.freeze
    log = Optimize::Log.new
    r = find_iseq(ir, "r")

    pass = Optimize::Passes::ConstFoldEnvPass.new
    each_function(ir) do |fn|
      pass.apply(fn, type_env: nil, log: log, object_table: ot, env_snapshot: snap)
    end

    refute_includes r.instructions.map(&:opcode), :opt_aref,
      "r should fold — ENV.values_at (argc=3) sibling must not taint in v2"
    refute(log.for_pass(:const_fold_env).any? { |e| e.reason == :env_write_observed },
           "argc=3 safe sends should not taint the tree in v2")
  end

  def test_env_store_two_args_still_taints_tree
    # ENV.store is not in SAFE_ENV_READ_METHODS — v2's argc-generic scan
    # still taints on it (mid check is what gates safety).
    src = 'def r; ENV["A"]; end; def w; ENV.store("B", "x"); end'
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    snap = { "A" => "1" }.freeze
    log = Optimize::Log.new
    r = find_iseq(ir, "r")
    before_r = r.instructions.map(&:opcode)

    pass = Optimize::Passes::ConstFoldEnvPass.new
    each_function(ir) do |fn|
      pass.apply(fn, type_env: nil, log: log, object_table: ot, env_snapshot: snap)
    end

    assert_equal before_r, r.instructions.map(&:opcode),
      "r should NOT fold — ENV.store sibling still taints in v2"
    assert_operator log.for_pass(:const_fold_env).count { |e| e.reason == :env_write_observed }, :>=, 1
  end

  def test_env_with_dynamic_key_does_not_taint
    # ENV[name] — opt_aref with a getlocal key. Safe use (i+2 is opt_aref).
    # Must NOT emit :env_write_observed.
    src = 'def f; x = "FOO"; ENV[x]; end'
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    log = Optimize::Log.new
    snap = { "FOO" => "1" }.freeze

    pass = Optimize::Passes::ConstFoldEnvPass.new
    each_function(ir) do |fn|
      pass.apply(fn, type_env: nil, log: log, object_table: ot, env_snapshot: snap)
    end

    refute(log.for_pass(:const_fold_env).any? { |e| e.reason == :env_write_observed },
           "opt_aref with non-literal key is a safe use, not a taint")
  end

  def test_folds_env_aref_when_value_already_interned
    # "hello" appears as the RHS literal so it's in the object table.
    src = 'def f; ENV["K"] == "hello"; end; f'
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    snap = { "K" => "hello" }.freeze
    log = Optimize::Log.new

    pass = Optimize::Passes::ConstFoldEnvPass.new
    each_function(ir) do |fn|
      pass.apply(fn, type_env: nil, log: log, object_table: ot, env_snapshot: snap)
    end

    opcodes = f.instructions.map(&:opcode)
    refute_includes opcodes, :opt_getconstant_path, "ENV producer should be gone"
    refute_includes opcodes, :opt_aref, "opt_aref should be gone"
  end

  def test_folds_missing_key_to_putnil
    src = 'def f; ENV["MISSING"]; end; f'
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    snap = {}.freeze
    log = Optimize::Log.new

    pass = Optimize::Passes::ConstFoldEnvPass.new
    each_function(ir) do |fn|
      pass.apply(fn, type_env: nil, log: log, object_table: ot, env_snapshot: snap)
    end

    opcodes = f.instructions.map(&:opcode)
    refute_includes opcodes, :opt_getconstant_path
    refute_includes opcodes, :opt_aref
    assert_includes opcodes, :putnil
    loaded = RubyVM::InstructionSequence.load_from_binary(Optimize::Codec.encode(ir))
    assert_nil loaded.eval
  end

  def test_folds_env_to_interned_string_value
    # "xyzzy" is in the snapshot but NOT anywhere in the compiled program.
    # After string-intern support, the pass MUST fold by interning the
    # snapshot value into the object table.
    src = 'def f; ENV["K"]; end; f'
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    snap = { "K" => "xyzzy" }.freeze
    log = Optimize::Log.new

    pass = Optimize::Passes::ConstFoldEnvPass.new
    each_function(ir) do |fn|
      pass.apply(fn, type_env: nil, log: log, object_table: ot, env_snapshot: snap)
    end

    refute_includes f.instructions.map(&:opcode), :opt_aref,
      "opt_aref should be folded away"
    folded = log.for_pass(:const_fold_env).count { |e| e.reason == :folded }
    assert_operator folded, :>=, 1
    not_interned = log.for_pass(:const_fold_env).count { |e| e.reason == :env_value_not_interned }
    assert_equal 0, not_interned, ":env_value_not_interned should no longer fire for strings"

    # End-to-end: the re-encoded binary loads and returns the snapshot value.
    loaded = RubyVM::InstructionSequence.load_from_binary(Optimize::Codec.encode(ir))
    assert_equal "xyzzy", loaded.eval
  end

  def test_logs_folded_for_each_successful_fold
    src = 'def f; ENV["K"] == "hello"; end; f'
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    snap = { "K" => "hello" }.freeze
    log = Optimize::Log.new

    pass = Optimize::Passes::ConstFoldEnvPass.new
    each_function(ir) do |fn|
      pass.apply(fn, type_env: nil, log: log, object_table: ot, env_snapshot: snap)
    end

    folded = log.for_pass(:const_fold_env).select { |e| e.reason == :folded }
    assert_operator folded.size, :>=, 1
  end

  def test_folds_env_fetch_with_present_literal_key
    src = 'def r; ENV.fetch("A"); end; r'
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    r = find_iseq(ir, "r")
    snap = { "A" => "1" }.freeze
    log = Optimize::Log.new

    pass = Optimize::Passes::ConstFoldEnvPass.new
    each_function(ir) do |fn|
      pass.apply(fn, type_env: nil, log: log, object_table: ot, env_snapshot: snap)
    end

    opcodes = r.instructions.map(&:opcode)
    refute_includes opcodes, :opt_send_without_block, "fetch send should be folded away"
    refute_includes opcodes, :opt_getconstant_path, "ENV producer should be gone"
    assert_includes opcodes, :putobject
    folded = log.for_pass(:const_fold_env).count { |e| e.reason == :folded }
    assert_operator folded, :>=, 1
  end

  def test_env_fetch_absent_key_is_not_folded_and_logs
    src = 'def r; ENV.fetch("MISSING"); end'
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    r = find_iseq(ir, "r")
    before = r.instructions.map(&:opcode)
    snap = {}.freeze
    log = Optimize::Log.new

    pass = Optimize::Passes::ConstFoldEnvPass.new
    each_function(ir) do |fn|
      pass.apply(fn, type_env: nil, log: log, object_table: ot, env_snapshot: snap)
    end

    assert_equal before, r.instructions.map(&:opcode),
      "absent key must preserve the bytecode so KeyError is raised at runtime"
    absent = log.for_pass(:const_fold_env).count { |e| e.reason == :fetch_key_absent }
    assert_operator absent, :>=, 1
  end

  def test_folds_env_fetch_and_opt_aref_in_same_function
    src = 'def r; [ENV["A"], ENV.fetch("B")]; end; r'
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    r = find_iseq(ir, "r")
    snap = { "A" => "1", "B" => "2" }.freeze
    log = Optimize::Log.new

    pass = Optimize::Passes::ConstFoldEnvPass.new
    each_function(ir) do |fn|
      pass.apply(fn, type_env: nil, log: log, object_table: ot, env_snapshot: snap)
    end

    opcodes = r.instructions.map(&:opcode)
    refute_includes opcodes, :opt_aref
    refute_includes opcodes, :opt_send_without_block
  end

  def test_env_fetch_fold_disabled_by_tree_taint
    src = <<~RUBY
      def w; ENV.store("Z", "x"); end
      def r; ENV.fetch("A"); end
    RUBY
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    r = find_iseq(ir, "r")
    before = r.instructions.map(&:opcode)
    snap = { "A" => "1" }.freeze
    log = Optimize::Log.new

    pass = Optimize::Passes::ConstFoldEnvPass.new
    each_function(ir) do |fn|
      pass.apply(fn, type_env: nil, log: log, object_table: ot, env_snapshot: snap)
    end

    assert_equal before, r.instructions.map(&:opcode),
      "tainted tree must preserve fetch bytecode"
    tainted = log.for_pass(:const_fold_env).count { |e| e.reason == :env_write_observed }
    assert_operator tainted, :>=, 1
  end

  def test_folds_env_fetch_with_literal_default_when_key_present
    src = 'def r; ENV.fetch("A", "fallback"); end'
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    r = find_iseq(ir, "r")
    snap = { "A" => "1" }.freeze
    log = Optimize::Log.new

    pass = Optimize::Passes::ConstFoldEnvPass.new
    each_function(ir) do |fn|
      pass.apply(fn, type_env: nil, log: log, object_table: ot, env_snapshot: snap)
    end

    opcodes = r.instructions.map(&:opcode)
    refute_includes opcodes, :opt_send_without_block, "fetch send should be folded away"
    refute_includes opcodes, :opt_getconstant_path, "ENV producer should be gone"
    assert_includes opcodes, :putobject
    folded = log.for_pass(:const_fold_env).count { |e| e.reason == :folded }
    assert_operator folded, :>=, 1
  end

  def test_folds_env_fetch_with_string_default_when_key_absent
    src = 'def r; ENV.fetch("MISSING", "fallback"); end'
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    r = find_iseq(ir, "r")
    snap = {}.freeze
    log = Optimize::Log.new

    pass = Optimize::Passes::ConstFoldEnvPass.new
    each_function(ir) do |fn|
      pass.apply(fn, type_env: nil, log: log, object_table: ot, env_snapshot: snap)
    end

    opcodes = r.instructions.map(&:opcode)
    refute_includes opcodes, :opt_send_without_block, "fetch send should be folded away"
    refute_includes opcodes, :opt_getconstant_path, "ENV producer should be gone"
    # The default producer survives — either :putstring or :putchilledstring
    # depending on Ruby's compile-time string handling.
    assert(opcodes.include?(:putstring) || opcodes.include?(:putchilledstring),
      "default string producer should be preserved as the fold result")
    folded = log.for_pass(:const_fold_env).count { |e| e.reason == :folded }
    assert_operator folded, :>=, 1
  end

  def test_folds_env_fetch_with_putnil_default_when_key_absent
    src = 'def r; ENV.fetch("MISSING", nil); end'
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    r = find_iseq(ir, "r")
    snap = {}.freeze
    log = Optimize::Log.new

    pass = Optimize::Passes::ConstFoldEnvPass.new
    each_function(ir) do |fn|
      pass.apply(fn, type_env: nil, log: log, object_table: ot, env_snapshot: snap)
    end

    opcodes = r.instructions.map(&:opcode)
    refute_includes opcodes, :opt_send_without_block
    refute_includes opcodes, :opt_getconstant_path
    assert_includes opcodes, :putnil
    folded = log.for_pass(:const_fold_env).count { |e| e.reason == :folded }
    assert_operator folded, :>=, 1
  end

  def test_folds_env_fetch_with_integer_default_when_key_absent
    src = 'def r; ENV.fetch("MISSING", 42); end'
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    r = find_iseq(ir, "r")
    snap = {}.freeze
    log = Optimize::Log.new

    pass = Optimize::Passes::ConstFoldEnvPass.new
    each_function(ir) do |fn|
      pass.apply(fn, type_env: nil, log: log, object_table: ot, env_snapshot: snap)
    end

    opcodes = r.instructions.map(&:opcode)
    refute_includes opcodes, :opt_send_without_block
    refute_includes opcodes, :opt_getconstant_path
    assert_includes opcodes, :putobject
    folded = log.for_pass(:const_fold_env).count { |e| e.reason == :folded }
    assert_operator folded, :>=, 1
  end

  def test_does_not_fold_env_fetch_with_impure_default
    # `other_call` compiles to a send, which is not on PURE_DEFAULT_OPCODES.
    src = <<~RUBY
      def other_call; "x"; end
      def r; ENV.fetch("A", other_call); end
    RUBY
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    r = find_iseq(ir, "r")
    before = r.instructions.map(&:opcode)
    snap = { "A" => "1" }.freeze
    log = Optimize::Log.new

    pass = Optimize::Passes::ConstFoldEnvPass.new
    each_function(ir) do |fn|
      pass.apply(fn, type_env: nil, log: log, object_table: ot, env_snapshot: snap)
    end

    assert_equal before, r.instructions.map(&:opcode),
      "impure default must preserve the full ENV.fetch bytecode"
    # The fetch send is still present, so an argc-match-but-impure-default
    # must not count as a fold.
    refute(log.for_pass(:const_fold_env).any? { |e| e.reason == :folded && e.file == r.path },
      "no :folded log entry should be emitted for r when default is impure")
  end

  def test_env_fetch_with_block_does_not_crash
    src = 'def r; ENV.fetch("A") { "x" }; end'
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    r = find_iseq(ir, "r")
    before = r.instructions.map(&:opcode)
    snap = { "A" => "1" }.freeze
    log = Optimize::Log.new

    pass = Optimize::Passes::ConstFoldEnvPass.new
    each_function(ir) do |fn|
      pass.apply(fn, type_env: nil, log: log, object_table: ot, env_snapshot: snap)
    end

    assert_equal before, r.instructions.map(&:opcode),
      "block-passing fetch must not fold"
    folded = log.for_pass(:const_fold_env).count { |e| e.reason == :folded }
    assert_equal 0, folded
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
