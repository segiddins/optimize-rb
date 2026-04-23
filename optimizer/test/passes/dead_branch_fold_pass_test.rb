# frozen_string_literal: true
require "test_helper"
require "optimize/codec"
require "optimize/log"
require "optimize/passes/const_fold_pass"
require "optimize/passes/dead_branch_fold_pass"

class DeadBranchFoldPassTest < Minitest::Test
  # ConstFoldPass folds `"a" == "a"` to `putobject true`, leaving
  # `putobject true; branchunless <else>` in front of the then-arm.
  # DeadBranchFoldPass should drop the pair: the condition is truthy,
  # so `branchunless` is not taken — fall through.
  def test_drops_pair_when_branchunless_condition_is_truthy
    src = <<~RUBY
      def f(x)
        if "a" == "a"
          x + 1
        else
          x - 1
        end
      end
      f(10)
    RUBY
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    log = Optimize::Log.new

    Optimize::Passes::ConstFoldPass.new.apply(f, type_env: nil, log: log, object_table: ot)
    Optimize::Passes::DeadBranchFoldPass.new.apply(f, type_env: nil, log: log, object_table: ot)

    refute(f.instructions.any? { |i| i.opcode == :branchunless },
           "branchunless should have been folded away")
    assert(log.entries.any? { |e| e.reason == :branch_folded },
           "expected a :branch_folded log entry")

    loaded = RubyVM::InstructionSequence.load_from_binary(Optimize::Codec.encode(ir))
    assert_equal 11, loaded.eval
  end

  # False condition + branchunless: branch IS taken.
  # Pair collapses to `jump <else-arm>` so execution reaches `x - 1`.
  def test_collapses_to_jump_when_branchunless_condition_is_falsy
    src = <<~RUBY
      def f(x)
        if "a" == "b"
          x + 1
        else
          x - 1
        end
      end
      f(10)
    RUBY
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    log = Optimize::Log.new

    Optimize::Passes::ConstFoldPass.new.apply(f, type_env: nil, log: log, object_table: ot)
    Optimize::Passes::DeadBranchFoldPass.new.apply(f, type_env: nil, log: log, object_table: ot)

    refute(f.instructions.any? { |i| i.opcode == :branchunless })
    assert(f.instructions.any? { |i| i.opcode == :jump })
    assert(log.entries.any? { |e| e.reason == :branch_folded })

    loaded = RubyVM::InstructionSequence.load_from_binary(Optimize::Codec.encode(ir))
    assert_equal 9, loaded.eval
  end

  # Integer literals are truthy in Ruby (only nil/false are falsy).
  # ConstFoldPass turns `2 + 3` into `putobject 5`; then
  # `putobject 5; branchunless` is not-taken.
  def test_integer_literal_condition_is_truthy
    src = <<~RUBY
      def f(x)
        if 2 + 3
          x + 1
        else
          x - 1
        end
      end
      f(10)
    RUBY
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    log = Optimize::Log.new

    Optimize::Passes::ConstFoldPass.new.apply(f, type_env: nil, log: log, object_table: ot)
    Optimize::Passes::DeadBranchFoldPass.new.apply(f, type_env: nil, log: log, object_table: ot)

    refute(f.instructions.any? { |i| i.opcode == :branchunless })
    loaded = RubyVM::InstructionSequence.load_from_binary(Optimize::Codec.encode(ir))
    assert_equal 11, loaded.eval
  end

  # Non-literal condition: nothing to fold.
  def test_unchanged_when_condition_is_not_a_literal
    src = "def f(x); if x.zero?; :a; else :b; end; end; f(1)"
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    before = f.instructions.map(&:opcode)
    log = Optimize::Log.new

    Optimize::Passes::DeadBranchFoldPass.new.apply(f, type_env: nil, log: log, object_table: ot)

    assert_equal before, f.instructions.map(&:opcode)
    assert(log.entries.none? { |e| e.reason == :branch_folded })

    loaded = RubyVM::InstructionSequence.load_from_binary(Optimize::Codec.encode(ir))
    assert_equal :b, loaded.eval
  end

  # `true && x` compiles to `<cond>; dup; branchunless L; pop; <rhs>; L:`.
  # After ConstFoldPass collapses "a"=="a" to `putobject true`, the short-
  # circuit is NOT taken — branchunless falls through. DeadBranchFoldPass
  # should drop the 4-instruction `<lit>; dup; branchunless; pop` prefix
  # and leave the rhs block untouched.
  def test_drops_short_circuit_prefix_for_true_and_rhs
    src = <<~RUBY
      def f(x)
        ("a" == "a") && x
      end
      f(10)
    RUBY
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    log = Optimize::Log.new

    Optimize::Passes::ConstFoldPass.new.apply(f, type_env: nil, log: log, object_table: ot)
    Optimize::Passes::DeadBranchFoldPass.new.apply(f, type_env: nil, log: log, object_table: ot)

    refute(f.instructions.any? { |i| i.opcode == :branchunless })
    refute(f.instructions.any? { |i| i.opcode == :dup })
    assert(log.entries.any? { |e| e.reason == :short_circuit_folded })

    loaded = RubyVM::InstructionSequence.load_from_binary(Optimize::Codec.encode(ir))
    assert_equal 10, loaded.eval
  end

  # Mirror case: `false || x`. After ConstFoldPass `"a"=="b"` → false,
  # the shape is `putobject false; dup; branchif L; pop; <rhs>; L:`.
  # branchif is NOT taken (false is falsy) — drop the 4-prefix.
  def test_drops_short_circuit_prefix_for_false_or_rhs
    src = <<~RUBY
      def f(x)
        ("a" == "b") || x
      end
      f(10)
    RUBY
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    log = Optimize::Log.new

    Optimize::Passes::ConstFoldPass.new.apply(f, type_env: nil, log: log, object_table: ot)
    Optimize::Passes::DeadBranchFoldPass.new.apply(f, type_env: nil, log: log, object_table: ot)

    refute(f.instructions.any? { |i| i.opcode == :branchif })
    refute(f.instructions.any? { |i| i.opcode == :dup })

    loaded = RubyVM::InstructionSequence.load_from_binary(Optimize::Codec.encode(ir))
    assert_equal 10, loaded.eval
  end

  # Short-circuit IS taken: `false && x`. Removing the rhs block is CFG
  # work and out of scope — this pass should leave the shape alone.
  def test_unchanged_when_short_circuit_is_taken
    src = <<~RUBY
      def f(x)
        ("a" == "b") && x
      end
      f(10)
    RUBY
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    log = Optimize::Log.new

    Optimize::Passes::ConstFoldPass.new.apply(f, type_env: nil, log: log, object_table: ot)
    before = f.instructions.map(&:opcode)
    Optimize::Passes::DeadBranchFoldPass.new.apply(f, type_env: nil, log: log, object_table: ot)

    assert_equal before, f.instructions.map(&:opcode),
                 "short-circuit-taken shape must not be folded by the peephole"

    loaded = RubyVM::InstructionSequence.load_from_binary(Optimize::Codec.encode(ir))
    assert_equal false, loaded.eval
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
