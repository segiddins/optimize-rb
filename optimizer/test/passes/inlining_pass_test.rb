# frozen_string_literal: true
require "test_helper"
require "optimize/codec"
require "optimize/log"
require "optimize/type_env"
require "optimize/ir/slot_type_table"
require "optimize/passes/inlining_pass"

class InliningPassTest < Minitest::Test
  def test_zero_arg_constant_fcall_inlined
    src = "def magic; 42; end; def use_it; magic; end; use_it"
    ir  = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot  = ir.misc[:object_table]
    use_it = find_iseq(ir, "use_it")
    magic  = find_iseq(ir, "magic")

    log = Optimize::Log.new
    callee_map = { magic: magic }
    Optimize::Passes::InliningPass.new.apply(
      use_it, type_env: nil, log: log,
      object_table: ot, callee_map: callee_map,
    )

    # The call site is gone.
    refute use_it.instructions.any? { |i| i.opcode == :opt_send_without_block }
    # Body is now: putobject 42; leave
    assert_equal [:putobject, :leave], use_it.instructions.map(&:opcode)
    assert log.entries.any? { |e| e.reason == :inlined }

    # Round-trip still executes correctly.
    loaded = RubyVM::InstructionSequence.load_from_binary(Optimize::Codec.encode(ir))
    assert_equal 42, loaded.eval
  end

  def test_skips_when_callee_has_two_args
    # v2 inlines one-arg FCALLs; two-arg callees still reject.
    src = "def add(a, b); a + b; end; def use_it; add(1, 2); end; use_it"
    ir  = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot  = ir.misc[:object_table]
    use_it = find_iseq(ir, "use_it")
    add    = find_iseq(ir, "add")
    log = Optimize::Log.new
    Optimize::Passes::InliningPass.new.apply(
      use_it, type_env: nil, log: log,
      object_table: ot, callee_map: { add: add },
    )
    assert use_it.instructions.any? { |i| i.opcode == :opt_send_without_block }
    refute log.entries.any? { |e| e.reason == :inlined }
    assert log.entries.any? { |e| e.reason == :callee_has_args }
  end

  def test_skips_when_callee_has_branches
    src = "def maybe; 1 > 0 ? 1 : 2; end; def use_it; maybe; end; use_it"
    ir  = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot  = ir.misc[:object_table]
    use_it = find_iseq(ir, "use_it")
    maybe  = find_iseq(ir, "maybe")
    log = Optimize::Log.new
    Optimize::Passes::InliningPass.new.apply(
      use_it, type_env: nil, log: log,
      object_table: ot, callee_map: { maybe: maybe },
    )
    assert use_it.instructions.any? { |i| i.opcode == :opt_send_without_block }
    assert log.entries.any? { |e| e.reason == :callee_has_branches }
  end

  def test_skips_when_callee_has_locals
    src = "def local_y; y = 5; y; end; def use_it; local_y; end; use_it"
    ir  = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot  = ir.misc[:object_table]
    use_it  = find_iseq(ir, "use_it")
    local_y = find_iseq(ir, "local_y")
    log = Optimize::Log.new
    Optimize::Passes::InliningPass.new.apply(
      use_it, type_env: nil, log: log,
      object_table: ot, callee_map: { local_y: local_y },
    )
    assert use_it.instructions.any? { |i| i.opcode == :opt_send_without_block }
    refute log.entries.any? { |e| e.reason == :inlined }
    assert log.entries.any? { |e| e.reason == :callee_writes_local }
  end

  def test_skips_when_callee_makes_nested_call
    src = "def inner; 1; end; def outer; inner; end; def use_it; outer; end; use_it"
    ir  = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot  = ir.misc[:object_table]
    use_it = find_iseq(ir, "use_it")
    outer  = find_iseq(ir, "outer")
    inner  = find_iseq(ir, "inner")
    log = Optimize::Log.new
    Optimize::Passes::InliningPass.new.apply(
      use_it, type_env: nil, log: log,
      object_table: ot, callee_map: { outer: outer, inner: inner },
    )
    assert use_it.instructions.any? { |i| i.opcode == :opt_send_without_block }
    assert log.entries.any? { |e| e.reason == :callee_makes_call }
  end

  def test_skips_when_callee_unresolved
    src = "def use_it; bogus_name_that_does_not_exist; end; 1"
    ir  = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot  = ir.misc[:object_table]
    use_it = find_iseq(ir, "use_it")
    log = Optimize::Log.new
    Optimize::Passes::InliningPass.new.apply(
      use_it, type_env: nil, log: log,
      object_table: ot, callee_map: {},
    )
    assert log.entries.any? { |e| e.reason == :callee_unresolved }
  end

  def test_v2_skips_callee_with_multi_local
    src = "def wrap(x); y = x + 1; y; end; def use_it; wrap(3); end; use_it"
    ir  = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot  = ir.misc[:object_table]
    use_it = find_iseq(ir, "use_it")
    wrap   = find_iseq(ir, "wrap")
    log = Optimize::Log.new
    Optimize::Passes::InliningPass.new.apply(
      use_it, type_env: nil, log: log,
      object_table: ot, callee_map: { wrap: wrap },
    )
    assert use_it.instructions.any? { |i| i.opcode == :opt_send_without_block }
    refute log.entries.any? { |e| e.reason == :inlined }
    assert log.entries.any? { |e| e.reason == :callee_multi_local }
  end

  def test_v2_skips_callee_that_writes_its_arg
    src = "def reassign(x); x = 5; x; end; def use_it; reassign(1); end; use_it"
    ir  = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot  = ir.misc[:object_table]
    use_it   = find_iseq(ir, "use_it")
    reassign = find_iseq(ir, "reassign")
    log = Optimize::Log.new
    Optimize::Passes::InliningPass.new.apply(
      use_it, type_env: nil, log: log,
      object_table: ot, callee_map: { reassign: reassign },
    )
    assert use_it.instructions.any? { |i| i.opcode == :opt_send_without_block }
    refute log.entries.any? { |e| e.reason == :inlined }
    assert log.entries.any? { |e| e.reason == :callee_writes_local }
  end

  def test_v2_skips_callee_with_two_args
    src = "def add(a, b); a + b; end; def use_it; add(1, 2); end; use_it"
    ir  = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot  = ir.misc[:object_table]
    use_it = find_iseq(ir, "use_it")
    add    = find_iseq(ir, "add")
    log = Optimize::Log.new
    Optimize::Passes::InliningPass.new.apply(
      use_it, type_env: nil, log: log,
      object_table: ot, callee_map: { add: add },
    )
    assert use_it.instructions.any? { |i| i.opcode == :opt_send_without_block }
    refute log.entries.any? { |e| e.reason == :inlined }
    assert log.entries.any? { |e| e.reason == :callee_has_args }
  end

  def test_v2_inlines_one_arg_literal_fcall
    src = "def double(x); x * 2; end; def use_it; double(3); end; use_it"
    ir  = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot  = ir.misc[:object_table]
    use_it = find_iseq(ir, "use_it")
    double = find_iseq(ir, "double")

    log = Optimize::Log.new
    Optimize::Passes::InliningPass.new.apply(
      use_it, type_env: nil, log: log,
      object_table: ot, callee_map: { double: double },
    )

    refute use_it.instructions.any? { |i| i.opcode == :opt_send_without_block },
      "expected the send to `double` to be inlined"
    assert log.entries.any? { |e| e.reason == :inlined }
    assert_equal 1, use_it.misc[:local_table_size]

    loaded = RubyVM::InstructionSequence.load_from_binary(Optimize::Codec.encode(ir))
    assert_equal 6, loaded.eval
  end

  def test_v2_inlines_one_arg_forwarded_fcall
    src = "def double(x); x * 2; end; def use_it(n); double(n); end; use_it(7)"
    ir  = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot  = ir.misc[:object_table]
    use_it = find_iseq(ir, "use_it")
    double = find_iseq(ir, "double")

    assert_equal 1, use_it.misc[:local_table_size]

    log = Optimize::Log.new
    Optimize::Passes::InliningPass.new.apply(
      use_it, type_env: nil, log: log,
      object_table: ot, callee_map: { double: double },
    )

    refute use_it.instructions.any? { |i| i.opcode == :opt_send_without_block }
    assert log.entries.any? { |e| e.reason == :inlined }
    assert_equal 2, use_it.misc[:local_table_size]

    loaded = RubyVM::InstructionSequence.load_from_binary(Optimize::Codec.encode(ir))
    assert_equal 14, loaded.eval
  end

  def test_v2_skips_arg_with_multi_instruction_push
    src = "def double(x); x * 2; end; def use_it(n); double(n + 1); end; use_it(1)"
    ir  = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot  = ir.misc[:object_table]
    use_it = find_iseq(ir, "use_it")
    double = find_iseq(ir, "double")

    log = Optimize::Log.new
    Optimize::Passes::InliningPass.new.apply(
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
    ir  = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot  = ir.misc[:object_table]
    use_it = find_iseq(ir, "use_it")
    double = find_iseq(ir, "double")
    triple = find_iseq(ir, "triple")

    # use_it starts with 1 local (the `n` param).
    assert_equal 1, use_it.misc[:local_table_size]

    log = Optimize::Log.new
    Optimize::Passes::InliningPass.new.apply(
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
    loaded = RubyVM::InstructionSequence.load_from_binary(Optimize::Codec.encode(ir))
    assert_equal 25, loaded.eval
  end

  def test_opt_send_eligibility_allows_nested_plain_sends
    # A callee body with attr_reader-style send on self: `def getter; x; end`
    # — where `x` is an instance-method call on self — compiles to
    # `putself; opt_send_without_block :x, 0; leave`. The existing
    # FCALL classifier rejects this as `:callee_makes_call`; the new
    # OPT_SEND classifier should accept it.
    src = "class Foo; attr_reader :x; def getter; x; end; end; 1"
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    getter = find_iseq(ir, "getter")
    refute_nil getter
    pass = Optimize::Passes::InliningPass.new
    assert_nil pass.send(:disqualify_callee_for_opt_send, getter, 0)
  end

  def test_opt_send_eligibility_rejects_getinstancevariable
    src = "class Foo; def read_ivar; @x; end; end; 1"
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    callee = find_iseq(ir, "read_ivar")
    refute_nil callee
    pass = Optimize::Passes::InliningPass.new
    assert_equal :callee_uses_ivar,
                 pass.send(:disqualify_callee_for_opt_send, callee, 0)
  end

  def test_opt_send_eligibility_rejects_branches
    src = "def maybe; 1 > 0 ? 1 : 2; end; 1"
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    callee = find_iseq(ir, "maybe")
    refute_nil callee
    pass = Optimize::Passes::InliningPass.new
    assert_equal :callee_has_branches,
                 pass.send(:disqualify_callee_for_opt_send, callee, 0)
  end

  def test_opt_send_with_typed_receiver_and_constant_body_splices
    # Note: this test does NOT call .eval, so it does not leak class definitions
    # into the top-level namespace. The unique class name is used for consistency
    # with the round-trip test below, which does call .eval and would otherwise
    # collide with test/codec/corpus/class_with_ivars.rb's `class Point`.
    src = <<~RUBY
      class InliningOptSendT8Point
        # @rbs (InliningOptSendT8Point) -> Integer
        def distance_to(other); 42; end
      end
      # @rbs (InliningOptSendT8Point, InliningOptSendT8Point) -> Integer
      def distance(p, q); p.distance_to(q); end
      distance(InliningOptSendT8Point.new, InliningOptSendT8Point.new)
    RUBY
    ir       = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot       = ir.misc[:object_table]
    type_env = Optimize::TypeEnv.from_source(src, "t.rb")
    caller   = find_iseq(ir, "distance")
    callee   = find_iseq(ir, "distance_to")
    refute_nil caller
    refute_nil callee

    caller_sig = type_env.signature_for_function(caller, class_context: nil)
    refute_nil caller_sig, "caller must have an @rbs signature for this test"
    slot_table = Optimize::IR::SlotTypeTable.build(caller, caller_sig, nil, object_table: ot)
    slot_type_map = {}.compare_by_identity
    slot_type_map[caller] = slot_table

    original_locals = caller.misc[:local_table_size]
    log = Optimize::Log.new
    Optimize::Passes::InliningPass.new.apply(
      caller,
      type_env: type_env, log: log,
      object_table: ot,
      callee_map: { ["InliningOptSendT8Point", :distance_to] => callee },
      slot_type_map: slot_type_map,
    )

    ops = caller.instructions.map(&:opcode)
    refute_includes ops, :opt_send_without_block, "call site should be spliced"
    assert_includes ops, :putobject, "constant body should appear in caller"
    assert log.entries.any? { |e| e.reason == :inlined }
    # Arg-stash slot added; no self-stash since body has no putself.
    assert_equal original_locals + 1, caller.misc[:local_table_size]
  end

  def test_opt_send_with_typed_receiver_roundtrips_through_vm
    # Uses a unique class name (InliningOptSendT8Point instead of Point) to
    # avoid top-level namespace collision with test/codec/corpus/class_with_ivars.rb
    # which also defines `class Point`. The .eval call leaks the class definition
    # into the process namespace, causing ordering-dependent flakes.
    src = <<~RUBY
      class InliningOptSendT8Point
        # @rbs (InliningOptSendT8Point) -> Integer
        def distance_to(other); 42; end
      end
      # @rbs (InliningOptSendT8Point, InliningOptSendT8Point) -> Integer
      def distance(p, q); p.distance_to(q); end
      distance(InliningOptSendT8Point.new, InliningOptSendT8Point.new)
    RUBY
    ir       = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot       = ir.misc[:object_table]
    type_env = Optimize::TypeEnv.from_source(src, "t.rb")
    caller   = find_iseq(ir, "distance")
    callee   = find_iseq(ir, "distance_to")

    caller_sig = type_env.signature_for_function(caller, class_context: nil)
    slot_table = Optimize::IR::SlotTypeTable.build(caller, caller_sig, nil, object_table: ot)
    slot_type_map = {}.compare_by_identity
    slot_type_map[caller] = slot_table

    log = Optimize::Log.new
    Optimize::Passes::InliningPass.new.apply(
      caller,
      type_env: type_env, log: log,
      object_table: ot,
      callee_map: { ["InliningOptSendT8Point", :distance_to] => callee },
      slot_type_map: slot_type_map,
    )
    # Sanity: confirm the inline actually happened before we trust the eval.
    assert log.entries.any? { |e| e.reason == :inlined }

    loaded = RubyVM::InstructionSequence.load_from_binary(Optimize::Codec.encode(ir))
    assert_equal 42, loaded.eval
  end

  def test_opt_send_body_with_putself_is_rewritten_to_self_stash
    # Uses a unique class name (InliningOptSendT9Box instead of Box) to avoid
    # top-level namespace pollution via .eval — any other test defining `class Box`
    # would cause ordering-dependent flakes under different seeds.
    src = <<~RUBY
      class InliningOptSendT9Box
        attr_reader :v
        def initialize(v); @v = v; end
        # @rbs (InliningOptSendT9Box) -> Integer
        def diff(other); v; end
      end
      # @rbs (InliningOptSendT9Box, InliningOptSendT9Box) -> Integer
      def driver(p, q); p.diff(q); end
      driver(InliningOptSendT9Box.new(7), InliningOptSendT9Box.new(3))
    RUBY
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    type_env = Optimize::TypeEnv.from_source(src, "t.rb")
    caller = find_iseq(ir, "driver")
    callee = find_iseq(ir, "diff")

    caller_sig = type_env.signature_for_function(caller, class_context: nil)
    slot_table = Optimize::IR::SlotTypeTable.build(caller, caller_sig, nil, object_table: ot)
    slot_type_map = {}.compare_by_identity
    slot_type_map[caller] = slot_table

    original_locals = caller.misc[:local_table_size]
    log = Optimize::Log.new
    Optimize::Passes::InliningPass.new.apply(
      caller,
      type_env: type_env, log: log,
      object_table: ot,
      callee_map: { ["InliningOptSendT9Box", :diff] => callee },
      slot_type_map: slot_type_map,
    )

    # Inline happened.
    assert log.entries.any? { |e| e.reason == :inlined }
    # Two stash slots grown (self-stash + arg-stash).
    assert_equal original_locals + 2, caller.misc[:local_table_size]
    # No putself remains — all rewritten to getlocal_WC_0.
    refute caller.instructions.any? { |i| i.opcode == :putself },
      "all putself in spliced body should be rewritten to self-stash reads"
    # The call site is gone.
    refute caller.instructions.any? { |i| i.opcode == :opt_send_without_block && i.operands[0].mid_symbol(ot) == :diff }

    # Round-trip through VM: driver(Box.new(7), Box.new(3)) returns p.v == 7.
    loaded = RubyVM::InstructionSequence.load_from_binary(Optimize::Codec.encode(ir))
    assert_equal 7, loaded.eval
  end

  # ---- v4: multi-arg OPT_SEND (argc >= 2) ----

  def test_opt_send_two_arg_constant_body_splices
    src = <<~RUBY
      class InliningOptSendT10Pair
        def sum(a, b); 42; end
      end
      # @rbs (InliningOptSendT10Pair, Integer, Integer) -> Integer
      def driver(p, x, y); p.sum(x, y); end
      driver(InliningOptSendT10Pair.new, 1, 2)
    RUBY
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    type_env = Optimize::TypeEnv.from_source(src, "t.rb")
    caller   = find_iseq(ir, "driver")
    callee   = find_iseq(ir, "sum")
    refute_nil caller
    refute_nil callee

    caller_sig = type_env.signature_for_function(caller, class_context: nil)
    slot_table = Optimize::IR::SlotTypeTable.build(caller, caller_sig, nil, object_table: ot)
    slot_type_map = {}.compare_by_identity
    slot_type_map[caller] = slot_table

    original_locals = caller.misc[:local_table_size]
    log = Optimize::Log.new
    Optimize::Passes::InliningPass.new.apply(
      caller,
      type_env: type_env, log: log,
      object_table: ot,
      callee_map: { ["InliningOptSendT10Pair", :sum] => callee },
      slot_type_map: slot_type_map,
    )

    ops = caller.instructions.map(&:opcode)
    refute_includes ops, :opt_send_without_block, "call site should be spliced"
    assert_includes ops, :putobject, "constant body should appear in caller"
    assert log.entries.any? { |e| e.reason == :inlined }
    # Two arg-stash slots added; no self-stash since body has no putself.
    assert_equal original_locals + 2, caller.misc[:local_table_size]
  end

  def test_opt_send_two_arg_roundtrips_through_vm
    src = <<~RUBY
      class InliningOptSendT10Pair
        # @rbs (Integer, Integer) -> Integer
        def sum(a, b); a + b; end
      end
      # @rbs (InliningOptSendT10Pair, Integer, Integer) -> Integer
      def driver(p, x, y); p.sum(x, y); end
      driver(InliningOptSendT10Pair.new, 3, 4)
    RUBY
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    type_env = Optimize::TypeEnv.from_source(src, "t.rb")
    caller   = find_iseq(ir, "driver")
    callee   = find_iseq(ir, "sum")

    caller_sig = type_env.signature_for_function(caller, class_context: nil)
    slot_table = Optimize::IR::SlotTypeTable.build(caller, caller_sig, nil, object_table: ot)
    slot_type_map = {}.compare_by_identity
    slot_type_map[caller] = slot_table

    log = Optimize::Log.new
    Optimize::Passes::InliningPass.new.apply(
      caller,
      type_env: type_env, log: log,
      object_table: ot,
      callee_map: { ["InliningOptSendT10Pair", :sum] => callee },
      slot_type_map: slot_type_map,
    )
    assert log.entries.any? { |e| e.reason == :inlined }, "argc=2 inline did not fire"

    loaded = RubyVM::InstructionSequence.load_from_binary(Optimize::Codec.encode(ir))
    assert_equal 7, loaded.eval
  end

  def test_opt_send_two_arg_body_with_putself_is_rewritten_to_self_stash
    # 2-arg method whose body uses self (attr_reader style). Verifies
    # self-stash lands at the highest new LINDEX and putself is rewritten.
    src = <<~RUBY
      class InliningOptSendT11Box
        attr_reader :v
        def initialize(v); @v = v; end
        # @rbs (Integer, Integer) -> Integer
        def combine(a, b); v; end
      end
      # @rbs (InliningOptSendT11Box, Integer, Integer) -> Integer
      def driver(p, x, y); p.combine(x, y); end
      driver(InliningOptSendT11Box.new(9), 1, 2)
    RUBY
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    type_env = Optimize::TypeEnv.from_source(src, "t.rb")
    caller = find_iseq(ir, "driver")
    callee = find_iseq(ir, "combine")

    caller_sig = type_env.signature_for_function(caller, class_context: nil)
    slot_table = Optimize::IR::SlotTypeTable.build(caller, caller_sig, nil, object_table: ot)
    slot_type_map = {}.compare_by_identity
    slot_type_map[caller] = slot_table

    original_locals = caller.misc[:local_table_size]
    log = Optimize::Log.new
    Optimize::Passes::InliningPass.new.apply(
      caller,
      type_env: type_env, log: log,
      object_table: ot,
      callee_map: { ["InliningOptSendT11Box", :combine] => callee },
      slot_type_map: slot_type_map,
    )

    assert log.entries.any? { |e| e.reason == :inlined }
    # Three stash slots: 2 args + self.
    assert_equal original_locals + 3, caller.misc[:local_table_size]
    refute caller.instructions.any? { |i| i.opcode == :putself },
      "putself in spliced body must be rewritten to self-stash read"
    refute caller.instructions.any? { |i| i.opcode == :opt_send_without_block && i.operands[0].mid_symbol(ot) == :combine }

    loaded = RubyVM::InstructionSequence.load_from_binary(Optimize::Codec.encode(ir))
    assert_equal 9, loaded.eval
  end

  def test_opt_send_three_arg_roundtrips_through_vm
    # argc=3 with all three args used in the body. Exercises the
    # general N-arg stashing path end-to-end.
    src = <<~RUBY
      class InliningOptSendT12Triple
        # @rbs (Integer, Integer, Integer) -> Integer
        def combine3(a, b, c); a + b + c; end
      end
      # @rbs (InliningOptSendT12Triple, Integer, Integer, Integer) -> Integer
      def driver(p, x, y, z); p.combine3(x, y, z); end
      driver(InliningOptSendT12Triple.new, 10, 20, 30)
    RUBY
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    type_env = Optimize::TypeEnv.from_source(src, "t.rb")
    caller = find_iseq(ir, "driver")
    callee = find_iseq(ir, "combine3")

    caller_sig = type_env.signature_for_function(caller, class_context: nil)
    slot_table = Optimize::IR::SlotTypeTable.build(caller, caller_sig, nil, object_table: ot)
    slot_type_map = {}.compare_by_identity
    slot_type_map[caller] = slot_table

    original_locals = caller.misc[:local_table_size]
    log = Optimize::Log.new
    Optimize::Passes::InliningPass.new.apply(
      caller,
      type_env: type_env, log: log,
      object_table: ot,
      callee_map: { ["InliningOptSendT12Triple", :combine3] => callee },
      slot_type_map: slot_type_map,
    )

    assert log.entries.any? { |e| e.reason == :inlined }, "argc=3 inline did not fire"
    # Three arg-stash slots; no self-stash (body doesn't use self).
    assert_equal original_locals + 3, caller.misc[:local_table_size]

    loaded = RubyVM::InstructionSequence.load_from_binary(Optimize::Codec.encode(ir))
    assert_equal 60, loaded.eval
  end

  # Helper: build a typed caller + slot_type_map for OPT_SEND guard tests.
  # Returns [caller_fn, callee_fn, slot_type_map, type_env, ot]. The caller's
  # type_env seeds slot 0 as "GuardClass"; the callee for "GuardClass#mid"
  # lives inside the compiled source, so tests can synthesize the callee_map
  # themselves if they want a specific kind of failure.
  def build_guard_caller(callee_body_src)
    src = <<~RUBY
      class GuardClass
        #{callee_body_src}
      end
      # @rbs (GuardClass, GuardClass) -> Integer
      def driver(p, q); p.mid(q); end
      driver(GuardClass.new, GuardClass.new)
    RUBY
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    type_env = Optimize::TypeEnv.from_source(src, "t.rb")
    caller   = find_iseq(ir, "driver")
    callee   = find_iseq(ir, "mid")
    caller_sig = type_env.signature_for_function(caller, class_context: nil)
    slot_table = Optimize::IR::SlotTypeTable.build(caller, caller_sig, nil, object_table: ot)
    slot_type_map = {}.compare_by_identity
    slot_type_map[caller] = slot_table
    [caller, callee, slot_type_map, type_env, ot]
  end

  def apply_inliner(caller, callee_map, slot_type_map, type_env, ot)
    log = Optimize::Log.new
    Optimize::Passes::InliningPass.new.apply(
      caller,
      type_env: type_env, log: log,
      object_table: ot,
      callee_map: callee_map,
      slot_type_map: slot_type_map,
    )
    log
  end

  def test_opt_send_skips_when_receiver_slot_untyped
    # No @rbs signature on driver → slot_type_map contains a table with
    # no signature, so slot 0 is untyped.
    src = <<~RUBY
      class NoSigClass
        def mid(other); other; end
      end
      def driver(p, q); p.mid(q); end    # intentionally no @rbs
      driver(NoSigClass.new, NoSigClass.new)
    RUBY
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    type_env = Optimize::TypeEnv.from_source(src, "t.rb")
    caller = find_iseq(ir, "driver")
    callee = find_iseq(ir, "mid")
    slot_table = Optimize::IR::SlotTypeTable.build(caller, nil, nil, object_table: ot)
    slot_type_map = {}.compare_by_identity
    slot_type_map[caller] = slot_table

    log = apply_inliner(caller, { ["NoSigClass", :mid] => callee }, slot_type_map, type_env, ot)

    assert caller.instructions.any? { |i| i.opcode == :opt_send_without_block },
      "opt_send survives when receiver slot has no type"
    refute log.entries.any? { |e| e.reason == :inlined },
      "no inline should have happened"
  end

  def test_opt_send_skips_when_callee_not_in_map
    caller, _callee, slot_type_map, type_env, ot =
      build_guard_caller("def mid(other); other; end")
    # Empty callee_map.
    log = apply_inliner(caller, {}, slot_type_map, type_env, ot)

    assert caller.instructions.any? { |i| i.opcode == :opt_send_without_block }
    assert log.entries.any? { |e| e.reason == :callee_unresolved }
  end

  def test_opt_send_skips_when_callee_has_branches
    caller, callee, slot_type_map, type_env, ot =
      build_guard_caller("def mid(other); other ? 1 : 2; end")
    log = apply_inliner(caller, { ["GuardClass", :mid] => callee }, slot_type_map, type_env, ot)

    assert caller.instructions.any? { |i| i.opcode == :opt_send_without_block }
    assert log.entries.any? { |e| e.reason == :callee_has_branches }
  end

  def test_opt_send_skips_when_callee_has_catch_entry
    # Ruby's `rescue` compiles with a catch table.
    caller, callee, slot_type_map, type_env, ot =
      build_guard_caller("def mid(other); other; rescue; nil; end")
    log = apply_inliner(caller, { ["GuardClass", :mid] => callee }, slot_type_map, type_env, ot)

    assert caller.instructions.any? { |i| i.opcode == :opt_send_without_block }
    assert log.entries.any? { |e| e.reason == :callee_has_catch }
  end

  def test_opt_send_skips_when_callee_has_multi_local
    caller, callee, slot_type_map, type_env, ot =
      build_guard_caller("def mid(other); y = other; y; end")
    log = apply_inliner(caller, { ["GuardClass", :mid] => callee }, slot_type_map, type_env, ot)

    assert caller.instructions.any? { |i| i.opcode == :opt_send_without_block }
    assert log.entries.any? { |e| e.reason == :callee_multi_local }
  end

  def test_opt_send_skips_when_callee_uses_ivar
    caller, callee, slot_type_map, type_env, ot =
      build_guard_caller("def mid(other); @x; end")
    log = apply_inliner(caller, { ["GuardClass", :mid] => callee }, slot_type_map, type_env, ot)

    assert caller.instructions.any? { |i| i.opcode == :opt_send_without_block }
    assert log.entries.any? { |e| e.reason == :callee_uses_ivar }
  end

  def test_opt_send_skips_when_callee_uses_block
    # A callee that yields compiles with invokeblock in the IR body; the
    # invokeblock instruction is terminal in the IR encoding so the iseq does
    # not end with :leave — which means :callee_no_trailing_leave fires before
    # the body-scan loop even checks for :invokeblock.  Both reasons correctly
    # reject the callee, so we accept any of them.
    caller, callee, slot_type_map, type_env, ot =
      build_guard_caller("def mid(other); yield other; end")
    log = apply_inliner(caller, { ["GuardClass", :mid] => callee }, slot_type_map, type_env, ot)

    assert caller.instructions.any? { |i| i.opcode == :opt_send_without_block }
    assert log.entries.any? { |e|
      [:callee_uses_block, :callee_send_has_block, :callee_no_trailing_leave].include?(e.reason)
    }, "expected block-related or no-trailing-leave rejection, got: #{log.entries.map(&:reason).inspect}"
  end

  def test_inlining_same_method_twice_does_not_alias_callee_body
    # Two call sites for the same one-arg callee in the same function.
    # The second inline triggers the LINDEX shift that corrupts the first
    # inline's spliced-in body when the Instruction objects are shared
    # (shallow slice bug). Each setlocal_WC_0 stash must be immediately
    # followed by a getlocal_WC_0 that reads the same slot.
    src = <<~RUBY
      def double(x); x * 2; end
      def use_it(n); double(n) + double(n); end
      use_it(5)
    RUBY
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    use_it = find_iseq(ir, "use_it")
    double = find_iseq(ir, "double")

    log = Optimize::Log.new
    Optimize::Passes::InliningPass.new.apply(
      use_it, type_env: nil, log: log,
      object_table: ot, callee_map: { double: double },
    )

    # Both sends should be inlined.
    assert_equal 2, log.entries.count { |e| e.reason == :inlined }

    # For every inliner stash (setlocal_WC_0 followed immediately by
    # getlocal_WC_0), the slots must match. Aliasing would cause the
    # second body's getlocal to read a slot that was already shifted.
    insts = use_it.instructions
    insts.each_with_index do |inst, i|
      next unless inst.opcode == :setlocal_WC_0
      next_inst = insts[i + 1]
      next unless next_inst&.opcode == :getlocal_WC_0
      assert_equal inst.operands[0], next_inst.operands[0],
        "inline stash at #{i} writes slot #{inst.operands[0]} but next getlocal reads slot #{next_inst.operands[0]} — aliasing bug"
    end

    # Semantic check: the VM must produce 20 (5*2 + 5*2).
    loaded = RubyVM::InstructionSequence.load_from_binary(Optimize::Codec.encode(ir))
    assert_equal 20, loaded.eval
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

  def test_opt_send_in_block_iseq_reads_parent_slot_type
    # @rbs (Box, Box) -> Integer on the caller means slot 0 (p) is typed "Box".
    # Inside the block body `p.diff(q)`, the call site reads `p` via
    # getlocal_WC_1 (level 1). decode_getlocal must consult the parent
    # frame's local_table_size, and slot_table.lookup(slot, 1) must find
    # the type in the parent SlotTypeTable.
    src = <<~RUBY
      class InliningT11Box
        attr_reader :v
        def initialize(v); @v = v; end
        # @rbs (InliningT11Box) -> Integer
        def diff(other); v; end
      end
      # @rbs (InliningT11Box, InliningT11Box) -> Integer
      def driver(p, q)
        1.times { p.diff(q) }
        p.diff(q)   # also assert the non-block path still works
      end
      driver(InliningT11Box.new(11), InliningT11Box.new(5))
    RUBY
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    type_env = Optimize::TypeEnv.from_source(src, "t.rb")
    driver = find_iseq(ir, "driver")
    callee = find_iseq(ir, "diff")
    refute_nil driver
    refute_nil callee

    # The block iseq lives inside driver.children. find its iseq — its type
    # should be :block and its parent is driver.
    block_iseq = driver.children.find { |c| c.type == :block }
    refute_nil block_iseq, "driver should have a block child for `1.times { ... }`"

    # Build slot_type_map the same way Pipeline does: walk with parent chain.
    driver_sig   = type_env.signature_for_function(driver, class_context: nil)
    driver_table = Optimize::IR::SlotTypeTable.build(driver, driver_sig, nil, object_table: ot)
    block_table  = Optimize::IR::SlotTypeTable.build(block_iseq, nil, driver_table, object_table: ot)
    slot_type_map = {}.compare_by_identity
    slot_type_map[driver]     = driver_table
    slot_type_map[block_iseq] = block_table

    callee_map = { ["InliningT11Box", :diff] => callee }

    pass = Optimize::Passes::InliningPass.new
    log = Optimize::Log.new
    # Apply to driver first, then block (order mirrors Pipeline's walk).
    pass.apply(driver,     type_env: type_env, log: log, object_table: ot,
                            callee_map: callee_map, slot_type_map: slot_type_map)
    pass.apply(block_iseq, type_env: type_env, log: log, object_table: ot,
                            callee_map: callee_map, slot_type_map: slot_type_map)

    inlined_in_block = log.entries.count { |e|
      e.reason == :inlined && (e.respond_to?(:file) ? true : false)
    }
    # Expect at least 2 inlines: one in driver (non-block), one in block.
    assert(log.entries.count { |e| e.reason == :inlined } >= 2,
           "expected at least 2 :inlined entries, got log: #{log.entries.inspect}")

    # Block iseq now has no opt_send_without_block for :diff.
    diff_sym = :diff
    refute block_iseq.instructions.any? { |i|
      i.opcode == :opt_send_without_block &&
        i.operands[0].mid_symbol(ot) == diff_sym
    }, "block's diff call should be inlined"
  end
end
