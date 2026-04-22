# frozen_string_literal: true
require "test_helper"
require "ruby_opt/ir/slot_type_table"

class SlotTypeTableTest < Minitest::Test
  FnStub = Struct.new(:arg_spec, :instructions, :misc, keyword_init: true)
  SigStub = Struct.new(:method_name, :receiver_class, :arg_types, :return_type, :file, :line, keyword_init: true)

  def test_seeds_param_slots_from_signature
    fn  = FnStub.new(arg_spec: { lead_num: 2 }, instructions: [], misc: { local_table_size: 2 })
    sig = SigStub.new(arg_types: %w[Point Point])
    table = RubyOpt::IR::SlotTypeTable.build(fn, sig, nil)

    assert_equal "Point", table.lookup(0, 0)
    assert_equal "Point", table.lookup(1, 0)
  end

  def test_non_param_slots_are_nil
    fn = FnStub.new(arg_spec: { lead_num: 1 }, instructions: [], misc: { local_table_size: 3 })
    sig = SigStub.new(arg_types: ["Integer"])
    table = RubyOpt::IR::SlotTypeTable.build(fn, sig, nil)

    assert_equal "Integer", table.lookup(0, 0)
    assert_nil table.lookup(1, 0)
    assert_nil table.lookup(2, 0)
  end

  def test_no_signature_means_empty_seed
    fn = FnStub.new(arg_spec: { lead_num: 1 }, instructions: [], misc: { local_table_size: 1 })
    table = RubyOpt::IR::SlotTypeTable.build(fn, nil, nil)

    assert_nil table.lookup(0, 0)
  end
end
