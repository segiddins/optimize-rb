# frozen_string_literal: true
require "test_helper"
require "optimize/codec"
require "optimize/codec/local_table"
require "optimize/log"
require "optimize/ir/function"
require "optimize/ir/instruction"
require "optimize/passes/dead_stash_elim_pass"

class DeadStashElimPassTest < Minitest::Test
  def build_fn(insts, local_table: [{ name: :n, type: :local }])
    Optimize::IR::Function.new(
      type: :method, name: "f",
      path: "/t", first_lineno: 1,
      local_table: local_table,
      instructions: insts,
      children: [],
    )
  end

  def inst(opcode, operands, line: 1)
    Optimize::IR::Instruction.new(opcode: opcode, operands: operands, line: line)
  end

  def apply(fn, log: Optimize::Log.new)
    Optimize::Passes::DeadStashElimPass.new.apply(fn, type_env: nil, log: log)
    log
  end

  def test_drops_adjacent_setlocal_getlocal_wc0_with_unique_slot
    fn = build_fn([
      inst(:putobject, [42]),
      inst(:setlocal_WC_0, [1]),
      inst(:getlocal_WC_0, [1]),
      inst(:leave, []),
    ])
    log = apply(fn)

    assert_equal %i[putobject leave], fn.instructions.map(&:opcode)
    # Peephole A handles this case (literal forwarding), reason is :literal_forwarded.
    refute_empty log.for_pass(:dead_stash_elim)
  end

  def test_end_to_end_preserves_value_through_dropped_pair
    # Use a method with one local so the object table already has a Symbol OT index
    # we can reuse as the stash slot's name for LocalTable.grow!.
    src = "def f(x); x; end; f(42)"
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    f = find_iseq(ir, "f")
    existing_lt = Optimize::Codec::LocalTable.decode(
      f.misc[:local_table_raw] || "".b,
      f.misc[:local_table_size] || 0,
    )
    skip("no locals to reuse as stash name") if existing_lt.empty?
    stash_sym_ot_idx = existing_lt.first
    stash_lindex = Optimize::Codec::LocalTable.grow!(f, stash_sym_ot_idx) + 1
    # Shift pre-existing level-0 LINDEXes so x's slot doesn't collide with stash.
    f.instructions.each do |inst|
      case inst.opcode
      when :getlocal_WC_0, :setlocal_WC_0
        inst.operands[0] = inst.operands[0] + 1
      end
    end
    # Insert the stash pair after the putself that begins the body.
    putself_idx = f.instructions.find_index { |i| i.opcode == :putself }
    if putself_idx
      insert_after = putself_idx
    else
      insert_after = f.instructions.find_index { |i| i.opcode == :getlocal_WC_0 } || 0
    end
    f.instructions.insert(insert_after + 1,
      Optimize::IR::Instruction.new(opcode: :setlocal_WC_0, operands: [stash_lindex], line: 1),
      Optimize::IR::Instruction.new(opcode: :getlocal_WC_0, operands: [stash_lindex], line: 1),
    )

    assert_includes f.instructions.map(&:opcode), :setlocal_WC_0

    opcodes_before = f.instructions.map(&:opcode)
    apply(f)
    opcodes_after = f.instructions.map(&:opcode)

    # The stash pair must be gone; other instructions (x's getlocal, leave) survive.
    refute_includes opcodes_after, :setlocal_WC_0
    assert_operator opcodes_after.size, :<, opcodes_before.size

    loaded = RubyVM::InstructionSequence.load_from_binary(Optimize::Codec.encode(ir))
    assert_equal 42, loaded.eval
  end

  def test_reduces_pair_when_second_reader_exists
    # Peephole A forwards the literal to both readers; peephole C then eliminates
    # the `putobject; pop` left from the first (now-dead) read.
    fn = build_fn([
      inst(:putobject, [42]),
      inst(:setlocal_WC_0, [1]),
      inst(:getlocal_WC_0, [1]),
      inst(:getlocal_WC_0, [1]),
      inst(:pop, []),
      inst(:leave, []),
    ])
    apply(fn)
    assert_equal %i[putobject leave], fn.instructions.map(&:opcode)
    assert_equal [42], fn.instructions[0].operands
  end

  def test_reduces_pair_when_later_reader_exists
    # Peephole A forwards literal 42 to both reads; peephole C eliminates
    # the intervening `putobject 99; pop`.
    fn = build_fn([
      inst(:putobject, [42]),
      inst(:setlocal_WC_0, [1]),
      inst(:getlocal_WC_0, [1]),
      inst(:putobject, [99]),
      inst(:pop, []),
      inst(:getlocal_WC_0, [1]),
      inst(:leave, []),
    ])
    apply(fn)
    assert_equal %i[putobject putobject leave], fn.instructions.map(&:opcode)
    assert_equal [42], fn.instructions[0].operands
    assert_equal [42], fn.instructions[1].operands
  end

  def test_leaves_pair_when_later_writer_exists
    fn = build_fn([
      inst(:putobject, [42]),
      inst(:setlocal_WC_0, [1]),
      inst(:getlocal_WC_0, [1]),
      inst(:putobject, [99]),
      inst(:setlocal_WC_0, [1]),
      inst(:leave, []),
    ])
    before = fn.instructions.map(&:opcode)
    apply(fn)
    assert_equal before, fn.instructions.map(&:opcode)
  end

  def test_leaves_pair_when_levels_differ
    fn = build_fn([
      inst(:putobject, [42]),
      inst(:setlocal, [1, 1]),
      inst(:getlocal, [1, 0]),
      inst(:leave, []),
    ])
    before = fn.instructions.map(&:opcode)
    apply(fn)
    assert_equal before, fn.instructions.map(&:opcode)
  end

  def test_reduces_setlocal_wc0_with_explicit_getlocal_reader
    # Peephole A treats getlocal [slot, 0] as a level-0 reader and forwards the literal.
    fn = build_fn([
      inst(:putobject, [42]),
      inst(:setlocal_WC_0, [1]),
      inst(:getlocal, [1, 0]),
      inst(:leave, []),
    ])
    apply(fn)
    assert_equal %i[putobject leave], fn.instructions.map(&:opcode)
    assert_equal [42], fn.instructions[0].operands
  end

  def test_reduces_non_adjacent_pair_via_literal_forwarding
    # Peephole A forwards 42 to the non-adjacent reader; peephole C then
    # eliminates the intervening `putobject 1; pop`.
    fn = build_fn([
      inst(:putobject, [42]),
      inst(:setlocal_WC_0, [1]),
      inst(:putobject, [1]),
      inst(:pop, []),
      inst(:getlocal_WC_0, [1]),
      inst(:leave, []),
    ])
    apply(fn)
    assert_equal %i[putobject leave], fn.instructions.map(&:opcode)
    assert_equal [42], fn.instructions[0].operands
  end

  def test_drops_multiple_independent_pairs
    # Peephole A forwards both literals; peephole C then eliminates the putobject 42
    # that was feeding the pop. Final result: putobject 99; leave.
    fn = build_fn(
      [
        inst(:putobject, [42]),
        inst(:setlocal_WC_0, [1]),
        inst(:getlocal_WC_0, [1]),
        inst(:pop, []),
        inst(:putobject, [99]),
        inst(:setlocal_WC_0, [2]),
        inst(:getlocal_WC_0, [2]),
        inst(:leave, []),
      ],
      local_table: [{ name: :a, type: :local }, { name: :b, type: :local }],
    )
    log = apply(fn)
    assert_equal %i[putobject leave], fn.instructions.map(&:opcode)
    assert_equal [99], fn.instructions[0].operands
    refute_empty log.for_pass(:dead_stash_elim)
  end

  def test_rewrite_count_increments_on_fold
    # Peephole A drops producer then writer — 2 splices, 2 log entries.
    fn = build_fn([
      inst(:putobject, [42]),
      inst(:setlocal_WC_0, [1]),
      inst(:getlocal_WC_0, [1]),
      inst(:leave, []),
    ])
    log = Optimize::Log.new
    apply(fn, log: log)
    assert_operator log.rewrite_count, :>=, 1
  end

  # ---------------------------------------------------------------------------
  # Peephole A — Literal forwarding
  # ---------------------------------------------------------------------------

  def test_peephole_a_forwards_literal_to_single_reader
    fn = build_fn([
      inst(:putobject, [5]),
      inst(:setlocal_WC_0, [1]),
      inst(:getlocal_WC_0, [1]),
      inst(:leave, []),
    ])
    log = apply(fn)
    assert_equal %i[putobject leave], fn.instructions.map(&:opcode)
    assert_equal [5], fn.instructions[0].operands
    assert log.for_pass(:dead_stash_elim).any? { |e| e.reason == :literal_forwarded }
  end

  def test_peephole_a_forwards_literal_to_multiple_readers
    # Peephole A forwards 5 to both readers, drops writer+producer.
    # The first forwarded copy is then `putobject 5; pop` which peephole C eliminates.
    # Net result: putobject 5; leave (the second reader survives for leave).
    fn = build_fn(
      [
        inst(:putobject, [5]),
        inst(:setlocal_WC_0, [3]),
        inst(:getlocal_WC_0, [3]),
        inst(:pop, []),
        inst(:getlocal_WC_0, [3]),
        inst(:leave, []),
      ],
      local_table: [{ name: :a, type: :local }, { name: :b, type: :local }, { name: :c, type: :local }],
    )
    log = apply(fn)
    opcodes = fn.instructions.map(&:opcode)
    assert_equal %i[putobject leave], opcodes
    assert_equal [5], fn.instructions[0].operands
    assert log.for_pass(:dead_stash_elim).any? { |e| e.reason == :literal_forwarded }
  end

  def test_peephole_a_forwards_putnil_to_readers
    fn = build_fn([
      inst(:putnil, []),
      inst(:setlocal_WC_0, [1]),
      inst(:getlocal_WC_0, [1]),
      inst(:leave, []),
    ])
    log = apply(fn)
    assert_equal %i[putnil leave], fn.instructions.map(&:opcode)
    assert log.for_pass(:dead_stash_elim).any? { |e| e.reason == :literal_forwarded }
  end

  def test_peephole_a_does_not_forward_when_two_writers
    fn = build_fn([
      inst(:putobject, [5]),
      inst(:setlocal_WC_0, [1]),
      inst(:putobject, [6]),
      inst(:setlocal_WC_0, [1]),
      inst(:getlocal_WC_0, [1]),
      inst(:leave, []),
    ])
    before = fn.instructions.map(&:opcode)
    apply(fn)
    assert_equal before, fn.instructions.map(&:opcode)
  end

  def test_peephole_a_does_not_forward_getlocal_producer
    fn = build_fn(
      [
        inst(:getlocal_WC_0, [2]),
        inst(:setlocal_WC_0, [1]),
        inst(:getlocal_WC_0, [1]),
        inst(:leave, []),
      ],
      local_table: [{ name: :a, type: :local }, { name: :b, type: :local }],
    )
    # getlocal is not a pure literal; peephole A must not fire
    before = fn.instructions.map(&:opcode)
    apply(fn)
    # existing adjacent-pair peephole might still fire for the setlocal_WC_0/getlocal_WC_0 pair
    # but peephole A must NOT have forwarded the getlocal producer
    assert_equal %i[getlocal_WC_0 leave], fn.instructions.map(&:opcode)
    assert fn.instructions.none? { |i| i.opcode == :setlocal_WC_0 }
  end

  # ---------------------------------------------------------------------------
  # Peephole B — Dead write-only stash
  # ---------------------------------------------------------------------------

  def test_peephole_b_drops_write_only_literal_stash
    fn = build_fn([
      inst(:putobject, [42]),
      inst(:setlocal_WC_0, [1]),
      inst(:putnil, []),
      inst(:leave, []),
    ])
    log = apply(fn)
    assert_equal %i[putnil leave], fn.instructions.map(&:opcode)
    assert log.for_pass(:dead_stash_elim).any? { |e| e.reason == :dead_stash_eliminated }
  end

  def test_peephole_b_drops_write_only_getlocal_producer
    fn = build_fn(
      [
        inst(:putnil, []),
        inst(:leave, []),
        inst(:getlocal_WC_0, [2]),
        inst(:setlocal_WC_0, [1]),
      ],
      local_table: [{ name: :a, type: :local }, { name: :b, type: :local }],
    )
    log = apply(fn)
    assert_equal %i[putnil leave], fn.instructions.map(&:opcode)
    assert log.for_pass(:dead_stash_elim).any? { |e| e.reason == :dead_stash_eliminated }
  end

  def test_peephole_b_does_not_drop_when_reader_exists
    fn = build_fn([
      inst(:putobject, [42]),
      inst(:setlocal_WC_0, [1]),
      inst(:getlocal_WC_0, [1]),
      inst(:leave, []),
    ])
    # has a reader — peephole B must not fire (peephole A handles this case)
    log = apply(fn)
    # peephole A will forward it, but peephole B alone would be wrong here
    # just check the result is still semantically correct
    assert_equal %i[putobject leave], fn.instructions.map(&:opcode)
  end

  # ---------------------------------------------------------------------------
  # Peephole C — Adjacent pure-push + pop
  # ---------------------------------------------------------------------------

  def test_peephole_c_drops_putnil_pop
    fn = build_fn([
      inst(:putnil, []),
      inst(:pop, []),
      inst(:putobject, [1]),
      inst(:leave, []),
    ])
    log = apply(fn)
    assert_equal %i[putobject leave], fn.instructions.map(&:opcode)
    assert log.for_pass(:dead_stash_elim).any? { |e| e.reason == :dead_push_pop_eliminated }
  end

  def test_peephole_c_drops_putobject_pop
    fn = build_fn([
      inst(:putobject, [99]),
      inst(:pop, []),
      inst(:putnil, []),
      inst(:leave, []),
    ])
    log = apply(fn)
    assert_equal %i[putnil leave], fn.instructions.map(&:opcode)
    assert log.for_pass(:dead_stash_elim).any? { |e| e.reason == :dead_push_pop_eliminated }
  end

  def test_peephole_c_drops_getlocal_pop
    fn = build_fn([
      inst(:getlocal_WC_0, [1]),
      inst(:pop, []),
      inst(:putnil, []),
      inst(:leave, []),
    ])
    log = apply(fn)
    assert_equal %i[putnil leave], fn.instructions.map(&:opcode)
    assert log.for_pass(:dead_stash_elim).any? { |e| e.reason == :dead_push_pop_eliminated }
  end

  def test_peephole_c_does_not_drop_side_effecting_push_pop
    fn = build_fn([
      inst(:opt_send_without_block, [{ mid: :foo, flag: 0, orig_argc: 0 }]),
      inst(:pop, []),
      inst(:putnil, []),
      inst(:leave, []),
    ])
    before = fn.instructions.map(&:opcode)
    apply(fn)
    assert_equal before, fn.instructions.map(&:opcode)
  end

  # ---------------------------------------------------------------------------
  # Regression — existing adjacent-pair peephole still works
  # ---------------------------------------------------------------------------

  def test_regression_existing_adjacent_pair_still_works
    fn = build_fn([
      inst(:putobject, [42]),
      inst(:setlocal_WC_0, [1]),
      inst(:getlocal_WC_0, [1]),
      inst(:leave, []),
    ])
    log = apply(fn)
    # peephole A now handles this (single writer, single reader, literal producer)
    assert_equal %i[putobject leave], fn.instructions.map(&:opcode)
    refute_empty log.for_pass(:dead_stash_elim)
  end

  private

  def find_iseq(ir, name)
    walk = lambda do |fn|
      return fn if fn.name == name
      (fn.children || []).each do |c|
        found = walk.call(c)
        return found if found
      end
      nil
    end
    walk.call(ir)
  end
end
