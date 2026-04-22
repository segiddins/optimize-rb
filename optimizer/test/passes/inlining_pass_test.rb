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

  def test_skips_when_callee_has_two_args
    # v2 inlines one-arg FCALLs; two-arg callees still reject.
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
    assert log.entries.any? { |e| e.reason == :callee_writes_local }
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

  def test_v2_inlines_one_arg_literal_fcall
    src = "def double(x); x * 2; end; def use_it; double(3); end; use_it"
    ir  = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot  = ir.misc[:object_table]
    use_it = find_iseq(ir, "use_it")
    double = find_iseq(ir, "double")

    log = RubyOpt::Log.new
    RubyOpt::Passes::InliningPass.new.apply(
      use_it, type_env: nil, log: log,
      object_table: ot, callee_map: { double: double },
    )

    refute use_it.instructions.any? { |i| i.opcode == :opt_send_without_block },
      "expected the send to `double` to be inlined"
    assert log.entries.any? { |e| e.reason == :inlined }
    assert_equal 1, use_it.misc[:local_table_size]

    loaded = RubyVM::InstructionSequence.load_from_binary(RubyOpt::Codec.encode(ir))
    assert_equal 6, loaded.eval
  end

  def test_v2_inlines_one_arg_forwarded_fcall
    src = "def double(x); x * 2; end; def use_it(n); double(n); end; use_it(7)"
    ir  = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot  = ir.misc[:object_table]
    use_it = find_iseq(ir, "use_it")
    double = find_iseq(ir, "double")

    assert_equal 1, use_it.misc[:local_table_size]

    log = RubyOpt::Log.new
    RubyOpt::Passes::InliningPass.new.apply(
      use_it, type_env: nil, log: log,
      object_table: ot, callee_map: { double: double },
    )

    refute use_it.instructions.any? { |i| i.opcode == :opt_send_without_block }
    assert log.entries.any? { |e| e.reason == :inlined }
    assert_equal 2, use_it.misc[:local_table_size]

    loaded = RubyVM::InstructionSequence.load_from_binary(RubyOpt::Codec.encode(ir))
    assert_equal 14, loaded.eval
  end

  def test_v2_skips_arg_with_multi_instruction_push
    src = "def double(x); x * 2; end; def use_it(n); double(n + 1); end; use_it(1)"
    ir  = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot  = ir.misc[:object_table]
    use_it = find_iseq(ir, "use_it")
    double = find_iseq(ir, "double")

    log = RubyOpt::Log.new
    RubyOpt::Passes::InliningPass.new.apply(
      use_it, type_env: nil, log: log,
      object_table: ot, callee_map: { double: double },
    )
    assert use_it.instructions.any? { |i| i.opcode == :opt_send_without_block }
    assert log.entries.any? { |e| e.reason == :unsupported_call_shape }
  end

  def test_v2_inlines_two_one_arg_fcalls_in_same_caller
    # Two independent one-arg callees inlined back-to-back into the same
    # caller. Exercises grow! composing across calls (size 1 → 2 → 3) and
    # the LINDEX +1 shift applying correctly to the FIRST inline's emitted
    # setlocal when the second grow runs.
    src = <<~RUBY
      def double(x); x * 2; end
      def triple(x); x * 3; end
      def use_it(n); double(n) + triple(n); end
      use_it(5)
    RUBY
    ir  = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot  = ir.misc[:object_table]
    use_it = find_iseq(ir, "use_it")
    double = find_iseq(ir, "double")
    triple = find_iseq(ir, "triple")

    # use_it starts with 1 local (the `n` param).
    assert_equal 1, use_it.misc[:local_table_size]

    log = RubyOpt::Log.new
    RubyOpt::Passes::InliningPass.new.apply(
      use_it, type_env: nil, log: log,
      object_table: ot, callee_map: { double: double, triple: triple },
    )

    # Both sends inlined.
    refute use_it.instructions.any? { |i| i.opcode == :opt_send_without_block }
    # local_table grew by 2 (one per inlined arg).
    assert_equal 3, use_it.misc[:local_table_size]
    # Two :inlined entries logged.
    assert_equal 2, log.entries.count { |e| e.reason == :inlined }

    # The semantic check: 5*2 + 5*3 == 25.
    loaded = RubyVM::InstructionSequence.load_from_binary(RubyOpt::Codec.encode(ir))
    assert_equal 25, loaded.eval
  end

  def test_opt_send_eligibility_allows_nested_plain_sends
    # A callee body with attr_reader-style send on self: `def getter; x; end`
    # — where `x` is an instance-method call on self — compiles to
    # `putself; opt_send_without_block :x, 0; leave`. The existing
    # FCALL classifier rejects this as `:callee_makes_call`; the new
    # OPT_SEND classifier should accept it.
    src = "class Foo; attr_reader :x; def getter; x; end; end; 1"
    ir = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    getter = find_iseq(ir, "getter")
    refute_nil getter
    pass = RubyOpt::Passes::InliningPass.new
    assert_nil pass.send(:disqualify_callee_for_opt_send, getter)
  end

  def test_opt_send_eligibility_rejects_getinstancevariable
    src = "class Foo; def read_ivar; @x; end; end; 1"
    ir = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    callee = find_iseq(ir, "read_ivar")
    refute_nil callee
    pass = RubyOpt::Passes::InliningPass.new
    assert_equal :callee_uses_ivar,
                 pass.send(:disqualify_callee_for_opt_send, callee)
  end

  def test_opt_send_eligibility_rejects_branches
    src = "def maybe; 1 > 0 ? 1 : 2; end; 1"
    ir = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    callee = find_iseq(ir, "maybe")
    refute_nil callee
    pass = RubyOpt::Passes::InliningPass.new
    assert_equal :callee_has_branches,
                 pass.send(:disqualify_callee_for_opt_send, callee)
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
