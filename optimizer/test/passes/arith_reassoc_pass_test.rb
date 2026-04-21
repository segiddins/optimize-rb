# frozen_string_literal: true
require "test_helper"
require "ruby_opt/codec"
require "ruby_opt/log"
require "ruby_opt/passes/arith_reassoc_pass"
require "ruby_opt/passes/literal_value"

class ArithReassocPassTest < Minitest::Test
  def test_collapses_leading_non_literal_chain_to_single_literal_tail
    src = "def f(x); x + 1 + 2 + 3; end; f(10)"
    ir = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    RubyOpt::Passes::ArithReassocPass.new.apply(f, type_env: nil, log: RubyOpt::Log.new, object_table: ot)

    opt_plus_count = f.instructions.count { |i| i.opcode == :opt_plus }
    assert_equal 1, opt_plus_count, "expected a single opt_plus after reassoc"
    lit_six = f.instructions.find { |i| RubyOpt::Passes::LiteralValue.read(i, object_table: ot) == 6 }
    refute_nil lit_six, "expected a literal 6 in the rewritten instructions"

    loaded = RubyVM::InstructionSequence.load_from_binary(RubyOpt::Codec.encode(ir))
    assert_equal 16, loaded.eval
  end

  def test_reorders_around_mid_chain_non_literal
    src = "def f(x); 1 + x + 2; end; f(10)"
    ir = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    RubyOpt::Passes::ArithReassocPass.new.apply(f, type_env: nil, log: RubyOpt::Log.new, object_table: ot)

    opt_plus_count = f.instructions.count { |i| i.opcode == :opt_plus }
    assert_equal 1, opt_plus_count
    refute_nil f.instructions.find { |i| RubyOpt::Passes::LiteralValue.read(i, object_table: ot) == 3 }

    loaded = RubyVM::InstructionSequence.load_from_binary(RubyOpt::Codec.encode(ir))
    assert_equal 13, loaded.eval
  end

  def test_multiple_non_literals_preserved_in_original_order
    src = "def f(x, y); 1 + x + 2 + y + 3; end; f(10, 20)"
    ir = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    RubyOpt::Passes::ArithReassocPass.new.apply(f, type_env: nil, log: RubyOpt::Log.new, object_table: ot)

    opt_plus_count = f.instructions.count { |i| i.opcode == :opt_plus }
    assert_equal 2, opt_plus_count, "3 operands after reassoc => 2 opt_pluses"
    refute_nil f.instructions.find { |i| RubyOpt::Passes::LiteralValue.read(i, object_table: ot) == 6 }

    producers = f.instructions.select { |i| %i[getlocal getlocal_WC_0 getlocal_WC_1].include?(i.opcode) }
    assert_equal 2, producers.size
    loaded = RubyVM::InstructionSequence.load_from_binary(RubyOpt::Codec.encode(ir))
    assert_equal 36, loaded.eval
  end

  def test_single_literal_chain_is_left_alone
    src = "def f(x); x + 1; end; f(10)"
    ir = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    before = f.instructions.map(&:opcode)
    RubyOpt::Passes::ArithReassocPass.new.apply(f, type_env: nil, log: RubyOpt::Log.new, object_table: ot)
    assert_equal before, f.instructions.map(&:opcode)
  end

  def test_no_literals_chain_is_left_alone
    src = "def f(x, y, z); x + y + z; end; f(1, 2, 3)"
    ir = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    before = f.instructions.map(&:opcode)
    RubyOpt::Passes::ArithReassocPass.new.apply(f, type_env: nil, log: RubyOpt::Log.new, object_table: ot)
    assert_equal before, f.instructions.map(&:opcode)
  end

  def test_all_literal_chain_is_left_to_const_fold
    src = "def f; 1 + 2 + 3; end; f"
    ir = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    RubyOpt::Passes::ArithReassocPass.new.apply(f, type_env: nil, log: RubyOpt::Log.new, object_table: ot)
    assert_equal 0, f.instructions.count { |i| i.opcode == :opt_plus }
    refute_nil f.instructions.find { |i| RubyOpt::Passes::LiteralValue.read(i, object_table: ot) == 6 }
    loaded = RubyVM::InstructionSequence.load_from_binary(RubyOpt::Codec.encode(ir))
    assert_equal 6, loaded.eval
  end

  def test_opt_mult_basic_two_literal_fold_with_non_literal
    src = "def f(x); x * 2 * 3; end; f(4)"
    ir = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    RubyOpt::Passes::ArithReassocPass.new.apply(f, type_env: nil, log: RubyOpt::Log.new, object_table: ot)
    assert_equal 1, f.instructions.count { |i| i.opcode == :opt_mult }
    refute_nil f.instructions.find { |i| RubyOpt::Passes::LiteralValue.read(i, object_table: ot) == 6 }
    loaded = RubyVM::InstructionSequence.load_from_binary(RubyOpt::Codec.encode(ir))
    assert_equal 24, loaded.eval
  end

  def test_rewritten_instruction_order_non_literals_first_then_literal_then_opt_pluses
    src = "def f(x, y); 1 + x + 2 + y + 3; end; f(10, 20)"
    ir = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    RubyOpt::Passes::ArithReassocPass.new.apply(f, type_env: nil, log: RubyOpt::Log.new, object_table: ot)

    # Find the chain in the rewritten instructions. With the sign-aware
    # build_replacement, all-positive non-literals are interleaved with their
    # intermediate ops, then the literal, then the tail op. Expect:
    #   <getlocal-for-x>, <getlocal-for-y>, opt_plus, <literal 6>, opt_plus
    # Locate the two getlocal instructions.
    getlocal_idxs = f.instructions.each_with_index.select { |i, _|
      %i[getlocal getlocal_WC_0 getlocal_WC_1].include?(i.opcode)
    }.map { |_, idx| idx }
    assert_equal 2, getlocal_idxs.size
    first_get, second_get = getlocal_idxs
    assert_equal first_get + 1, second_get, "getlocals should be adjacent (x then y)"

    # After the second getlocal: an opt_plus (intermediate), then the combined literal 6.
    assert_equal :opt_plus, f.instructions[second_get + 1].opcode
    after_intermediate = f.instructions[second_get + 2]
    assert_equal 6, RubyOpt::Passes::LiteralValue.read(after_intermediate, object_table: ot)

    # Then the tail opt_plus.
    assert_equal :opt_plus, f.instructions[second_get + 3].opcode
  end

  def test_logs_reassociated_on_success
    src = "def f(x); x + 1 + 2 + 3; end; f(10)"
    ir = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    log = RubyOpt::Log.new
    RubyOpt::Passes::ArithReassocPass.new.apply(find_iseq(ir, "f"), type_env: nil, log: log, object_table: ot)
    entries = log.for_pass(:arith_reassoc).select { |e| e.reason == :reassociated }
    assert_operator entries.size, :>=, 1
  end

  def test_logs_mixed_literal_types_when_chain_has_non_integer_literal
    src = 'def f(x); x + "a" + 2; end; f("z")'
    ir = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    before = f.instructions.map(&:opcode)
    log = RubyOpt::Log.new
    RubyOpt::Passes::ArithReassocPass.new.apply(f, type_env: nil, log: log, object_table: ot)
    assert_equal before, f.instructions.map(&:opcode)
    entries = log.for_pass(:arith_reassoc).select { |e| e.reason == :mixed_literal_types }
    assert_operator entries.size, :>=, 1
  end

  def test_logs_chain_too_short_when_only_one_integer_literal
    src = "def f(x, y); x + 1 + y; end; f(10, 20)"
    ir = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    log = RubyOpt::Log.new
    RubyOpt::Passes::ArithReassocPass.new.apply(f, type_env: nil, log: log, object_table: ot)
    entries = log.for_pass(:arith_reassoc).select { |e| e.reason == :chain_too_short }
    assert_operator entries.size, :>=, 1
  end

  def test_independent_chains_both_get_rewritten
    src = <<~RUBY
      def f(cond, x, y)
        if cond
          x + 1 + 2 + 3
        else
          y + 4 + 5 + 6
        end
      end
      f(true, 10, 20)
    RUBY
    ir = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    log = RubyOpt::Log.new
    RubyOpt::Passes::ArithReassocPass.new.apply(f, type_env: nil, log: log, object_table: ot)
    reassoc_entries = log.for_pass(:arith_reassoc).select { |e| e.reason == :reassociated }
    assert_operator reassoc_entries.size, :>=, 2,
      "expected both then/else chains to reassociate"
    assert(f.instructions.any? { |i| RubyOpt::Passes::LiteralValue.read(i, object_table: ot) == 6 })
    assert(f.instructions.any? { |i| RubyOpt::Passes::LiteralValue.read(i, object_table: ot) == 15 })
    loaded = RubyVM::InstructionSequence.load_from_binary(RubyOpt::Codec.encode(ir))
    assert_equal 16, loaded.eval  # f(true, 10, 20) == 10 + 6
  end

  def test_end_to_end_deep_chain_evaluates_correctly
    src = "def f(x); x + 1 + 2 + 3 + 4 + 5 + 6 + 7 + 8 + 9 + 10; end; f(100)"
    ir = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    RubyOpt::Passes::ArithReassocPass.new.apply(find_iseq(ir, "f"), type_env: nil, log: RubyOpt::Log.new, object_table: ot)
    loaded = RubyVM::InstructionSequence.load_from_binary(RubyOpt::Codec.encode(ir))
    assert_equal 155, loaded.eval  # 100 + (1+2+...+10) = 100 + 55
  end

  def test_reassoc_inside_then_branch_does_not_break_else_branch_targets
    src = "def f(c, x); if c; x + 1 + 2 + 3; else; 99; end; end; [f(true, 10), f(false, 0)]"
    ir = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    RubyOpt::Passes::ArithReassocPass.new.apply(find_iseq(ir, "f"), type_env: nil, log: RubyOpt::Log.new, object_table: ot)
    loaded = RubyVM::InstructionSequence.load_from_binary(RubyOpt::Codec.encode(ir))
    assert_equal [16, 99], loaded.eval
  end

  # ---- opt_mult ----

  def test_opt_mult_collapses_leading_non_literal_chain
    src = "def f(x); x * 2 * 3 * 4; end; f(10)"
    ir = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    RubyOpt::Passes::ArithReassocPass.new.apply(f, type_env: nil, log: RubyOpt::Log.new, object_table: ot)

    assert_equal 1, f.instructions.count { |i| i.opcode == :opt_mult }
    refute_nil f.instructions.find { |i| RubyOpt::Passes::LiteralValue.read(i, object_table: ot) == 24 }
    loaded = RubyVM::InstructionSequence.load_from_binary(RubyOpt::Codec.encode(ir))
    assert_equal 240, loaded.eval
  end

  def test_opt_mult_reorders_around_mid_chain_non_literal
    src = "def f(x); 2 * x * 3; end; f(5)"
    ir = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    RubyOpt::Passes::ArithReassocPass.new.apply(f, type_env: nil, log: RubyOpt::Log.new, object_table: ot)

    assert_equal 1, f.instructions.count { |i| i.opcode == :opt_mult }
    refute_nil f.instructions.find { |i| RubyOpt::Passes::LiteralValue.read(i, object_table: ot) == 6 }
    loaded = RubyVM::InstructionSequence.load_from_binary(RubyOpt::Codec.encode(ir))
    assert_equal 30, loaded.eval
  end

  def test_opt_mult_multiple_non_literals_preserved_in_order
    src = "def f(x, y); 2 * x * 3 * y * 4; end; f(10, 5)"
    ir = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    RubyOpt::Passes::ArithReassocPass.new.apply(f, type_env: nil, log: RubyOpt::Log.new, object_table: ot)

    assert_equal 2, f.instructions.count { |i| i.opcode == :opt_mult }
    refute_nil f.instructions.find { |i| RubyOpt::Passes::LiteralValue.read(i, object_table: ot) == 24 }
    loaded = RubyVM::InstructionSequence.load_from_binary(RubyOpt::Codec.encode(ir))
    assert_equal 1200, loaded.eval
  end

  def test_opt_mult_all_literal_chain_folds
    src = "def f; 2 * 3 * 4; end; f"
    ir = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    RubyOpt::Passes::ArithReassocPass.new.apply(f, type_env: nil, log: RubyOpt::Log.new, object_table: ot)

    assert_equal 0, f.instructions.count { |i| i.opcode == :opt_mult }
    refute_nil f.instructions.find { |i| RubyOpt::Passes::LiteralValue.read(i, object_table: ot) == 24 }
    loaded = RubyVM::InstructionSequence.load_from_binary(RubyOpt::Codec.encode(ir))
    assert_equal 24, loaded.eval
  end

  def test_opt_mult_single_literal_chain_is_left_alone
    src = "def f(x); x * 2; end; f(10)"
    ir = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    before = f.instructions.map(&:opcode)
    RubyOpt::Passes::ArithReassocPass.new.apply(f, type_env: nil, log: RubyOpt::Log.new, object_table: ot)
    assert_equal before, f.instructions.map(&:opcode)
  end

  def test_opt_mult_mixed_literal_types_leaves_chain_alone
    src = "def f(x); x * 1.5 * 2; end; f(4)"
    ir = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    before = f.instructions.map(&:opcode)
    log = RubyOpt::Log.new
    RubyOpt::Passes::ArithReassocPass.new.apply(f, type_env: nil, log: log, object_table: ot)
    assert_equal before, f.instructions.map(&:opcode)
    entries = log.for_pass(:arith_reassoc).select { |e| e.reason == :mixed_literal_types }
    assert_operator entries.size, :>=, 1
  end

  # ---- intern-range overflow guard ----

  def test_product_that_overflows_intern_range_is_skipped
    # Two literals only (no foldable sub-chain). Product (1 << 62) has
    # bit_length == 62, outside the intern-accepted range.
    src = "def f(x); x * #{1 << 31} * #{1 << 31}; end; f(1)"
    ir = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    before_opcodes = f.instructions.map(&:opcode)
    log = RubyOpt::Log.new
    RubyOpt::Passes::ArithReassocPass.new.apply(f, type_env: nil, log: log, object_table: ot)

    assert_equal before_opcodes, f.instructions.map(&:opcode),
      "overflow-guard should leave the chain untouched"
    entries = log.for_pass(:arith_reassoc).select { |e| e.reason == :would_exceed_intern_range }
    assert_operator entries.size, :>=, 1
    loaded = RubyVM::InstructionSequence.load_from_binary(RubyOpt::Codec.encode(ir))
    assert_equal 1 << 62, loaded.eval
  end

  # ---- cross-operator interaction (outer fixpoint) ----

  def test_mult_rewrite_exposes_plus_chain_across_outer_fixpoint
    src = "def f(x); x + 2 * 3 + 4; end; f(10)"
    ir = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    RubyOpt::Passes::ArithReassocPass.new.apply(f, type_env: nil, log: RubyOpt::Log.new, object_table: ot)

    assert_equal 0, f.instructions.count { |i| i.opcode == :opt_mult },
      "mult should have folded 2*3 to a literal"
    assert_equal 1, f.instructions.count { |i| i.opcode == :opt_plus },
      "plus should have collapsed x + 6 + 4 to one opt_plus after outer fixpoint re-ran it"
    refute_nil f.instructions.find { |i| RubyOpt::Passes::LiteralValue.read(i, object_table: ot) == 10 }
    loaded = RubyVM::InstructionSequence.load_from_binary(RubyOpt::Codec.encode(ir))
    assert_equal 20, loaded.eval
  end

  def test_opt_mult_deep_chain_end_to_end
    src = "def f(x); x * 2 * 3 * 4 * 5 * 6; end; f(1)"
    ir = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    RubyOpt::Passes::ArithReassocPass.new.apply(find_iseq(ir, "f"), type_env: nil, log: RubyOpt::Log.new, object_table: ot)
    loaded = RubyVM::InstructionSequence.load_from_binary(RubyOpt::Codec.encode(ir))
    assert_equal 720, loaded.eval
  end

  # ---- opt_minus / additive group ----

  def test_opt_plus_minus_collapses_leading_non_literal_chain
    src = "def f(x); x + 1 - 2 + 3; end; f(10)"
    ir = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    RubyOpt::Passes::ArithReassocPass.new.apply(f, type_env: nil, log: RubyOpt::Log.new, object_table: ot)

    assert_equal 1, f.instructions.count { |i| i.opcode == :opt_plus }
    assert_equal 0, f.instructions.count { |i| i.opcode == :opt_minus }
    refute_nil f.instructions.find { |i| RubyOpt::Passes::LiteralValue.read(i, object_table: ot) == 2 }
    loaded = RubyVM::InstructionSequence.load_from_binary(RubyOpt::Codec.encode(ir))
    assert_equal 12, loaded.eval
  end

  def test_opt_minus_only_chain_emits_negative_literal
    src = "def f(x); x - 1 - 2 - 3; end; f(10)"
    ir = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    RubyOpt::Passes::ArithReassocPass.new.apply(f, type_env: nil, log: RubyOpt::Log.new, object_table: ot)

    assert_equal 1, f.instructions.count { |i| i.opcode == :opt_plus }
    assert_equal 0, f.instructions.count { |i| i.opcode == :opt_minus }
    refute_nil f.instructions.find { |i| RubyOpt::Passes::LiteralValue.read(i, object_table: ot) == -6 }
    loaded = RubyVM::InstructionSequence.load_from_binary(RubyOpt::Codec.encode(ir))
    assert_equal 4, loaded.eval
  end

  def test_opt_plus_minus_folds_to_negative_literal
    src = "def f(x); x - 5 + 3; end; f(10)"
    ir = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    RubyOpt::Passes::ArithReassocPass.new.apply(f, type_env: nil, log: RubyOpt::Log.new, object_table: ot)

    assert_equal 1, f.instructions.count { |i| i.opcode == :opt_plus }
    assert_equal 0, f.instructions.count { |i| i.opcode == :opt_minus }
    refute_nil f.instructions.find { |i| RubyOpt::Passes::LiteralValue.read(i, object_table: ot) == -2 }
    loaded = RubyVM::InstructionSequence.load_from_binary(RubyOpt::Codec.encode(ir))
    assert_equal 8, loaded.eval
  end

  def test_opt_plus_minus_with_pos_and_neg_non_literals
    # x + 1 - y + 2: pos=[x], neg=[y], literal=3 → emit "x - y + 3"
    src = "def f(x, y); x + 1 - y + 2; end; f(10, 4)"
    ir = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    RubyOpt::Passes::ArithReassocPass.new.apply(f, type_env: nil, log: RubyOpt::Log.new, object_table: ot)

    assert_equal 1, f.instructions.count { |i| i.opcode == :opt_plus },
      "one opt_plus for the literal tail"
    assert_equal 1, f.instructions.count { |i| i.opcode == :opt_minus },
      "one opt_minus between x and y"
    refute_nil f.instructions.find { |i| RubyOpt::Passes::LiteralValue.read(i, object_table: ot) == 3 }
    loaded = RubyVM::InstructionSequence.load_from_binary(RubyOpt::Codec.encode(ir))
    assert_equal 9, loaded.eval
  end

  def test_opt_plus_minus_all_negative_non_literals_is_skipped
    # 1 - x + 2 - y + 3: pos=[], neg=[x, y] → skip :no_positive_nonliteral.
    src = "def f(x, y); 1 - x + 2 - y + 3; end; f(10, 4)"
    ir = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    before_opcodes = f.instructions.map(&:opcode)
    log = RubyOpt::Log.new
    RubyOpt::Passes::ArithReassocPass.new.apply(f, type_env: nil, log: log, object_table: ot)

    assert_equal before_opcodes, f.instructions.map(&:opcode),
      ":no_positive_nonliteral should leave the chain untouched"
    entries = log.for_pass(:arith_reassoc).select { |e| e.reason == :no_positive_nonliteral }
    assert_operator entries.size, :>=, 1

    loaded = RubyVM::InstructionSequence.load_from_binary(RubyOpt::Codec.encode(ir))
    assert_equal (1 - 10 + 2 - 4 + 3), loaded.eval # -8
  end

  def test_opt_plus_minus_single_leading_negative_is_skipped
    # 1 - x + 2: pos=[], neg=[x] → skip.
    src = "def f(x); 1 - x + 2; end; f(4)"
    ir = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    before_opcodes = f.instructions.map(&:opcode)
    log = RubyOpt::Log.new
    RubyOpt::Passes::ArithReassocPass.new.apply(f, type_env: nil, log: log, object_table: ot)

    assert_equal before_opcodes, f.instructions.map(&:opcode)
    entries = log.for_pass(:arith_reassoc).select { |e| e.reason == :no_positive_nonliteral }
    assert_operator entries.size, :>=, 1

    loaded = RubyVM::InstructionSequence.load_from_binary(RubyOpt::Codec.encode(ir))
    assert_equal (1 - 4 + 2), loaded.eval # -1
  end

  def test_opt_plus_minus_mixed_literal_types_is_skipped
    src = "def f(x); x + 1 - 1.5; end; f(4)"
    ir = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    before_opcodes = f.instructions.map(&:opcode)
    log = RubyOpt::Log.new
    RubyOpt::Passes::ArithReassocPass.new.apply(f, type_env: nil, log: log, object_table: ot)

    assert_equal before_opcodes, f.instructions.map(&:opcode)
    entries = log.for_pass(:arith_reassoc).select { |e| e.reason == :mixed_literal_types }
    assert_operator entries.size, :>=, 1
  end

  def test_opt_minus_single_literal_chain_is_left_alone
    src = "def f(x); x - 1; end; f(10)"
    ir = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    before_opcodes = f.instructions.map(&:opcode)
    RubyOpt::Passes::ArithReassocPass.new.apply(f, type_env: nil, log: RubyOpt::Log.new, object_table: ot)
    assert_equal before_opcodes, f.instructions.map(&:opcode)
  end

  def test_opt_plus_minus_no_literals_chain_is_left_alone
    src = "def f(x, y, z); x - y + z; end; f(10, 4, 2)"
    ir = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    before_opcodes = f.instructions.map(&:opcode)
    RubyOpt::Passes::ArithReassocPass.new.apply(f, type_env: nil, log: RubyOpt::Log.new, object_table: ot)
    assert_equal before_opcodes, f.instructions.map(&:opcode)
  end

  def test_opt_plus_minus_all_literal_chain_folds
    src = "def f; 3 - 1 - 1; end; f"
    ir = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    RubyOpt::Passes::ArithReassocPass.new.apply(f, type_env: nil, log: RubyOpt::Log.new, object_table: ot)

    assert_equal 0, f.instructions.count { |i| i.opcode == :opt_plus }
    assert_equal 0, f.instructions.count { |i| i.opcode == :opt_minus }
    refute_nil f.instructions.find { |i| RubyOpt::Passes::LiteralValue.read(i, object_table: ot) == 1 }
    loaded = RubyVM::InstructionSequence.load_from_binary(RubyOpt::Codec.encode(ir))
    assert_equal 1, loaded.eval
  end

  # ---- cross-group interaction (outer fixpoint with opt_minus in the additive group) ----

  def test_mult_exposes_additive_chain_with_minus
    # x + 2 * 3 - 4 → x + 6 - 4 after mult folds → x + 2 after additive re-runs.
    src = "def f(x); x + 2 * 3 - 4; end; f(10)"
    ir = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    RubyOpt::Passes::ArithReassocPass.new.apply(f, type_env: nil, log: RubyOpt::Log.new, object_table: ot)

    assert_equal 0, f.instructions.count { |i| i.opcode == :opt_mult },
      "mult should have folded 2*3 to a literal"
    assert_equal 1, f.instructions.count { |i| i.opcode == :opt_plus },
      "additive re-run should have collapsed to one opt_plus"
    assert_equal 0, f.instructions.count { |i| i.opcode == :opt_minus },
      "additive re-run should have folded the minus into the literal"
    refute_nil f.instructions.find { |i| RubyOpt::Passes::LiteralValue.read(i, object_table: ot) == 2 }
    loaded = RubyVM::InstructionSequence.load_from_binary(RubyOpt::Codec.encode(ir))
    assert_equal 12, loaded.eval
  end

  # ---- v2 loose-end: opt_mult no-literal chain ----

  def test_opt_mult_no_literals_chain_is_left_alone
    src = "def f(x, y, z); x * y * z; end; f(2, 3, 4)"
    ir = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    before_opcodes = f.instructions.map(&:opcode)
    RubyOpt::Passes::ArithReassocPass.new.apply(f, type_env: nil, log: RubyOpt::Log.new, object_table: ot)
    assert_equal before_opcodes, f.instructions.map(&:opcode)
  end

  # --- v4: multiplicative :ordered group ---

  def test_mult_div_same_op_div_chain_folds
    src = "def f(x); x / 2 / 3; end; f(60)"
    ir = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    RubyOpt::Passes::ArithReassocPass.new.apply(f, type_env: nil, log: RubyOpt::Log.new, object_table: ot)

    assert_equal 1, f.instructions.count { |i| i.opcode == :opt_div }
    assert_equal 0, f.instructions.count { |i| i.opcode == :opt_mult }
    refute_nil f.instructions.find { |i| RubyOpt::Passes::LiteralValue.read(i, object_table: ot) == 6 }

    loaded = RubyVM::InstructionSequence.load_from_binary(RubyOpt::Codec.encode(ir))
    assert_equal 10, loaded.eval
  end

  def test_mult_div_trailing_divisor_run_folds
    src = "def f(x); x * 2 * 3 / 4 / 5; end; f(100)"
    ir = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    RubyOpt::Passes::ArithReassocPass.new.apply(f, type_env: nil, log: RubyOpt::Log.new, object_table: ot)

    assert_equal 1, f.instructions.count { |i| i.opcode == :opt_mult }
    assert_equal 1, f.instructions.count { |i| i.opcode == :opt_div }
    refute_nil f.instructions.find { |i| RubyOpt::Passes::LiteralValue.read(i, object_table: ot) == 6 }
    refute_nil f.instructions.find { |i| RubyOpt::Passes::LiteralValue.read(i, object_table: ot) == 20 }

    loaded = RubyVM::InstructionSequence.load_from_binary(RubyOpt::Codec.encode(ir))
    assert_equal 30, loaded.eval
  end

  def test_mult_div_crossing_boundary_bails_no_change
    src = "def f(x); x * 2 / 3 * 4; end; f(6)"
    ir = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    before = f.instructions.map(&:opcode)
    log = RubyOpt::Log.new
    RubyOpt::Passes::ArithReassocPass.new.apply(f, type_env: nil, log: log, object_table: ot)

    assert_equal before, f.instructions.map(&:opcode)
    assert(log.entries.any? { |e| e[:reason] == :no_change },
      "expected :no_change log entry, got reasons: #{log.entries.map { |e| e[:reason] }.inspect}")

    loaded = RubyVM::InstructionSequence.load_from_binary(RubyOpt::Codec.encode(ir))
    assert_equal 16, loaded.eval
  end

  def test_mult_div_literal_run_with_mixed_ops_folds
    # 2 * 3 / 6 * x: two literal runs separated by the /6 boundary.
    # The *->/ boundary does not allow 6/6 to further reduce within this pass.
    src = "def f(x); 2 * 3 / 6 * x; end; f(5)"
    ir = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    RubyOpt::Passes::ArithReassocPass.new.apply(f, type_env: nil, log: RubyOpt::Log.new, object_table: ot)

    sixes = f.instructions.count { |i| RubyOpt::Passes::LiteralValue.read(i, object_table: ot) == 6 }
    assert_equal 2, sixes
    assert_equal 1, f.instructions.count { |i| i.opcode == :opt_mult }
    assert_equal 1, f.instructions.count { |i| i.opcode == :opt_div }

    loaded = RubyVM::InstructionSequence.load_from_binary(RubyOpt::Codec.encode(ir))
    assert_equal 5, loaded.eval
  end

  private

  def find_iseq(ir, name)
    return ir if ir.name == name
    ir.children&.each do |c|
      found = find_iseq(c, name)
      return found if found
    end
    nil
  end
end
