# frozen_string_literal: true
require "test_helper"
require "optimize/ir/slot_type_table"

class SlotTypeTableTest < Minitest::Test
  FnStub = Struct.new(:arg_spec, :instructions, :misc, keyword_init: true)
  SigStub = Struct.new(:method_name, :receiver_class, :arg_types, :return_type, :file, :line, keyword_init: true)

  def test_seeds_param_slots_from_signature
    fn  = FnStub.new(arg_spec: { lead_num: 2 }, instructions: [], misc: { local_table_size: 2 })
    sig = SigStub.new(arg_types: %w[Point Point])
    table = Optimize::IR::SlotTypeTable.build(fn, sig, nil)

    assert_equal "Point", table.lookup(0, 0)
    assert_equal "Point", table.lookup(1, 0)
  end

  def test_non_param_slots_are_nil
    fn = FnStub.new(arg_spec: { lead_num: 1 }, instructions: [], misc: { local_table_size: 3 })
    sig = SigStub.new(arg_types: ["Integer"])
    table = Optimize::IR::SlotTypeTable.build(fn, sig, nil)

    assert_equal "Integer", table.lookup(0, 0)
    assert_nil table.lookup(1, 0)
    assert_nil table.lookup(2, 0)
  end

  def test_no_signature_means_empty_seed
    fn = FnStub.new(arg_spec: { lead_num: 1 }, instructions: [], misc: { local_table_size: 1 })
    table = Optimize::IR::SlotTypeTable.build(fn, nil, nil)

    assert_nil table.lookup(0, 0)
  end

  InstStub = Struct.new(:opcode, :operands, keyword_init: true)

  # Minimal fake CallData: SlotTypeTable only reads .argc and .mid_symbol.
  FakeCD = Struct.new(:mid_sym, :argc) do
    def mid_symbol(_object_table) = mid_sym
  end

  def test_new_pattern_types_destination_slot
    # Caller bytecode for: p = Point.new(1, 2)   (size-1 local table, p is slot 0)
    # LINDEX 3 corresponds to slot 0 when size == 1.
    insts = [
      InstStub.new(opcode: :opt_getconstant_path, operands: [[:Point]]),
      InstStub.new(opcode: :putobject_INT2FIX_1_, operands: []),
      InstStub.new(opcode: :putobject_INT2FIX_1_, operands: []),
      InstStub.new(opcode: :opt_send_without_block, operands: [FakeCD.new(:new, 2)]),
      InstStub.new(opcode: :setlocal_WC_0,         operands: [3]),
    ]
    fn = FnStub.new(arg_spec: {}, instructions: insts, misc: { local_table_size: 1 })
    table = Optimize::IR::SlotTypeTable.build(fn, nil, nil)
    assert_equal "Point", table.lookup(0, 0)
  end

  def test_setlocal_from_unrelated_producer_leaves_slot_nil
    insts = [
      InstStub.new(opcode: :putobject,    operands: [42]),
      InstStub.new(opcode: :setlocal_WC_0, operands: [3]),
    ]
    fn = FnStub.new(arg_spec: {}, instructions: insts, misc: { local_table_size: 1 })
    table = Optimize::IR::SlotTypeTable.build(fn, nil, nil)
    assert_nil table.lookup(0, 0)
  end

  def test_unrelated_setlocal_clears_a_previously_typed_slot
    # Seed slot 0 as "Point" via signature, then a plain setlocal in the
    # instruction stream should taint it back to nil.
    insts = [
      InstStub.new(opcode: :putobject,    operands: [42]),
      InstStub.new(opcode: :setlocal_WC_0, operands: [3]),
    ]
    fn = FnStub.new(
      arg_spec: { lead_num: 1 },
      instructions: insts,
      misc: { local_table_size: 1 },
    )
    sig = SigStub.new(arg_types: ["Point"])
    table = Optimize::IR::SlotTypeTable.build(fn, sig, nil)
    assert_nil table.lookup(0, 0)
  end

  def test_cross_level_lookup_walks_to_parent
    parent_fn  = FnStub.new(
      arg_spec: { lead_num: 1 }, instructions: [], misc: { local_table_size: 1 },
    )
    parent_sig = SigStub.new(arg_types: ["Point"])
    parent = Optimize::IR::SlotTypeTable.build(parent_fn, parent_sig, nil)

    child_fn = FnStub.new(
      arg_spec: {}, instructions: [], misc: { local_table_size: 0 },
    )
    child = Optimize::IR::SlotTypeTable.build(child_fn, nil, parent)

    assert_nil child.lookup(0, 0)
    assert_equal "Point", child.lookup(0, 1)
  end

  def test_opt_new_wrapper_types_destination_slot
    # Ruby 4.0+ compiles `p = Point.new(1, 2)` roughly as:
    #   opt_getconstant_path; putnil; swap; <args>; opt_new; opt_send :initialize;
    #   jump; opt_send :new; swap; pop; setlocal
    # The setlocal is preceded by pop, not opt_send :new.
    insts = [
      InstStub.new(opcode: :opt_getconstant_path, operands: [[:Point]]),
      InstStub.new(opcode: :putnil, operands: []),
      InstStub.new(opcode: :swap, operands: []),
      InstStub.new(opcode: :putobject_INT2FIX_1_, operands: []),
      InstStub.new(opcode: :putobject, operands: [2]),
      InstStub.new(opcode: :opt_new, operands: [FakeCD.new(:new, 2), 9]),
      InstStub.new(opcode: :opt_send_without_block, operands: [FakeCD.new(:initialize, 2)]),
      InstStub.new(opcode: :jump, operands: [11]),
      InstStub.new(opcode: :opt_send_without_block, operands: [FakeCD.new(:new, 2)]),
      InstStub.new(opcode: :swap, operands: []),
      InstStub.new(opcode: :pop, operands: []),
      InstStub.new(opcode: :setlocal_WC_0, operands: [3]),
    ]
    fn = FnStub.new(arg_spec: {}, instructions: insts, misc: { local_table_size: 1 })
    table = Optimize::IR::SlotTypeTable.build(fn, nil, nil)
    assert_equal "Point", table.lookup(0, 0)
  end

  def test_lookup_above_root_returns_nil
    fn = FnStub.new(arg_spec: {}, instructions: [], misc: { local_table_size: 0 })
    table = Optimize::IR::SlotTypeTable.build(fn, nil, nil)
    assert_nil table.lookup(0, 3)
  end
end
