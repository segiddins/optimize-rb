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
    refute_empty log.for_pass(:dead_stash_elim).select { |e| e.reason == :dead_stash_eliminated }
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

  def test_leaves_pair_when_second_reader_exists
    fn = build_fn([
      inst(:putobject, [42]),
      inst(:setlocal_WC_0, [1]),
      inst(:getlocal_WC_0, [1]),
      inst(:getlocal_WC_0, [1]),
      inst(:pop, []),
      inst(:leave, []),
    ])
    before = fn.instructions.map(&:opcode)
    apply(fn)
    assert_equal before, fn.instructions.map(&:opcode)
  end

  def test_leaves_pair_when_later_reader_exists
    fn = build_fn([
      inst(:putobject, [42]),
      inst(:setlocal_WC_0, [1]),
      inst(:getlocal_WC_0, [1]),
      inst(:putobject, [99]),
      inst(:pop, []),
      inst(:getlocal_WC_0, [1]),
      inst(:leave, []),
    ])
    before = fn.instructions.map(&:opcode)
    apply(fn)
    assert_equal before, fn.instructions.map(&:opcode)
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

  def test_leaves_pair_when_shorthand_and_explicit_mix
    fn = build_fn([
      inst(:putobject, [42]),
      inst(:setlocal_WC_0, [1]),
      inst(:getlocal, [1, 0]),
      inst(:leave, []),
    ])
    before = fn.instructions.map(&:opcode)
    apply(fn)
    assert_equal before, fn.instructions.map(&:opcode)
  end

  def test_leaves_non_adjacent_pair
    fn = build_fn([
      inst(:putobject, [42]),
      inst(:setlocal_WC_0, [1]),
      inst(:putobject, [1]),
      inst(:pop, []),
      inst(:getlocal_WC_0, [1]),
      inst(:leave, []),
    ])
    before = fn.instructions.map(&:opcode)
    apply(fn)
    assert_equal before, fn.instructions.map(&:opcode)
  end

  def test_drops_multiple_independent_pairs
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
    assert_equal %i[putobject pop putobject leave], fn.instructions.map(&:opcode)
    assert_equal 2, log.for_pass(:dead_stash_elim).count { |e| e.reason == :dead_stash_eliminated }
  end

  def test_rewrite_count_increments_on_fold
    fn = build_fn([
      inst(:putobject, [42]),
      inst(:setlocal_WC_0, [1]),
      inst(:getlocal_WC_0, [1]),
      inst(:leave, []),
    ])
    log = Optimize::Log.new
    apply(fn, log: log)
    assert_equal 1, log.rewrite_count
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
