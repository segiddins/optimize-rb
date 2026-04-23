# RBS Type Env v1 — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship receiver-resolving inlining for `p.distance_to(q)` end-to-end, driven by RBS signatures on the caller and constructor-return inference from `ClassName.new`.

**Architecture:** New `IR::SlotTypeTable` (signature-param seeding + `.new` constructor prop + cross-level parent chain) and two `TypeEnv` queries unlock an OPT_SEND recognizer inside `Passes::InliningPass`. `Pipeline` pre-builds two function-keyed maps (signature + slot-type-table) and threads them to passes as extras alongside the existing `callee_map`, which is extended to key instance methods by `(receiver_class, method_name)` tuples.

**Tech Stack:** Ruby, Prism (already used in `RbsParser`), Minitest, `jj` VCS.

**Reference spec:** `docs/superpowers/specs/2026-04-22-rbs-type-env-v1-design.md`.

---

## Commit discipline

Every task ends with `jj split -m "..." <explicit files>` to carve that task's changes out of the working copy (see user memory `feedback_jj_split_explicit_files`). Never `jj commit`. Never `jj describe` for finalization. Each task's commit message should match the convention the repo uses (`feat:`, `test:`, `refactor:`, `docs:`).

## Running the test suite

Tests run inside the Docker sandbox via the `run_optimizer_tests` MCP tool (see `optimizer/lib/optimize` and the user memory about the Ruby MCP server). **Do not** shell out to `bundle exec rake test` — route through the MCP tool.

Per-test invocation: the MCP tool accepts a `TESTOPTS="--name=/pattern/"` style filter. When a step says "run test X", invoke the MCP tool with the file path and the `-n /test_name/` filter.

---

## Task 1: `SlotTypeTable` — signature-param seeding

**Files:**
- Create: `optimizer/lib/optimize/ir/slot_type_table.rb`
- Create: `optimizer/test/ir/slot_type_table_test.rb`

- [ ] **Step 1: Write the failing test for signature-param seeding**

Create `optimizer/test/ir/slot_type_table_test.rb`:

```ruby
# frozen_string_literal: true
require "test_helper"
require "optimize/ir/slot_type_table"

class SlotTypeTableTest < Minitest::Test
  # A minimal stub IR::Function-ish object — we only need :arg_spec + :instructions.
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
end
```

- [ ] **Step 2: Run test to verify it fails**

MCP `run_optimizer_tests` with `test/ir/slot_type_table_test.rb`.
Expected: FAIL with `LoadError: cannot load such file -- optimize/ir/slot_type_table`.

- [ ] **Step 3: Minimal implementation**

Create `optimizer/lib/optimize/ir/slot_type_table.rb`:

```ruby
# frozen_string_literal: true

module Optimize
  module IR
    # Per-function map from local-slot-index → type-string.
    # v1: populated from (a) RBS signature param types, (b) ClassName.new
    # constructor-prop (added in a later task). Parent ref enables
    # cross-iseq-level lookup from block bodies.
    class SlotTypeTable
      attr_reader :parent

      def self.build(function, signature, parent)
        new(function, signature, parent)
      end

      def initialize(function, signature, parent)
        @slot_types = {}
        @parent = parent
        seed_from_signature(function, signature)
      end

      # Look up the type of `slot` at level `level` relative to this table.
      # Walks up `level` parent tables; returns nil if no type known or chain
      # ends before the requested level.
      def lookup(slot, level)
        table = self
        level.times do
          table = table.parent
          return nil unless table
        end
        table.instance_variable_get(:@slot_types)[slot]
      end

      private

      def seed_from_signature(function, signature)
        return unless signature
        lead_num = (function.arg_spec && function.arg_spec[:lead_num]) || 0
        arg_types = signature.arg_types || []
        lead_num.times do |i|
          type = arg_types[i]
          next unless type
          @slot_types[i] = type
        end
      end
    end
  end
end
```

- [ ] **Step 4: Run tests — expect green**

Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
jj split -m "feat: IR::SlotTypeTable — signature-param seeding" \
  optimizer/lib/optimize/ir/slot_type_table.rb \
  optimizer/test/ir/slot_type_table_test.rb
```

---

## Task 2: `SlotTypeTable` — `ClassName.new` constructor-prop

**Files:**
- Modify: `optimizer/lib/optimize/ir/slot_type_table.rb`
- Modify: `optimizer/test/ir/slot_type_table_test.rb`

- [ ] **Step 1: Write failing tests for constructor-prop**

Append to `optimizer/test/ir/slot_type_table_test.rb`:

```ruby
  # Constructor-prop tests use IR::Instruction stubs.
  InstStub = Struct.new(:opcode, :operands, keyword_init: true)

  def test_new_pattern_types_destination_slot
    insts = [
      InstStub.new(opcode: :opt_getconstant_path, operands: ["Point"]),
      InstStub.new(opcode: :putobject_INT2FIX_1_, operands: []),
      InstStub.new(opcode: :putobject_INT2FIX_1_, operands: []),
      InstStub.new(opcode: :opt_send_without_block, operands: [FakeCD.new(:new, 2)]),
      InstStub.new(opcode: :setlocal_WC_0,         operands: [3]), # LINDEX 3 == slot 0 in size-1 table… see table-size conversion below
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

  # Minimal fake CallData: SlotTypeTable only reads .argc and .mid_symbol.
  # Constructor-prop does NOT need a real ObjectTable — build() accepts an
  # optional mid-resolver. See implementation.
  FakeCD = Struct.new(:mid_sym, :argc) do
    def mid_symbol(_object_table) = mid_sym
  end
```

- [ ] **Step 2: Run tests — expect 2 failures (NoMethodError or wrong result)**

- [ ] **Step 3: Implement constructor-prop**

Modify `slot_type_table.rb` to accept an `object_table` arg and run the linear scan after signature seeding:

```ruby
def self.build(function, signature, parent, object_table: nil)
  new(function, signature, parent, object_table: object_table)
end

def initialize(function, signature, parent, object_table: nil)
  @slot_types = {}
  @parent = parent
  seed_from_signature(function, signature)
  scan_for_constructors(function, object_table)
end

# ...

private

# LINDEX ↔ slot-index conversion: LINDEX = VM_ENV_DATA_SIZE(3) + (size - 1 - slot).
# For size S and LINDEX L:  slot = S - 1 - (L - 3).
def self.lindex_to_slot(lindex, size)
  size - 1 - (lindex - 3)
end

def scan_for_constructors(function, object_table)
  insts = function.instructions || []
  size  = (function.misc && function.misc[:local_table_size]) || 0
  i = 0
  while i < insts.size
    inst = insts[i]
    if (inst.opcode == :setlocal_WC_0 || (inst.opcode == :setlocal && (inst.operands[1] || 0) == 0))
      slot = self.class.lindex_to_slot(inst.operands[0], size)
      class_name = detect_class_new_producer(insts, i, object_table)
      if class_name
        @slot_types[slot] = class_name
      else
        @slot_types.delete(slot)
      end
    end
    i += 1
  end
end

# Walk back from the setlocal at idx looking for
# [opt_getconstant_path <Name>, arg_pushes..., opt_send_without_block :new].
def detect_class_new_producer(insts, set_idx, object_table)
  return nil if set_idx.zero?
  send_inst = insts[set_idx - 1]
  return nil unless send_inst.opcode == :opt_send_without_block
  cd = send_inst.operands[0]
  return nil unless cd.respond_to?(:argc) && cd.respond_to?(:mid_symbol)
  return nil unless cd.mid_symbol(object_table) == :new
  # Arg pushes occupy `cd.argc` slots; after them comes the receiver.
  recv_idx = set_idx - 1 - cd.argc - 1
  return nil if recv_idx < 0
  recv = insts[recv_idx]
  return nil unless recv.opcode == :opt_getconstant_path
  # Operand is a frozen Array<Symbol> of the const path;
  # for a plain `Point` it is `[:Point]`. Return the last segment as a string.
  path = recv.operands[0]
  return nil unless path.is_a?(Array) && path.any?
  path.last.to_s
end
```

- [ ] **Step 4: Run tests — all green**

- [ ] **Step 5: Commit**

```bash
jj split -m "feat: SlotTypeTable — ClassName.new constructor-prop" \
  optimizer/lib/optimize/ir/slot_type_table.rb \
  optimizer/test/ir/slot_type_table_test.rb
```

---

## Task 3: `SlotTypeTable` — cross-level lookup

**Files:**
- Modify: `optimizer/test/ir/slot_type_table_test.rb`

Cross-level `lookup(slot, level)` is already implemented in Task 1. This task adds coverage.

- [ ] **Step 1: Write failing test**

Append:

```ruby
  def test_cross_level_lookup_walks_to_parent
    parent_fn  = FnStub.new(arg_spec: { lead_num: 1 }, instructions: [], misc: { local_table_size: 1 })
    parent_sig = SigStub.new(arg_types: ["Point"])
    parent = Optimize::IR::SlotTypeTable.build(parent_fn, parent_sig, nil)

    child_fn = FnStub.new(arg_spec: {}, instructions: [], misc: { local_table_size: 0 })
    child = Optimize::IR::SlotTypeTable.build(child_fn, nil, parent)

    assert_nil child.lookup(0, 0)
    assert_equal "Point", child.lookup(0, 1)
  end

  def test_lookup_above_root_returns_nil
    fn = FnStub.new(arg_spec: {}, instructions: [], misc: { local_table_size: 0 })
    table = Optimize::IR::SlotTypeTable.build(fn, nil, nil)
    assert_nil table.lookup(0, 3)
  end
```

- [ ] **Step 2: Run tests — expect PASS** (implementation from Task 1 already covers this)

- [ ] **Step 3: Commit**

```bash
jj split -m "test: SlotTypeTable — cross-level lookup coverage" \
  optimizer/test/ir/slot_type_table_test.rb
```

---

## Task 4: `TypeEnv` — `signature_for_function` + `new_returns?`

**Files:**
- Modify: `optimizer/lib/optimize/type_env.rb`
- Modify: `optimizer/test/type_env_test.rb`

- [ ] **Step 1: Write failing tests**

Append to `optimizer/test/type_env_test.rb`:

```ruby
  def test_signature_for_function_matches_top_level_def
    FnStub = Struct.new(:name, :type, :path, :first_lineno, :misc, keyword_init: true) unless defined?(FnStub)
    env = Optimize::TypeEnv.from_source(<<~RUBY, "t.rb")
      # @rbs (Integer) -> Integer
      def inc(a); a + 1; end
    RUBY

    fn = FnStub.new(name: "inc", type: :method, path: "t.rb", first_lineno: 2, misc: {})
    sig = env.signature_for_function(fn, class_context: nil)
    refute_nil sig
    assert_equal :inc, sig.method_name
  end

  def test_signature_for_function_matches_instance_method_with_class_context
    env = Optimize::TypeEnv.from_source(<<~RUBY, "t.rb")
      class Point
        # @rbs (Point) -> Float
        def distance_to(o); 0.0; end
      end
    RUBY
    fn = FnStub.new(name: "distance_to", type: :method, path: "t.rb", first_lineno: 3, misc: {})
    sig = env.signature_for_function(fn, class_context: "Point")
    refute_nil sig
    assert_equal "Float", sig.return_type
  end

  def test_new_returns_identity
    env = Optimize::TypeEnv.from_source("", "t.rb")
    assert_equal "Point", env.new_returns?("Point")
  end
```

- [ ] **Step 2: Run tests — expect 3 failures (NoMethodError)**

- [ ] **Step 3: Implement the two queries**

Modify `optimizer/lib/optimize/type_env.rb`:

```ruby
def signature_for_function(function, class_context:)
  return nil unless function.type == :method && function.name
  @by_key[[class_context, function.name.to_sym]]
end

def new_returns?(class_name)
  class_name
end
```

- [ ] **Step 4: Tests green**

- [ ] **Step 5: Commit**

```bash
jj split -m "feat: TypeEnv — signature_for_function + new_returns?" \
  optimizer/lib/optimize/type_env.rb \
  optimizer/test/type_env_test.rb
```

---

## Task 5: `Pipeline` — pre-build slot-type / signature maps, thread as extras

**Files:**
- Modify: `optimizer/lib/optimize/pipeline.rb`
- Modify: `optimizer/test/pipeline_test.rb`

Goal: `Pipeline#run` walks the iseq tree once, builds `slot_type_map: Hash{Function => SlotTypeTable}` (keyed by identity via `compare_by_identity`) and `signature_map: Hash{Function => Signature}`. Both are passed to every `pass.apply` via the existing `**extras` channel.

- [ ] **Step 1: Write failing test**

Append to `optimizer/test/pipeline_test.rb` (a minimal spy pass that asserts extras presence):

```ruby
  class ExtrasSpyPass < Optimize::Pass
    attr_reader :seen_slot_map, :seen_signature_map
    def name = :extras_spy
    def apply(function, type_env:, log:, object_table: nil, slot_type_map: nil, signature_map: nil, **_extras)
      @seen_slot_map = slot_type_map
      @seen_signature_map = signature_map
    end
  end

  def test_pipeline_threads_slot_type_map_and_signature_map
    ir = build_trivial_top_level_ir # existing helper OR inline-build
    spy = ExtrasSpyPass.new
    pipeline = Optimize::Pipeline.new([spy])
    type_env = Optimize::TypeEnv.from_source("", "t.rb")
    pipeline.run(ir, type_env: type_env)
    refute_nil spy.seen_slot_map
    refute_nil spy.seen_signature_map
  end
```

If no `build_trivial_top_level_ir` exists in `pipeline_test.rb` yet, inline a stub `ir = IR::Function.new(type: :top, name: "<main>", ...)` matching how existing tests build their IR.

- [ ] **Step 2: Run — expect FAIL** (extras not populated).

- [ ] **Step 3: Implement**

Modify `optimizer/lib/optimize/pipeline.rb`:

```ruby
require "optimize/ir/slot_type_table"

# ...

def run(ir, type_env:, env_snapshot: nil)
  log = Log.new
  object_table = ir.misc && ir.misc[:object_table]
  callee_map = build_callee_map(ir)
  slot_type_map, signature_map = build_type_maps(ir, type_env, object_table)

  each_function(ir) do |function|
    @passes.each do |pass|
      begin
        pass.apply(
          function,
          type_env: type_env, log: log,
          object_table: object_table, callee_map: callee_map,
          slot_type_map: slot_type_map,
          signature_map: signature_map,
          env_snapshot: env_snapshot,
        )
      rescue => e
        log.skip(pass: pass.name, reason: :pass_raised,
                 file: function.path, line: function.first_lineno || 0)
      end
    end
  end
  log
end

private

def build_type_maps(ir, type_env, object_table)
  slot_type_map = {}.compare_by_identity
  signature_map = {}.compare_by_identity
  walk_with_context(ir, class_context: nil, parent_table: nil) do |fn, class_context, parent_table|
    sig = type_env && type_env.signature_for_function(fn, class_context: class_context)
    signature_map[fn] = sig if sig
    table = IR::SlotTypeTable.build(fn, sig, parent_table, object_table: object_table)
    slot_type_map[fn] = table
    [class_context_for_child(fn, class_context), table]
  end
  [slot_type_map, signature_map]
end

def walk_with_context(fn, class_context:, parent_table:, &block)
  next_ctx, next_parent = yield(fn, class_context, parent_table)
  (fn.children || []).each do |child|
    walk_with_context(child, class_context: next_ctx, parent_table: next_parent, &block)
  end
end

def class_context_for_child(fn, current_ctx)
  return fn.name if fn.type == :class
  current_ctx
end
```

- [ ] **Step 4: Tests green**

- [ ] **Step 5: Commit**

```bash
jj split -m "feat: Pipeline threads slot_type_map + signature_map as pass extras" \
  optimizer/lib/optimize/pipeline.rb \
  optimizer/test/pipeline_test.rb
```

---

## Task 6: `callee_map` — key instance methods by `(receiver_class, method_name)`

**Files:**
- Modify: `optimizer/lib/optimize/pipeline.rb`
- Modify: `optimizer/test/pipeline_test.rb`

- [ ] **Step 1: Write failing test**

Append to `optimizer/test/pipeline_test.rb`:

```ruby
  class CalleeMapSpyPass < Optimize::Pass
    attr_reader :seen_callee_map
    def name = :callee_map_spy
    def apply(function, type_env:, log:, callee_map: {}, **_extras)
      @seen_callee_map = callee_map if function.type == :top
    end
  end

  def test_callee_map_keys_instance_methods_by_class_and_method
    # Synthesize an IR where root is :top, child is :class (Point), grandchild is :method (distance_to).
    method_fn = Optimize::IR::Function.new(
      name: "distance_to", type: :method, path: "t.rb", first_lineno: 3, misc: {},
      instructions: [], children: [],
    )
    class_fn = Optimize::IR::Function.new(
      name: "Point", type: :class, path: "t.rb", first_lineno: 1, misc: {},
      instructions: [], children: [method_fn],
    )
    top_fn = Optimize::IR::Function.new(
      name: "<main>", type: :top, path: "t.rb", first_lineno: 1, misc: {},
      instructions: [], children: [class_fn],
    )
    spy = CalleeMapSpyPass.new
    Optimize::Pipeline.new([spy]).run(top_fn, type_env: nil)

    assert_same method_fn, spy.seen_callee_map[["Point", :distance_to]]
  end
```

- [ ] **Step 2: Run — expect FAIL**

- [ ] **Step 3: Implement — extend `build_callee_map` to track class context**

Replace `build_callee_map` in `pipeline.rb`:

```ruby
def build_callee_map(ir)
  map = {}
  walk_with_class_context(ir, nil) do |fn, class_context|
    next unless fn.type == :method && fn.name
    if class_context
      map[[class_context, fn.name.to_sym]] = fn
    else
      map[fn.name.to_sym] = fn
    end
  end
  map
end

def walk_with_class_context(fn, class_context, &block)
  yield fn, class_context
  next_ctx = fn.type == :class ? fn.name : class_context
  (fn.children || []).each do |child|
    walk_with_class_context(child, next_ctx, &block)
  end
end
```

- [ ] **Step 4: Tests green (new one + existing tests — existing tests key by symbol-only still works since top-level defs have class_context=nil)**

- [ ] **Step 5: Commit**

```bash
jj split -m "feat: Pipeline callee_map keys instance methods by (class, :mid)" \
  optimizer/lib/optimize/pipeline.rb \
  optimizer/test/pipeline_test.rb
```

---

## Task 7: `InliningPass` — OPT_SEND-eligible `disqualify` variant (permits plain sends)

**Files:**
- Modify: `optimizer/lib/optimize/passes/inlining_pass.rb`
- Modify: `optimizer/test/passes/inlining_pass_test.rb`

- [ ] **Step 1: Write failing tests**

Two tests: (a) a body with a plain `opt_send_without_block` is NOT disqualified by the new variant; (b) bodies with getivar / setivar / branches / catch entries / block args ARE disqualified.

Append to `optimizer/test/passes/inlining_pass_test.rb`:

```ruby
  def test_opt_send_eligibility_allows_nested_plain_sends
    callee = build_callee(insts: [
      IR::Instruction.new(opcode: :putself, operands: [], line: 1),
      IR::Instruction.new(opcode: :opt_send_without_block, operands: [fake_cd(:x, 0)], line: 1),
      IR::Instruction.new(opcode: :leave, operands: [], line: 1),
    ])
    pass = Optimize::Passes::InliningPass.new
    assert_nil pass.send(:disqualify_callee_for_opt_send, callee)
  end

  def test_opt_send_eligibility_rejects_getinstancevariable
    callee = build_callee(insts: [
      IR::Instruction.new(opcode: :getinstancevariable, operands: [0, 0], line: 1),
      IR::Instruction.new(opcode: :leave, operands: [], line: 1),
    ])
    pass = Optimize::Passes::InliningPass.new
    assert_equal :callee_uses_ivar, pass.send(:disqualify_callee_for_opt_send, callee)
  end

  def test_opt_send_eligibility_rejects_branches
    callee = build_callee(insts: [
      IR::Instruction.new(opcode: :branchunless, operands: [2], line: 1),
      IR::Instruction.new(opcode: :leave, operands: [], line: 1),
    ])
    pass = Optimize::Passes::InliningPass.new
    assert_equal :callee_has_branches, pass.send(:disqualify_callee_for_opt_send, callee)
  end
```

(`build_callee` / `fake_cd` helpers: see existing `inlining_pass_test.rb` for patterns. If not present, add the small helpers at the top of the test class.)

- [ ] **Step 2: Run — expect FAIL with NoMethodError**

- [ ] **Step 3: Implement `disqualify_callee_for_opt_send`**

Add to `InliningPass` (public-enough for tests — private + `.send(:...)` is fine):

```ruby
# Like #disqualify_callee but permits nested plain sends.
# Forbidden: branches, catch tables, block-setup sends, ivar ops,
# mid-body leaves, multiple locals.
def disqualify_callee_for_opt_send(callee)
  return :callee_has_catch if callee.catch_entries && !callee.catch_entries.empty?
  insts = callee.instructions || []
  return :callee_empty if insts.empty?
  return :callee_over_budget if insts.size > INLINE_BUDGET
  return :callee_no_trailing_leave unless insts.last.opcode == :leave

  body = insts[0..-2]
  body.each do |inst|
    return :callee_has_branches if CONTROL_FLOW_OPCODES.include?(inst.opcode)
    return :callee_has_leave_midway if inst.opcode == :leave
    return :callee_has_throw if inst.opcode == :throw
    return :callee_uses_ivar if inst.opcode == :getinstancevariable
    return :callee_uses_ivar if inst.opcode == :setinstancevariable
    case inst.opcode
    when :invokeblock, :invokesuper, :invokesuperforward, :getblockparam
      return :callee_uses_block
    when :opt_send_without_block, :send
      cd = inst.operands[0]
      return :callee_send_has_block if cd.respond_to?(:blockarg?) && cd.blockarg?
      return :callee_send_has_block if cd.respond_to?(:flag) && (cd.flag & IR::CallData::FLAG_BLOCKISEQ) != 0
    end
  end
  nil
end
```

Also: add `:callee_uses_ivar` / `:callee_uses_block` / `:callee_send_has_block` as permitted skip reasons — the log allows any symbol, no allowlist needed.

- [ ] **Step 4: Tests green**

- [ ] **Step 5: Commit**

```bash
jj split -m "feat: InliningPass — OPT_SEND-eligible callee classifier (permits plain sends)" \
  optimizer/lib/optimize/passes/inlining_pass.rb \
  optimizer/test/passes/inlining_pass_test.rb
```

---

## Task 8: `InliningPass` — OPT_SEND recognizer, constant-body path

**Files:**
- Modify: `optimizer/lib/optimize/passes/inlining_pass.rb`
- Modify: `optimizer/test/passes/inlining_pass_test.rb`

**Scope:** argc=1 OPT_SEND, receiver producer is `getlocal*` at level 0 pointing at a typed slot; callee body has no `putself` (zero self-ops), so no self-stash is grown. Arg is stashed; receiver is stashed but never referenced. This is the minimum viable splice, upgraded in Task 9 with self-rewrite.

- [ ] **Step 1: Write failing test**

Append to `inlining_pass_test.rb`:

```ruby
  def test_opt_send_with_typed_receiver_splices_constant_body_callee
    # Caller: def distance(p, q); p.distance_to(q); end   # @rbs (Point, Point) -> Integer
    # Callee: def distance_to(other); 42; end             # constant body, no self
    # Expected after inline: the OPT_SEND window collapses into arg-stash + body.
    caller_insts = [
      IR::Instruction.new(opcode: :getlocal_WC_0, operands: [4], line: 1), # p (slot 0, size 2 → LINDEX 4)
      IR::Instruction.new(opcode: :getlocal_WC_0, operands: [3], line: 1), # q (slot 1, LINDEX 3)
      IR::Instruction.new(opcode: :opt_send_without_block,
                          operands: [fake_cd(:distance_to, 1, fcall: false, simple: true)], line: 1),
      IR::Instruction.new(opcode: :leave, operands: [], line: 1),
    ]
    caller = build_function(
      name: "distance", type: :method, lead_num: 2,
      local_table_size: 2, instructions: caller_insts,
    )
    callee = build_callee(
      lead_num: 1, local_table_size: 1,
      insts: [
        IR::Instruction.new(opcode: :putobject, operands: [42], line: 1),
        IR::Instruction.new(opcode: :leave, operands: [], line: 1),
      ],
    )

    slot_table = Optimize::IR::SlotTypeTable.build(
      caller,
      signature_stub(arg_types: ["Point", "Point"]),
      nil,
    )
    slot_type_map = {}.compare_by_identity
    slot_type_map[caller] = slot_table

    object_table = make_object_table(%i[distance_to other])
    pass = Optimize::Passes::InliningPass.new
    pass.apply(
      caller,
      type_env: stub_type_env(for_class: "Point", mid: :distance_to),
      log: Optimize::Log.new,
      object_table: object_table,
      callee_map: { ["Point", :distance_to] => callee },
      slot_type_map: slot_type_map,
    )

    ops = caller.instructions.map(&:opcode)
    refute_includes ops, :opt_send_without_block, "call site should be spliced"
    assert_includes ops, :putobject, "body should appear in caller"
    # Arg-stash slot added → local_table_size bumped by 1 (no self-stash since no putself).
    assert_equal 3, caller.misc[:local_table_size]
  end
```

(The test requires helpers: `build_function`, `build_callee`, `fake_cd` with kwargs, `signature_stub`, `stub_type_env`, `make_object_table`. See existing `inlining_pass_test.rb` for patterns; add missing ones to its helper section.)

- [ ] **Step 2: Run — expect FAIL (opt_send not recognized yet)**

- [ ] **Step 3: Implement the recognizer**

In `InliningPass#apply`, extend the inner loop so OPT_SEND with non-fcall calldata can dispatch to a new `try_inline_opt_send` method:

```ruby
if b.opcode == :opt_send_without_block
  cd = b.operands[0]
  if cd.is_a?(IR::CallData) && cd.fcall?
    # existing FCALL path
    if try_inline(function, i, callee_map, object_table, log)
      changed = true
      insts = function.instructions
      next
    end
  else
    slot_type_map = _extras_for_slot_type_map
    if try_inline_opt_send(function, i, callee_map, object_table, log, slot_type_map)
      changed = true
      insts = function.instructions
      next
    end
  end
end
```

The cleanest way: change `apply`'s signature to capture `slot_type_map:`:

```ruby
def apply(function, type_env:, log:, object_table: nil, callee_map: {}, slot_type_map: {}, **_extras)
  _ = type_env
  return unless object_table
  slot_table = slot_type_map[function]
  # ... loop
end
```

Then the OPT_SEND path:

```ruby
def try_inline_opt_send(function, send_idx, callee_map, object_table, log, slot_table)
  insts = function.instructions
  send_inst = insts[send_idx]
  cd = send_inst.operands[0]
  line = send_inst.line || function.first_lineno
  return false unless cd.is_a?(IR::CallData)
  return false unless cd.argc == 1
  return false unless cd.args_simple? && cd.kwlen.zero? && !cd.blockarg? && !cd.has_splat?
  return false if send_idx < 2

  recv_inst = insts[send_idx - 2]
  arg_inst  = insts[send_idx - 1]

  slot, level = decode_getlocal(recv_inst, function)
  return false unless slot

  type = slot_table && slot_table.lookup(slot, level)
  return false unless type

  mid = cd.mid_symbol(object_table)
  callee = callee_map[[type, mid]]
  unless callee
    log.skip(pass: :inlining, reason: :callee_unresolved,
             file: function.path, line: line)
    return false
  end

  reason = disqualify_callee_for_opt_send(callee)
  if reason
    log.skip(pass: :inlining, reason: reason, file: function.path, line: line)
    return false
  end

  # Body shape check for this task: ≤1 body instruction before leave AND no putself
  # (self-rewrite arrives in Task 9). Defer bodies with putself.
  body = callee.instructions[0..-2]
  if body.any? { |inst| inst.opcode == :putself }
    log.skip(pass: :inlining, reason: :opt_send_needs_self_rewrite,
             file: function.path, line: line)
    return false
  end

  # Grow local table by 1 for arg-stash.
  callee_arg_obj_idx = Codec::LocalTable.decode(
    callee.misc[:local_table_raw] || "".b,
    callee.misc[:local_table_size] || 0,
  ).first
  if callee_arg_obj_idx.nil?
    log.skip(pass: :inlining, reason: :callee_local_table_unreadable,
             file: function.path, line: line)
    return false
  end
  Codec::LocalTable.grow!(function, callee_arg_obj_idx)
  # Shift every existing level-0 LINDEX by +1.
  shift_level0_lindex_by_1(function)

  # Build replacement. The receiver value on stack has to be consumed
  # (spec: stashed for possible later self-rewrite). For Task 8 we
  # simply drop it via `pop`. Task 9 replaces `pop` with
  # `setlocal <self_stash>` and grows a second slot.
  insts    = function.instructions
  arg_push = insts[send_idx - 1]
  recv_drop = IR::Instruction.new(opcode: :pop, operands: [], line: line)
  setlocal_arg = IR::Instruction.new(
    opcode: :setlocal_WC_0, operands: [NEW_SLOT_LINDEX],
    line: arg_push.line || line,
  )
  replacement = [recv_drop, arg_push, setlocal_arg, *body]
  function.splice_instructions!((send_idx - 2)..send_idx, replacement)

  log.skip(pass: :inlining, reason: :inlined, file: function.path, line: line)
  true
end

def decode_getlocal(inst, function)
  size = (function.misc && function.misc[:local_table_size]) || 0
  case inst.opcode
  when :getlocal_WC_0
    [IR::SlotTypeTable.lindex_to_slot(inst.operands[0], size), 0]
  when :getlocal_WC_1
    [IR::SlotTypeTable.lindex_to_slot(inst.operands[0], size), 1] # size here is wrong — see Task 11
  when :getlocal
    # operand[0] = lindex, operand[1] = level
    level = inst.operands[1]
    # For level>0, the LINDEX is in the parent's size, not ours. Skip
    # precise decoding in Task 8; Task 11 plumbs the parent's size.
    return [nil, nil] if level > 0
    [IR::SlotTypeTable.lindex_to_slot(inst.operands[0], size), 0]
  else
    [nil, nil]
  end
end

def shift_level0_lindex_by_1(function)
  function.instructions.each do |inst|
    case inst.opcode
    when :getlocal_WC_0, :setlocal_WC_0
      inst.operands[0] = inst.operands[0] + 1
    when :getlocal, :setlocal
      if inst.operands[1] == 0
        inst.operands[0] = inst.operands[0] + 1
      end
    end
  end
end
```

Do **not** hook cross-level lookup correctness yet; Task 11 replaces `decode_getlocal`'s incorrect level>0 handling.

- [ ] **Step 4: Tests green**

- [ ] **Step 5: Commit**

```bash
jj split -m "feat: InliningPass — OPT_SEND recognizer, constant-body path (no self-rewrite)" \
  optimizer/lib/optimize/passes/inlining_pass.rb \
  optimizer/test/passes/inlining_pass_test.rb
```

---

## Task 9: `InliningPass` — self-stash + `putself` rewrite

**Files:**
- Modify: `optimizer/lib/optimize/passes/inlining_pass.rb`
- Modify: `optimizer/test/passes/inlining_pass_test.rb`

**Scope:** callee bodies may now contain one or more `putself` ops (rewritten to `getlocal <self_stash> level=0`). Receiver stash becomes a real local. Total growth: +2 slots.

- [ ] **Step 1: Write failing test**

Append:

```ruby
  def test_opt_send_with_putself_body_rewrites_to_self_stash
    # Callee body: `(other)` via `return self_ignored_here`? Use a body that pushes
    # the receiver's instance by calling a 0-arg send on self, matching the demo shape.
    #   def distance_to(other); x - other.x; end
    # body: putself; send :x, 0; getlocal other LINDEX 3; send :x, 0; opt_minus; leave
    callee_body = [
      IR::Instruction.new(opcode: :putself, operands: [], line: 1),
      IR::Instruction.new(opcode: :opt_send_without_block,
                          operands: [fake_cd(:x, 0, fcall: false, simple: true)], line: 1),
      IR::Instruction.new(opcode: :getlocal_WC_0, operands: [3], line: 1),
      IR::Instruction.new(opcode: :opt_send_without_block,
                          operands: [fake_cd(:x, 0, fcall: false, simple: true)], line: 1),
      IR::Instruction.new(opcode: :opt_minus,
                          operands: [fake_cd(:-, 1, fcall: false, simple: true)], line: 1),
      IR::Instruction.new(opcode: :leave, operands: [], line: 1),
    ]
    callee = build_callee(lead_num: 1, local_table_size: 1, insts: callee_body)
    # ... (caller setup as in Task 8) ...
    # After inline:
    #  - local_table_size grew by 2 (arg-stash + self-stash)
    #  - Every putself in spliced body replaced with getlocal_WC_0 at self-stash LINDEX
    assert_equal 4, caller.misc[:local_table_size]
    spliced = caller.instructions
    refute(spliced.any? { |i| i.opcode == :putself },
           "all putself inside spliced body should be rewritten")
    # self-stash LINDEX = NEW_SLOT_LINDEX (3); arg-stash = 4 after self-stash growth.
  end
```

- [ ] **Step 2: Run — expect FAIL**

- [ ] **Step 3: Implement**

Modify `try_inline_opt_send`:

```ruby
# Body shape: find all putself occurrences.
body = callee.instructions[0..-2]
body_uses_self = body.any? { |inst| inst.opcode == :putself }

# Grow local table: +1 for arg-stash, +1 more if body uses self.
callee_arg_obj_idx = ...
Codec::LocalTable.grow!(function, callee_arg_obj_idx)
shift_level0_lindex_by_1(function)

if body_uses_self
  self_stash_obj_idx = callee_arg_obj_idx   # Reuse any Symbol; name doesn't matter at runtime.
  Codec::LocalTable.grow!(function, self_stash_obj_idx)
  shift_level0_lindex_by_1(function)
  # After two grows, the LATEST slot has LINDEX 3 (self-stash), and
  # the previous one has LINDEX 4 (arg-stash).
  self_stash_lindex = NEW_SLOT_LINDEX
  arg_stash_lindex  = NEW_SLOT_LINDEX + 1
else
  self_stash_lindex = nil
  arg_stash_lindex  = NEW_SLOT_LINDEX
end

# Rewrite body: putself → getlocal_WC_0 <self_stash_lindex>.
rewritten_body = body.map do |inst|
  if inst.opcode == :putself && self_stash_lindex
    IR::Instruction.new(
      opcode: :getlocal_WC_0,
      operands: [self_stash_lindex],
      line: inst.line,
    )
  else
    inst
  end
end

# Build replacement:
#   [receiver producer] (already in place)
#   [arg producer]
#   setlocal_WC_0 <arg_stash_lindex>   # consume arg
#   setlocal_WC_0 <self_stash_lindex>  # consume receiver (if needed, else pop)
#   <rewritten body>
insts    = function.instructions
arg_push = insts[send_idx - 1]
consume_arg = IR::Instruction.new(opcode: :setlocal_WC_0,
                                  operands: [arg_stash_lindex], line: line)
consume_recv = if self_stash_lindex
  IR::Instruction.new(opcode: :setlocal_WC_0,
                      operands: [self_stash_lindex], line: line)
else
  IR::Instruction.new(opcode: :pop, operands: [], line: line)
end

# Rewrite any `getlocal_WC_0 3` inside the body (the callee's arg at
# LINDEX 3 in its size-1 frame) to point at the arg-stash slot.
# In the callee's frame, the arg's LINDEX is always 3. In the caller's
# frame post-splice, the arg-stash has LINDEX `arg_stash_lindex`.
rewritten_body = rewritten_body.map do |inst|
  case inst.opcode
  when :getlocal_WC_0
    if inst.operands[0] == 3
      IR::Instruction.new(opcode: :getlocal_WC_0,
                          operands: [arg_stash_lindex], line: inst.line)
    else
      inst
    end
  when :getlocal
    if inst.operands[1] == 0 && inst.operands[0] == 3
      IR::Instruction.new(opcode: :getlocal,
                          operands: [arg_stash_lindex, 0], line: inst.line)
    else
      inst
    end
  else
    inst
  end
end

replacement = [arg_push, consume_arg, consume_recv, *rewritten_body]
# NOTE: the arg_push from the caller was originally at send_idx - 1 (producing
# the arg value). We keep it; its own LINDEX if it's a getlocal_WC_0 was
# already shifted by the two grows above.
function.splice_instructions!((send_idx - 1)..send_idx, replacement)
```

Note the splice range changes: the original recv producer at `send_idx - 2` stays in place to put the receiver on the stack; we replace from `send_idx - 1` (arg producer) through `send_idx` (the OPT_SEND). The replacement starts with `arg_push` (pushing arg on top of receiver), then `setlocal arg` (consumes arg), then `setlocal self` / `pop` (consumes receiver), then the body.

- [ ] **Step 4: Tests green**

- [ ] **Step 5: Commit**

```bash
jj split -m "feat: InliningPass — self-stash + putself rewrite for OPT_SEND" \
  optimizer/lib/optimize/passes/inlining_pass.rb \
  optimizer/test/passes/inlining_pass_test.rb
```

---

## Task 10: `InliningPass` — guard tests for all rejection reasons

**Files:**
- Modify: `optimizer/test/passes/inlining_pass_test.rb`

Coverage pass for skip-logging under each guard. One test per reason:

- [ ] **Step 1: Write one test per guard**

```ruby
  def test_skips_when_receiver_slot_untyped
    # caller has no @rbs signature → slot_table returns nil for slot 0
    # → log contains a skip, original OPT_SEND is untouched.
  end

  def test_skips_when_callee_not_in_map
  end

  def test_skips_when_callee_has_branches
  end

  def test_skips_when_callee_has_catch_entry
  end

  def test_skips_when_callee_has_block_arg_send
  end

  def test_skips_when_callee_uses_ivar
  end
```

For each, assert the `opt_send_without_block` survives and that `Log#entries` contains the expected reason symbol.

- [ ] **Step 2: Run — all should pass against the current implementation**

(Task 7 already rejects these cases; Task 8/9 plumbed `callee_unresolved` / `slot-untyped short-circuit`.)

- [ ] **Step 3: Any that fail → fix the guard; then green**

- [ ] **Step 4: Commit**

```bash
jj split -m "test: InliningPass OPT_SEND — guard coverage for all skip reasons" \
  optimizer/test/passes/inlining_pass_test.rb
```

---

## Task 11: `InliningPass` — cross-level receiver (block iseq reads parent slot)

**Files:**
- Modify: `optimizer/lib/optimize/passes/inlining_pass.rb`
- Modify: `optimizer/test/passes/inlining_pass_test.rb`

**Scope:** the benchmark shape is `1_000_000.times { p.distance_to(q) }` — the call site lives in a block iseq, and `p` / `q` live in the parent's local table. The block uses `getlocal_WC_1` to read them. `decode_getlocal` must read the parent's `local_table_size` to compute the slot correctly, and SlotTypeTable's cross-level lookup supplies the type from the parent table.

- [ ] **Step 1: Write failing test**

Append:

```ruby
  def test_opt_send_in_block_iseq_reads_parent_slot_type
    # Parent fn (type: :top):
    #   # @rbs (Point) -> Integer   # but this is :top, so seed via locals?
    # Actually use a :method parent:
    #   # @rbs (Point, Point) -> Integer
    #   def driver(p, q)
    #     1.times { p.distance_to(q) }   # block body has the OPT_SEND
    #   end
    # Parent's local_table_size = 2 (p, q). Block's getlocal_WC_1 with
    # LINDEX 4 → slot 0 in parent == p.
    # ...
    # Expectations:
    #   - block iseq's OPT_SEND is spliced.
    #   - parent's local_table_size grows (because the splice happens in the
    #     block, but the stash slots are added to the BLOCK's local table).
    #   - Actually: stash slots are added to the iseq WHERE THE SPLICE HAPPENS
    #     (the block), so block's local_table_size grows by 1 or 2.
  end
```

- [ ] **Step 2: Run — expect FAIL**

- [ ] **Step 3: Implement**

Fix `decode_getlocal` to walk up parent iseq references for levels > 0.

The function IR does not currently carry a parent pointer (only `children`). Add one during the pipeline's type-map build (a `Hash{fn => parent_fn}`) and pass it via extras — or store the parent-size on the SlotTypeTable itself.

Simplest: give `SlotTypeTable` a `local_table_size` attribute captured at build time; `lookup` returns a wrapper providing both the type and the size the caller needs. Or add a helper `SlotTypeTable#parent_table_size` that walks up.

Concrete:

```ruby
# In SlotTypeTable#initialize
@local_table_size = (function.misc && function.misc[:local_table_size]) || 0

def table_at_level(level)
  table = self
  level.times do
    table = table.parent
    return nil unless table
  end
  table
end

def local_table_size_at_level(level)
  t = table_at_level(level)
  t && t.instance_variable_get(:@local_table_size)
end
```

Update `decode_getlocal` in InliningPass:

```ruby
def decode_getlocal(inst, slot_table)
  case inst.opcode
  when :getlocal_WC_0
    size = slot_table.local_table_size_at_level(0)
    [IR::SlotTypeTable.lindex_to_slot(inst.operands[0], size), 0]
  when :getlocal_WC_1
    size = slot_table.local_table_size_at_level(1)
    return [nil, nil] unless size
    [IR::SlotTypeTable.lindex_to_slot(inst.operands[0], size), 1]
  when :getlocal
    level = inst.operands[1]
    size = slot_table.local_table_size_at_level(level)
    return [nil, nil] unless size
    [IR::SlotTypeTable.lindex_to_slot(inst.operands[0], size), level]
  else
    [nil, nil]
  end
end
```

Pass `slot_table` into `decode_getlocal` instead of `function`.

- [ ] **Step 4: Tests green**

- [ ] **Step 5: Commit**

```bash
jj split -m "feat: InliningPass — cross-iseq-level receiver lookup for block call sites" \
  optimizer/lib/optimize/passes/inlining_pass.rb \
  optimizer/lib/optimize/ir/slot_type_table.rb \
  optimizer/test/passes/inlining_pass_test.rb
```

---

## Task 12: End-to-end fixture — `optimizer/examples/point_distance.rb`

**Files:**
- Create: `optimizer/examples/point_distance.rb`
- Modify: `optimizer/test/pipeline_test.rb`

- [ ] **Step 1: Create the fixture**

`optimizer/examples/point_distance.rb`:

```ruby
# frozen_string_literal: true

class Point
  attr_reader :x, :y

  # @rbs (Integer, Integer) -> void
  def initialize(x, y)
    @x = x
    @y = y
  end

  # @rbs (Point) -> Integer
  def distance_to(other)
    (x - other.x) + (y - other.y)
  end
end

p = Point.new(1, 2)
q = Point.new(4, 6)

1_000_000.times { p.distance_to(q) }
```

- [ ] **Step 2: Pipeline round-trip test**

Append to `optimizer/test/pipeline_test.rb`:

```ruby
  def test_point_distance_fixture_roundtrips_through_pipeline
    source = File.read(File.expand_path("../examples/point_distance.rb", __dir__))
    iseq = RubyVM::InstructionSequence.compile(source, "point_distance.rb", "point_distance.rb")
    binary = iseq.to_binary
    ir = Optimize::Codec.decode(binary)
    type_env = Optimize::TypeEnv.from_source(source, "point_distance.rb")
    log = Optimize::Pipeline.default.run(ir, type_env: type_env)
    modified = Optimize::Codec.encode(ir)
    reloaded = RubyVM::InstructionSequence.load_from_binary(modified)
    assert_kind_of RubyVM::InstructionSequence, reloaded

    # At least one inlined OPT_SEND is expected somewhere in the log.
    inlined_entries = log.entries.select { |e| e[:reason] == :inlined && e[:pass] == :inlining }
    refute_empty inlined_entries, "expected at least one inlined OPT_SEND; log: #{log.entries.inspect}"
  end
```

- [ ] **Step 3: Run via MCP `run_optimizer_tests` — expect green**

If the round-trip reloads but `inlined_entries` is empty: missing piece in Tasks 1–11; diagnose via log `skip` entries before claiming this task is done.

- [ ] **Step 4: Smoke-run via MCP `run_ruby`**

Load the fixture through the harness (with the MCP tool pointed at the pipeline) to confirm it reloads from binary without raising at VM load time.

- [ ] **Step 5: Commit**

```bash
jj split -m "feat: point_distance fixture + end-to-end pipeline round-trip" \
  optimizer/examples/point_distance.rb \
  optimizer/test/pipeline_test.rb
```

---

## Task 13: `docs/TODO.md` + talk-structure update

**Files:**
- Modify: `docs/TODO.md`
- Modify: `docs/superpowers/specs/2026-04-19-talk-structure-design.md` (optional — only if you find a claim about "RBS not yet done" that's now false)

- [ ] **Step 1: Update TODO**

Strike roadmap item #1 (RBS type env). Update the "Three-pass plan: status" Inlining row with v3's new capability: "v3: zero-arg and one-arg FCALL inline + typed-receiver OPT_SEND inline for single-arg instance methods with RBS-seeded param types and ClassName.new constructor-prop". Remaining column: "multi-arg OPT_SEND; getinstancevariable handling; callee-internal locals; kwargs; blocks; full CFG-level splicing."

Also add a "Shipped 2026-04-22" note pointing at the spec + plan filenames.

- [ ] **Step 2: Commit**

```bash
jj split -m "docs: TODO — strike RBS type env v1 (shipped)" \
  docs/TODO.md
```

---

## Self-review checklist (run before declaring the plan complete)

- Every spec requirement has a task? **Yes**: SlotTypeTable (T1–T3), TypeEnv upgrades (T4), callee_map extension (T6), Pipeline wiring (T5), InliningPass recognizer + splice + rewrite (T7–T9), guards (T10), cross-level (T11), fixture (T12), doc update (T13).
- Every task has concrete code / commands, no "TBD"? **Yes.**
- Type / method names consistent across tasks? `slot_type_map`, `signature_map`, `SlotTypeTable#lookup(slot, level)`, `SlotTypeTable.lindex_to_slot`, `disqualify_callee_for_opt_send`, `try_inline_opt_send`, `decode_getlocal`, `shift_level0_lindex_by_1` — used consistently.
- Potential issue flagged in T8: `decode_getlocal` for level>0 returns `[nil, nil]` pending T11. T8's test uses a single-level case. Fine.
- Potential issue flagged in T9: the splice range shifts from `(send_idx - 2)..send_idx` (T8) to `(send_idx - 1)..send_idx` (T9). The receiver producer stays in place; T9's test must verify this explicitly. Callable out.

---

## Execution handoff

**Plan complete and saved to `docs/superpowers/plans/2026-04-22-rbs-type-env-v1.md`. Two execution options:**

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration. Each subagent's brief is self-contained (plus the task heading + this plan as its context pointer).

**2. Inline Execution** — I execute tasks in this session using the executing-plans skill, with checkpoints for your review between tasks.

**Which approach?**
