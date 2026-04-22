# frozen_string_literal: true
require "test_helper"
require "ruby_opt/codec"
require "ruby_opt/log"
require "ruby_opt/passes/inlining_pass"

class InliningPassTest < Minitest::Test
  def test_zero_arg_constant_fcall_inlined
    src = "def magic; 42; end; def use_it; magic; end; use_it"
    ir  = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot  = ir.misc[:object_table]
    use_it = find_iseq(ir, "use_it")
    magic  = find_iseq(ir, "magic")

    log = RubyOpt::Log.new
    callee_map = { magic: magic }
    RubyOpt::Passes::InliningPass.new.apply(
      use_it, type_env: nil, log: log,
      object_table: ot, callee_map: callee_map,
    )

    # The call site is gone.
    refute use_it.instructions.any? { |i| i.opcode == :opt_send_without_block }
    # Body is now: putobject 42; leave
    assert_equal [:putobject, :leave], use_it.instructions.map(&:opcode)
    assert log.entries.any? { |e| e.reason == :inlined }

    # Round-trip still executes correctly.
    loaded = RubyVM::InstructionSequence.load_from_binary(RubyOpt::Codec.encode(ir))
    assert_equal 42, loaded.eval
  end

  def test_skips_when_callee_has_args
    src = "def add_one(x); x + 1; end; def use_it; add_one(5); end; use_it"
    ir  = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot  = ir.misc[:object_table]
    use_it   = find_iseq(ir, "use_it")
    add_one  = find_iseq(ir, "add_one")
    log = RubyOpt::Log.new
    RubyOpt::Passes::InliningPass.new.apply(
      use_it, type_env: nil, log: log,
      object_table: ot, callee_map: { add_one: add_one },
    )
    assert use_it.instructions.any? { |i| i.opcode == :opt_send_without_block }
    refute log.entries.any? { |e| e.reason == :inlined }
  end

  def test_skips_when_callee_has_branches
    src = "def maybe; 1 > 0 ? 1 : 2; end; def use_it; maybe; end; use_it"
    ir  = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot  = ir.misc[:object_table]
    use_it = find_iseq(ir, "use_it")
    maybe  = find_iseq(ir, "maybe")
    log = RubyOpt::Log.new
    RubyOpt::Passes::InliningPass.new.apply(
      use_it, type_env: nil, log: log,
      object_table: ot, callee_map: { maybe: maybe },
    )
    assert use_it.instructions.any? { |i| i.opcode == :opt_send_without_block }
    assert log.entries.any? { |e| e.reason == :callee_has_branches }
  end

  def test_skips_when_callee_has_locals
    src = "def local_y; y = 5; y; end; def use_it; local_y; end; use_it"
    ir  = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot  = ir.misc[:object_table]
    use_it  = find_iseq(ir, "use_it")
    local_y = find_iseq(ir, "local_y")
    log = RubyOpt::Log.new
    RubyOpt::Passes::InliningPass.new.apply(
      use_it, type_env: nil, log: log,
      object_table: ot, callee_map: { local_y: local_y },
    )
    assert use_it.instructions.any? { |i| i.opcode == :opt_send_without_block }
    refute log.entries.any? { |e| e.reason == :inlined }
  end

  def test_skips_when_callee_makes_nested_call
    src = "def inner; 1; end; def outer; inner; end; def use_it; outer; end; use_it"
    ir  = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot  = ir.misc[:object_table]
    use_it = find_iseq(ir, "use_it")
    outer  = find_iseq(ir, "outer")
    inner  = find_iseq(ir, "inner")
    log = RubyOpt::Log.new
    RubyOpt::Passes::InliningPass.new.apply(
      use_it, type_env: nil, log: log,
      object_table: ot, callee_map: { outer: outer, inner: inner },
    )
    assert use_it.instructions.any? { |i| i.opcode == :opt_send_without_block }
    assert log.entries.any? { |e| e.reason == :callee_makes_call }
  end

  def test_skips_when_callee_unresolved
    src = "def use_it; bogus_name_that_does_not_exist; end; 1"
    ir  = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot  = ir.misc[:object_table]
    use_it = find_iseq(ir, "use_it")
    log = RubyOpt::Log.new
    RubyOpt::Passes::InliningPass.new.apply(
      use_it, type_env: nil, log: log,
      object_table: ot, callee_map: {},
    )
    assert log.entries.any? { |e| e.reason == :callee_unresolved }
  end

  def test_v2_skips_callee_with_multi_local
    src = "def wrap(x); y = x + 1; y; end; def use_it; wrap(3); end; use_it"
    ir  = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot  = ir.misc[:object_table]
    use_it = find_iseq(ir, "use_it")
    wrap   = find_iseq(ir, "wrap")
    log = RubyOpt::Log.new
    RubyOpt::Passes::InliningPass.new.apply(
      use_it, type_env: nil, log: log,
      object_table: ot, callee_map: { wrap: wrap },
    )
    assert use_it.instructions.any? { |i| i.opcode == :opt_send_without_block }
    refute log.entries.any? { |e| e.reason == :inlined }
    assert log.entries.any? { |e| e.reason == :callee_multi_local }
  end

  def test_v2_skips_callee_that_writes_its_arg
    src = "def reassign(x); x = 5; x; end; def use_it; reassign(1); end; use_it"
    ir  = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot  = ir.misc[:object_table]
    use_it   = find_iseq(ir, "use_it")
    reassign = find_iseq(ir, "reassign")
    log = RubyOpt::Log.new
    RubyOpt::Passes::InliningPass.new.apply(
      use_it, type_env: nil, log: log,
      object_table: ot, callee_map: { reassign: reassign },
    )
    assert use_it.instructions.any? { |i| i.opcode == :opt_send_without_block }
    refute log.entries.any? { |e| e.reason == :inlined }
    assert log.entries.any? { |e| e.reason == :callee_writes_local }
  end

  def test_v2_skips_callee_with_two_args
    src = "def add(a, b); a + b; end; def use_it; add(1, 2); end; use_it"
    ir  = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot  = ir.misc[:object_table]
    use_it = find_iseq(ir, "use_it")
    add    = find_iseq(ir, "add")
    log = RubyOpt::Log.new
    RubyOpt::Passes::InliningPass.new.apply(
      use_it, type_env: nil, log: log,
      object_table: ot, callee_map: { add: add },
    )
    assert use_it.instructions.any? { |i| i.opcode == :opt_send_without_block }
    refute log.entries.any? { |e| e.reason == :inlined }
    assert log.entries.any? { |e| e.reason == :callee_has_args }
  end

  private

  def find_iseq(fn, name)
    return fn if fn.name == name
    fn.children.each do |c|
      found = find_iseq(c, name)
      return found if found
    end
    nil
  end
end
