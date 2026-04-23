# ConstFoldEnvPass Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship Tier 4 const-fold — fold `ENV["LIT"]` to its snapshot value, with a whole-IR-tree taint gate that disables folding if any ENV write is observed. Extend `ConstFoldPass` with String-on-String `==`/`!=` so `ENV["FLAG"] == "true"` collapses to `true` in one pipeline pass.

**Architecture:**
- New `Optimize::Passes::ConstFoldEnvPass` in `optimizer/lib/optimize/passes/const_fold_env_pass.rb`.
- Additive kwarg `env_snapshot:` threaded through `Pipeline#run` and `pass.apply`.
- Two scan phases inside the pass: (1) whole-tree taint scan over every function's instructions; (2) if untainted, fold the 3-tuple `opt_getconstant_path ENV; putchilledstring KEY; opt_aref` via `function.splice_instructions!`.
- `ConstFoldPass` gets a small extension: `opt_eq`/`opt_neq` with two String operands fold to `putobject true`/`putobject false`.
- Pipeline order: `InliningPass → ArithReassocPass → ConstFoldEnvPass → ConstFoldPass → IdentityElimPass`.

**Tech Stack:**
- Ruby 4.0.2, Minitest.
- Existing helpers: `Optimize::Passes::LiteralValue`, `Optimize::IR::Function#splice_instructions!`, `Optimize::Codec::ObjectTable#index_for`.
- All Ruby/test execution via the `ruby-bytecode` MCP tools, NOT host shell.
- Source control: `jj` only. Finalize commits with `jj commit -m`, never `jj describe -m`.

**Spec reference:** `docs/superpowers/specs/2026-04-23-pass-const-fold-env-design.md`.

**Opcode shape confirmed by disasm** (Ruby 4.0.2):

```
# ENV["FOO"]
opt_getconstant_path <ic:0 ENV>
putchilledstring     "FOO"
opt_aref             <calldata mid:[], argc:1>
```

Three-tuple. No `opt_aref_with` in this Ruby. Spec mentions the 2-tuple shape as defensive; **do not implement it** — it does not occur. If a future Ruby emits it, add a single clause to the fold recognizer.

```
# ENV.fetch("FOO")
opt_getconstant_path <ic:0 ENV>
putchilledstring     "FOO"
opt_send_without_block <calldata mid:fetch, argc:1>
```

`fetch` uses `opt_send_without_block` — this is the "tainted use" shape the taint scanner must catch.

```
# ENV["FOO"] = "bar"
putnil
opt_getconstant_path <ic:0 ENV>
putchilledstring "FOO"
putchilledstring "bar"
setn 3
opt_aset <calldata mid:[]=, argc:2>
pop
```

`opt_aset` is the write shape. Taint scanner catches.

---

## File Structure

| File | Role | Create / Modify |
|---|---|---|
| `optimizer/lib/optimize/passes/const_fold_env_pass.rb` | New `ConstFoldEnvPass` — taint scan + 3-tuple fold. | Create |
| `optimizer/test/passes/const_fold_env_pass_test.rb` | Unit tests for the new pass. | Create |
| `optimizer/lib/optimize/passes/const_fold_pass.rb` | Add String-on-String `==`/`!=` fold path. | Modify |
| `optimizer/test/passes/const_fold_pass_test.rb` | Tests for new string-eq path. | Modify |
| `optimizer/lib/optimize/pipeline.rb` | Add `env_snapshot:` kwarg; thread to `pass.apply`; register `ConstFoldEnvPass` before `ConstFoldPass` in `.default`. | Modify |
| `optimizer/test/pipeline_test.rb` | End-to-end test — `ENV["FLAG"] == "true"` collapses to `true`. | Modify |
| `docs/TODO.md` | Mark Tier 4 shipped; move items to "Refinements"/v2 as applicable. | Modify |

---

## Task 1: Thread `env_snapshot:` through `Pipeline#run`

Purely additive plumbing — no behavior change yet. Every other task depends on this.

**Files:**
- Modify: `optimizer/lib/optimize/pipeline.rb`
- Test: `optimizer/test/pipeline_test.rb`

- [ ] **Step 1.1: Write a failing test that `env_snapshot:` reaches `apply`.**

Add to `optimizer/test/pipeline_test.rb`:

```ruby
def test_pipeline_threads_env_snapshot_to_passes
  captured = []
  recorder = Class.new(Optimize::Pass) do
    define_method(:apply) do |fn, type_env:, log:, object_table: nil, **extras|
      captured << extras[:env_snapshot]
    end
    def name = :recorder
  end

  ir = Optimize::Codec.decode(
    RubyVM::InstructionSequence.compile("def f; 1; end").to_binary
  )
  snap = { "FOO" => "bar" }.freeze
  Optimize::Pipeline.new([recorder.new]).run(ir, type_env: nil, env_snapshot: snap)

  refute_empty captured
  assert_equal snap, captured.first
end
```

- [ ] **Step 1.2: Run the test, confirm it fails with `unknown keyword: :env_snapshot`.**

Use the ruby-bytecode MCP `run_optimizer_tests` tool with a narrow test filter (the `running-ruby-experiments` skill routes this to Docker). Command for that tool: run the `const_fold_env` and `pipeline` test files.

Expected: ArgumentError about unknown keyword on the `.run` call.

- [ ] **Step 1.3: Modify `Pipeline#run` to accept `env_snapshot:` and thread it.**

Edit `optimizer/lib/optimize/pipeline.rb:25-48`:

```ruby
def run(ir, type_env:, env_snapshot: nil)
  log = Log.new
  object_table = ir.misc && ir.misc[:object_table]
  callee_map = build_callee_map(ir)
  each_function(ir) do |function|
    @passes.each do |pass|
      begin
        pass.apply(
          function,
          type_env: type_env, log: log,
          object_table: object_table, callee_map: callee_map,
          env_snapshot: env_snapshot,
        )
      rescue => e
        log.skip(
          pass: pass.name,
          reason: :pass_raised,
          file: function.path,
          line: function.first_lineno || 0,
        )
      end
    end
  end
  log
end
```

- [ ] **Step 1.4: Re-run the test suite, confirm the new test and all existing pipeline tests pass.**

Expected: all green. Passes that declare `**_extras` (every shipped pass does — verified in `pass.rb:14`) silently absorb the new kwarg.

- [ ] **Step 1.5: Commit.**

```bash
jj commit -m "pipeline: thread env_snapshot: kwarg through run → apply"
```

---

## Task 2: Extend `ConstFoldPass` with String-on-String `==`/`!=`

Small additive change to an existing pass. Integer paths unchanged; only `opt_eq` / `opt_neq` get a String-String branch.

**Files:**
- Modify: `optimizer/lib/optimize/passes/const_fold_pass.rb`
- Test: `optimizer/test/passes/const_fold_pass_test.rb`

- [ ] **Step 2.1: Write the failing test for String==String folds.**

Add to `optimizer/test/passes/const_fold_pass_test.rb`:

```ruby
def test_folds_string_equality_triple_to_true
  src = 'def f; "abc" == "abc"; end'
  ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
  ot = ir.misc[:object_table]
  f = find_iseq(ir, "f")
  Optimize::Passes::ConstFoldPass.new.apply(f, type_env: nil, log: Optimize::Log.new, object_table: ot)
  assert(f.instructions.any? { |i| Optimize::Passes::LiteralValue.read(i, object_table: ot) == true })
  loaded = RubyVM::InstructionSequence.load_from_binary(Optimize::Codec.encode(ir))
  assert_equal true, loaded.eval
end

def test_folds_string_equality_triple_to_false
  src = 'def f; "abc" == "def"; end'
  ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
  ot = ir.misc[:object_table]
  f = find_iseq(ir, "f")
  Optimize::Passes::ConstFoldPass.new.apply(f, type_env: nil, log: Optimize::Log.new, object_table: ot)
  assert(f.instructions.any? { |i| Optimize::Passes::LiteralValue.read(i, object_table: ot) == false })
end

def test_folds_string_inequality_triple
  src = 'def f; "a" != "b"; end'
  ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
  ot = ir.misc[:object_table]
  f = find_iseq(ir, "f")
  Optimize::Passes::ConstFoldPass.new.apply(f, type_env: nil, log: Optimize::Log.new, object_table: ot)
  assert(f.instructions.any? { |i| Optimize::Passes::LiteralValue.read(i, object_table: ot) == true })
  loaded = RubyVM::InstructionSequence.load_from_binary(Optimize::Codec.encode(ir))
  assert_equal true, loaded.eval
end

def test_leaves_mixed_type_equality_alone
  # "a" == 5 — both are literals but types differ; skip fold. Pre-existing
  # non_integer_literal log should fire because it's not Integer-Integer.
  src = 'def f; "a" == 5; end'
  ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
  ot = ir.misc[:object_table]
  f = find_iseq(ir, "f")
  before = f.instructions.map(&:opcode)
  Optimize::Passes::ConstFoldPass.new.apply(f, type_env: nil, log: Optimize::Log.new, object_table: ot)
  assert_equal before, f.instructions.map(&:opcode)
end
```

- [ ] **Step 2.2: Run the new tests, confirm they fail.**

Expected: `test_folds_string_equality_triple_to_true` etc. fail — the current `ConstFoldPass` bails on non-Integer operands and leaves the triple intact.

- [ ] **Step 2.3: Extend `try_fold_triple` in `const_fold_pass.rb`.**

Edit `optimizer/lib/optimize/passes/const_fold_pass.rb`, replacing the body of `try_fold_triple` (lines 64-91). Keep the Integer path unchanged; add a String-String branch for `opt_eq`/`opt_neq` only:

```ruby
def try_fold_triple(a, b, op, function, log, object_table)
  sym = FOLDABLE_OPS[op.opcode]
  return nil unless sym
  av = LiteralValue.read(a, object_table: object_table)
  bv = LiteralValue.read(b, object_table: object_table)

  # String-on-String equality: only opt_eq and opt_neq are in scope.
  # Other string ops (+, <, etc.) are not folded — their semantics
  # (Encoding, coercion) are not worth the risk for a talk demo.
  if av.is_a?(String) && bv.is_a?(String) && (op.opcode == :opt_eq || op.opcode == :opt_neq)
    result = av.public_send(sym, bv)
    log.skip(pass: :const_fold, reason: :folded,
             file: function.path, line: (op.line || a.line || function.first_lineno))
    return LiteralValue.emit(result, line: a.line, object_table: object_table)
  end

  # Integer-on-Integer path (unchanged).
  unless av.is_a?(Integer) && bv.is_a?(Integer)
    both_literals = LiteralValue.literal?(a) && LiteralValue.literal?(b)
    if both_literals
      log.skip(pass: :const_fold, reason: :non_integer_literal,
               file: function.path, line: (op.line || a.line || function.first_lineno))
    end
    return nil
  end

  result = av.public_send(sym, bv)
  log.skip(pass: :const_fold, reason: :folded,
           file: function.path, line: (op.line || a.line || function.first_lineno))
  LiteralValue.emit(result, line: a.line, object_table: object_table)
rescue ZeroDivisionError
  log.skip(pass: :const_fold, reason: :would_raise,
           file: function.path, line: (op.line || a.line || function.first_lineno))
  nil
end
```

Note: `LiteralValue.emit(true, ...)` and `LiteralValue.emit(false, ...)` go through the `else` branch and call `object_table.intern(value)`. `intern` supports true/false (they're special-consts — verified in `object_table.rb:202-215`). No codec change needed.

- [ ] **Step 2.4: Run the string-eq tests plus the full `const_fold_pass_test.rb`, confirm all green.**

Expected: the four new tests pass, pre-existing tests (Integer folds, non_integer_literal, would_raise) still pass.

- [ ] **Step 2.5: Commit.**

```bash
jj commit -m "const_fold: fold String==String and String!=String triples"
```

---

## Task 3: `ConstFoldEnvPass` — taint scanner (no folding yet)

Build the taint scanner first and test it in isolation. Folding comes in Task 4. This split keeps each change reviewable.

**Files:**
- Create: `optimizer/lib/optimize/passes/const_fold_env_pass.rb`
- Test: `optimizer/test/passes/const_fold_env_pass_test.rb`

- [ ] **Step 3.1: Write failing tests for the pass as a no-op under every condition except "safe-only uses".**

Create `optimizer/test/passes/const_fold_env_pass_test.rb`:

```ruby
# frozen_string_literal: true
require "test_helper"
require "optimize/codec"
require "optimize/log"
require "optimize/passes/const_fold_env_pass"

class ConstFoldEnvPassTest < Minitest::Test
  # --- Task 3 (taint scanner) tests ---

  def test_no_snapshot_is_noop
    ir = Optimize::Codec.decode(
      RubyVM::InstructionSequence.compile('def f; ENV["FOO"]; end').to_binary
    )
    f = find_iseq(ir, "f")
    before = f.instructions.map(&:opcode)
    Optimize::Passes::ConstFoldEnvPass.new.apply(
      f, type_env: nil, log: Optimize::Log.new,
      object_table: ir.misc[:object_table], env_snapshot: nil,
    )
    assert_equal before, f.instructions.map(&:opcode)
  end

  def test_env_write_in_tree_taints_and_disables_folds
    # Two methods in one tree: one reads ENV["A"], one writes ENV["B"]=...
    src = <<~RUBY
      def r; ENV["A"]; end
      def w; ENV["B"] = "x"; end
    RUBY
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    snap = { "A" => "1", "B" => "2" }.freeze
    log = Optimize::Log.new
    r = find_iseq(ir, "r")
    w = find_iseq(ir, "w")
    before_r = r.instructions.map(&:opcode)
    before_w = w.instructions.map(&:opcode)

    # Apply to every function (as pipeline would).
    each_function(ir) do |fn|
      Optimize::Passes::ConstFoldEnvPass.new.apply(
        fn, type_env: nil, log: log,
        object_table: ot, env_snapshot: snap,
      )
    end

    assert_equal before_r, r.instructions.map(&:opcode), "read should not fold when tree is tainted"
    assert_equal before_w, w.instructions.map(&:opcode)
    tainted = log.for_pass(:const_fold_env).select { |e| e.reason == :env_write_observed }
    assert_operator tainted.size, :>=, 1
  end

  def test_env_fetch_taints_tree
    # ENV.fetch is opt_send_without_block with receiver ENV — tainted in v1.
    src = 'def r; ENV["A"]; end; def f; ENV.fetch("B"); end'
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    snap = { "A" => "1", "B" => "2" }.freeze
    log = Optimize::Log.new
    r = find_iseq(ir, "r")
    before_r = r.instructions.map(&:opcode)

    each_function(ir) do |fn|
      Optimize::Passes::ConstFoldEnvPass.new.apply(
        fn, type_env: nil, log: log,
        object_table: ot, env_snapshot: snap,
      )
    end

    assert_equal before_r, r.instructions.map(&:opcode)
    assert_operator log.for_pass(:const_fold_env).count { |e| e.reason == :env_write_observed }, :>=, 1
  end

  def test_env_with_dynamic_key_does_not_taint
    # ENV[name] — opt_aref with non-literal key. Safe read, just not foldable.
    # Must not emit :env_write_observed.
    src = 'def f; x = "FOO"; ENV[x]; end'
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    log = Optimize::Log.new
    snap = { "FOO" => "1" }.freeze

    each_function(ir) do |fn|
      Optimize::Passes::ConstFoldEnvPass.new.apply(
        fn, type_env: nil, log: log,
        object_table: ot, env_snapshot: snap,
      )
    end

    refute(log.for_pass(:const_fold_env).any? { |e| e.reason == :env_write_observed },
           "opt_aref with non-literal key is a safe use, not a taint")
  end

  private

  def each_function(fn, &blk)
    yield fn
    fn.children&.each { |c| each_function(c, &blk) }
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
```

- [ ] **Step 3.2: Run these tests. Expect all to fail with `cannot load such file -- optimize/passes/const_fold_env_pass`.**

- [ ] **Step 3.3: Create the pass with scanner + no-op fold loop.**

Create `optimizer/lib/optimize/passes/const_fold_env_pass.rb`:

```ruby
# frozen_string_literal: true
require "optimize/pass"

module Optimize
  module Passes
    # Tier 4 const-fold: ENV["LIT"] -> its snapshot value (or nil).
    #
    # Runs per-function like every other pass, but it's the whole IR
    # tree that determines soundness: if *any* function anywhere in
    # the tree has a tainted ENV use (a write, a `fetch`, any send
    # other than the safe `opt_aref` with a string-literal key), every
    # fold site in the tree is skipped. The "anywhere in tree"
    # classification is memoized on the IR root via `function.misc`.
    class ConstFoldEnvPass < Optimize::Pass
      TAINT_FLAG_KEY = :const_fold_env_tree_tainted

      def name = :const_fold_env

      def apply(function, type_env:, log:, object_table: nil, env_snapshot: nil, **_extras)
        _ = type_env
        return unless object_table
        return unless env_snapshot
        insts = function.instructions
        return unless insts

        # Classify this function and merge into the tree-wide taint flag.
        tainted_here, first_taint_line = classify(insts)
        root = tree_root(function)
        root.misc ||= {}
        if tainted_here && !root.misc[TAINT_FLAG_KEY]
          root.misc[TAINT_FLAG_KEY] = true
          log.skip(pass: :const_fold_env, reason: :env_write_observed,
                   file: function.path, line: first_taint_line || function.first_lineno || 0)
        end

        # Fold phase added in Task 4. For now: respect the flag and return.
        return if root.misc[TAINT_FLAG_KEY]
        # no folding yet
      end

      private

      # Walk `insts` and classify every ENV producer by the opcode
      # two slots later (`insts[i+2]`), which is the actual consumer
      # of ENV on the stack:
      #
      #   Read shape:  opt_getconstant_path ENV; <key-producer>; opt_aref
      #   Write shape: opt_getconstant_path ENV; <key>; <value>; setn 3; opt_aset
      #   Fetch shape: opt_getconstant_path ENV; <key>; opt_send_without_block(:fetch)
      #
      # "Safe" == ENV is consumed by `opt_aref` exactly two slots later.
      # Everything else (opt_aset, opt_send_without_block, pop-at-i+2,
      # anything that shuffles the stack before `opt_aref` is reached)
      # taints. For the dynamic-key read (`ENV[x]` → key-producer is
      # `getlocal_WC_0`), this still classifies as safe — the fold
      # phase separately requires the key to be a string literal, so
      # dynamic keys just don't fold (and don't taint).
      #
      # Returns [tainted?, first_taint_line_or_nil].
      def classify(insts)
        first_taint_line = nil
        i = 0
        while i < insts.size
          inst = insts[i]
          if env_producer?(inst)
            consumer = insts[i + 2]
            unless consumer && consumer.opcode == :opt_aref
              first_taint_line ||= (consumer&.line || inst.line)
              return [true, first_taint_line]
            end
          end
          i += 1
        end
        [false, nil]
      end

      def env_producer?(inst)
        case inst.opcode
        when :opt_getconstant_path
          # Operand layout in decoded IR: [ic_index, [:ENV]]
          # (ic_index is an Integer; the Array contains the const-path
          # name symbols). Match if any operand is :ENV or an Array
          # containing :ENV. Verify via a diagnostic print the first
          # time you run the tests — see self-review checklist.
          ops = inst.operands
          ops.is_a?(Array) && ops.any? { |o| o == :ENV || (o.is_a?(Array) && o.include?(:ENV)) }
        when :getconstant
          inst.operands[0] == :ENV
        else
          false
        end
      end

      # Walk up `function.parent` if present; otherwise this IS the root.
      # IR::Function stores children but not parent — for now, assume the
      # pipeline calls apply() on every function in tree order, and the
      # topmost is the one without `.type == :method` (the top-level script).
      # Simpler: since the pipeline's `each_function` yields the root first,
      # we mark the first function seen as the root.
      def tree_root(function)
        # IR::Function doesn't track parent pointers. Walk via a thread-local
        # cache keyed by the pass instance — set on first call in a run.
        @root ||= function
        @root
      end
    end
  end
end
```

**⚠ Design note on `tree_root`:** The IR has no parent pointer. Checking `optimizer/lib/optimize/ir/function.rb` confirms only `children` exists. Two options:

1. **Cache on pass instance** (above): `@root ||= function`. Works because `Pipeline#each_function` yields the root first, and a fresh `ConstFoldEnvPass.new` is constructed per `Pipeline.default` call (verified in `pipeline.rb:11-17`). The pass-instance state is scoped to one pipeline run.
2. **Rely on `ir.misc` directly** — instead of `tree_root(function).misc`, use a thread/global or shared state. More fragile.

Go with option 1: cache `@root` on `apply`'s first call per pass instance. Add a comment. A fresh pass per run is already the convention.

**Correction to the above code:** replace the `tree_root` method with:

```ruby
def tree_root(function)
  @root ||= function
  @root
end
```

(Already reflected above — it memoizes on first call and returns the same root for every subsequent call during this pipeline run.)

- [ ] **Step 3.4: Run the four Task-3 tests. All should pass.**

Expected: green. No folding happens yet (the taint-disabled and no-snapshot cases are correct; the "write taints" and "fetch taints" cases correctly log. The dynamic-key test passes because `opt_aref` is the consumer.)

- [ ] **Step 3.5: Commit.**

```bash
jj commit -m "const_fold_env: scaffolding + whole-tree taint scanner"
```

---

## Task 4: `ConstFoldEnvPass` — folding the 3-tuple

Now add the fold phase to the pass. Tree-taint gate from Task 3 already guards the fold.

**Files:**
- Modify: `optimizer/lib/optimize/passes/const_fold_env_pass.rb`
- Modify: `optimizer/test/passes/const_fold_env_pass_test.rb`

- [ ] **Step 4.1: Write failing tests for the fold path.**

Append to `optimizer/test/passes/const_fold_env_pass_test.rb` (before the `private` section):

```ruby
def test_folds_env_aref_when_value_already_interned
  # "hello" appears in the program so it's in the object table already.
  src = 'def f; ENV["K"] == "hello"; end'
  ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
  ot = ir.misc[:object_table]
  f = find_iseq(ir, "f")
  snap = { "K" => "hello" }.freeze
  log = Optimize::Log.new

  each_function(ir) do |fn|
    Optimize::Passes::ConstFoldEnvPass.new.apply(
      fn, type_env: nil, log: log,
      object_table: ot, env_snapshot: snap,
    )
  end

  # The opt_getconstant_path + putchilledstring "K" + opt_aref triple should be
  # replaced by a single putobject referencing the already-interned "hello".
  opcodes = f.instructions.map(&:opcode)
  refute_includes opcodes, :opt_getconstant_path, "ENV producer should be gone"
  refute_includes opcodes, :opt_aref, "opt_aref should be gone"
  # The "hello" literal may now be pushed via putobject (our emit) OR
  # the original putchilledstring (the RHS of ==). Both are fine.
  loaded = RubyVM::InstructionSequence.load_from_binary(Optimize::Codec.encode(ir))
  assert_equal true, loaded.eval
end

def test_folds_missing_key_to_putnil
  src = 'def f; ENV["MISSING"]; end'
  ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
  ot = ir.misc[:object_table]
  f = find_iseq(ir, "f")
  snap = {}.freeze
  log = Optimize::Log.new

  each_function(ir) do |fn|
    Optimize::Passes::ConstFoldEnvPass.new.apply(
      fn, type_env: nil, log: log,
      object_table: ot, env_snapshot: snap,
    )
  end

  opcodes = f.instructions.map(&:opcode)
  refute_includes opcodes, :opt_getconstant_path
  refute_includes opcodes, :opt_aref
  assert_includes opcodes, :putnil
  loaded = RubyVM::InstructionSequence.load_from_binary(Optimize::Codec.encode(ir))
  assert_nil loaded.eval
end

def test_skips_fold_when_snapshot_value_not_in_object_table
  # "xyzzy" is in the snapshot but NOT anywhere in the compiled program.
  # intern() can't add strings → we skip this fold site and log.
  src = 'def f; ENV["K"]; end'
  ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
  ot = ir.misc[:object_table]
  f = find_iseq(ir, "f")
  snap = { "K" => "xyzzy" }.freeze
  log = Optimize::Log.new
  before = f.instructions.map(&:opcode)

  each_function(ir) do |fn|
    Optimize::Passes::ConstFoldEnvPass.new.apply(
      fn, type_env: nil, log: log,
      object_table: ot, env_snapshot: snap,
    )
  end

  assert_equal before, f.instructions.map(&:opcode)
  not_interned = log.for_pass(:const_fold_env).count { |e| e.reason == :env_value_not_interned }
  assert_operator not_interned, :>=, 1
end

def test_logs_folded_for_each_successful_fold
  src = 'def f; ENV["K"] == "hello"; end'
  ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
  ot = ir.misc[:object_table]
  snap = { "K" => "hello" }.freeze
  log = Optimize::Log.new

  each_function(ir) do |fn|
    Optimize::Passes::ConstFoldEnvPass.new.apply(
      fn, type_env: nil, log: log,
      object_table: ot, env_snapshot: snap,
    )
  end

  folded = log.for_pass(:const_fold_env).select { |e| e.reason == :folded }
  assert_operator folded.size, :>=, 1
end
```

- [ ] **Step 4.2: Run these tests, confirm they fail** — the pass doesn't fold yet, so instructions are unchanged.

- [ ] **Step 4.3: Implement the fold loop.**

Replace the body of `apply` in `const_fold_env_pass.rb` (keep everything else unchanged):

```ruby
def apply(function, type_env:, log:, object_table: nil, env_snapshot: nil, **_extras)
  _ = type_env
  return unless object_table
  return unless env_snapshot
  insts = function.instructions
  return unless insts

  tainted_here, first_taint_line = classify(insts)
  root = tree_root(function)
  root.misc ||= {}
  if tainted_here && !root.misc[TAINT_FLAG_KEY]
    root.misc[TAINT_FLAG_KEY] = true
    log.skip(pass: :const_fold_env, reason: :env_write_observed,
             file: function.path, line: first_taint_line || function.first_lineno || 0)
  end
  return if root.misc[TAINT_FLAG_KEY]

  # Fold phase. Scan for the 3-tuple: opt_getconstant_path ENV;
  # putchilledstring/putstring KEY; opt_aref. Splice -> single
  # putobject VALUE or putnil.
  #
  # Single forward pass; no fixpoint. Each matched triple is replaced
  # by a single instruction — there's no cascading shape at the same
  # site (the replacement is itself a literal, not a fold input for
  # another ENV fold).
  i = 0
  while i <= insts.size - 3
    a  = insts[i]
    b  = insts[i + 1]
    op = insts[i + 2]

    unless env_producer?(a) && literal_string?(b, object_table) && op.opcode == :opt_aref
      i += 1
      next
    end

    key = LiteralValue.read(b, object_table: object_table)
    value = env_snapshot[key]

    replacement =
      if value.nil?
        IR::Instruction.new(opcode: :putnil, operands: [], line: a.line)
      elsif value.is_a?(String)
        idx = object_table.index_for(value)
        if idx.nil?
          log.skip(pass: :const_fold_env, reason: :env_value_not_interned,
                   file: function.path, line: (a.line || function.first_lineno || 0))
          nil
        else
          IR::Instruction.new(opcode: :putobject, operands: [idx], line: a.line)
        end
      else
        # ENV values are always strings or nil by contract. Defensive.
        log.skip(pass: :const_fold_env, reason: :env_value_not_string,
                 file: function.path, line: (a.line || function.first_lineno || 0))
        nil
      end

    if replacement
      function.splice_instructions!(i..(i + 2), [replacement])
      log.skip(pass: :const_fold_env, reason: :folded,
               file: function.path, line: (a.line || function.first_lineno || 0))
      # No step-back: the replacement is a literal leaf, not the start
      # of another ENV triple.
      i += 1
    else
      i += 1
    end
  end
end
```

Add a `literal_string?` helper below `env_producer?`:

```ruby
def literal_string?(inst, object_table)
  return false unless inst
  case inst.opcode
  when :putchilledstring, :putstring
    idx = inst.operands[0]
    idx.is_a?(Integer) && object_table.objects[idx].is_a?(String)
  else
    false
  end
end
```

Also add `require "optimize/passes/literal_value"` and `require "optimize/ir/instruction"` at the top of the file (alongside the existing `require "optimize/pass"`).

- [ ] **Step 4.4: Run all Task-3 and Task-4 tests for `const_fold_env_pass`, confirm green.**

Expected: all pass. The "taint disables fold" tests still work because the fold loop returns early when `root.misc[TAINT_FLAG_KEY]` is set.

- [ ] **Step 4.5: Verify the folded iseq round-trips through encode + load_from_binary + eval.**

The `test_folds_env_aref_when_value_already_interned` test already does this (`assert_equal true, loaded.eval`). Re-run to confirm the emit-path `putobject idx` where `idx` indexes an already-interned String is accepted by the VM on load.

If this fails: the emitted `putobject` may need different stack-effect metadata, or the object_table's encoder might not handle the index reference. If it fails, diagnose with the `ruby-bytecode` MCP `disasm` tool on the re-encoded binary. (I expect it to work — `putobject <str_idx>` is what the decoder already produces for plain-string literals.)

- [ ] **Step 4.6: Commit.**

```bash
jj commit -m "const_fold_env: fold ENV[literal] 3-tuple to snapshot value"
```

---

## Task 5: Register in `Pipeline.default` and end-to-end test

**Files:**
- Modify: `optimizer/lib/optimize/pipeline.rb`
- Modify: `optimizer/test/pipeline_test.rb`

- [ ] **Step 5.1: Write the end-to-end failing test.**

Add to `optimizer/test/pipeline_test.rb`:

```ruby
def test_pipeline_collapses_env_feature_flag_to_boolean
  src = 'def f; ENV["FLAG"] == "true"; end'
  ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
  ot = ir.misc[:object_table]
  snap = { "FLAG" => "true" }.freeze

  Optimize::Pipeline.default.run(ir, type_env: nil, env_snapshot: snap)

  f = find_iseq_in_pipeline_test(ir, "f")
  # After the full pipeline: ENV["FLAG"] folds to "true", then "true"=="true" folds to true.
  # The function body (excluding trailer) should contain a `true` literal.
  assert(f.instructions.any? { |i| Optimize::Passes::LiteralValue.read(i, object_table: ot) == true },
         "expected ENV[FLAG] == 'true' to collapse to `true`")
  # And no ENV refs left.
  refute(f.instructions.any? { |i| i.opcode == :opt_getconstant_path })
  refute(f.instructions.any? { |i| i.opcode == :opt_aref })

  loaded = RubyVM::InstructionSequence.load_from_binary(Optimize::Codec.encode(ir))
  assert_equal true, loaded.eval
end

# Only add this helper if the test file doesn't already have one.
# Check first with grep before adding.
def find_iseq_in_pipeline_test(ir, name)
  return ir if ir.name == name
  ir.children&.each do |c|
    found = find_iseq_in_pipeline_test(c, name)
    return found if found
  end
  nil
end
```

If `pipeline_test.rb` already has a `find_iseq` helper, use that instead.

- [ ] **Step 5.2: Run the test. Expect failure** — either `env_snapshot:` is now plumbed but the pass isn't registered (so no folding happens) and `opt_getconstant_path` is still present.

- [ ] **Step 5.3: Register `ConstFoldEnvPass` in `Pipeline.default`.**

Edit `optimizer/lib/optimize/pipeline.rb`:

```ruby
require "optimize/log"
require "optimize/passes/inlining_pass"
require "optimize/passes/arith_reassoc_pass"
require "optimize/passes/const_fold_env_pass"  # NEW
require "optimize/passes/const_fold_pass"
require "optimize/passes/identity_elim_pass"

module Optimize
  class Pipeline
    def self.default
      new([
        Passes::InliningPass.new,
        Passes::ArithReassocPass.new,
        Passes::ConstFoldEnvPass.new,  # NEW — runs before ConstFoldPass so
                                       # the string-eq cascade fires in the same run.
        Passes::ConstFoldPass.new,
        Passes::IdentityElimPass.new,
      ])
    end
    # ... rest unchanged
  end
end
```

- [ ] **Step 5.4: Re-run the end-to-end test and the full test suite.**

Expected: the new E2E test passes. All existing pipeline and pass tests still pass.

- [ ] **Step 5.5: Commit.**

```bash
jj commit -m "pipeline: register ConstFoldEnvPass before ConstFoldPass in .default"
```

---

## Task 6: Update roadmap

**Files:**
- Modify: `docs/TODO.md`

- [ ] **Step 6.1: Update the status table and roadmap list.**

Edit `docs/TODO.md` (line 15, the Constant folding row):

Before:
```
| Constant folding | 4 tiers: ... | Tier 1 (ConstFoldPass). Tier 3 *partially* via IdentityElim v1 ... | Tier 2 (frozen top-level constants), Tier 3 proper (RBS-typed identities), Tier 4 (ENV folding) |
```

After:
```
| Constant folding | 4 tiers: ... | Tier 1 (ConstFoldPass, now also String==String/!=). Tier 3 *partially* via IdentityElim v1 .... Tier 4 (ConstFoldEnvPass): ENV["LIT"] fold with whole-tree taint gate. | Tier 2 (frozen top-level constants), Tier 3 proper (RBS-typed identities) |
```

Then in the "Roadmap gap, ranked by talk-ROI" list (lines 31-45), remove item **2. Const-fold Tier 4 (ENV)** and renumber following items. Preserve item 1 (RBS type environment) as the new top.

Finally, add a "Refinements of shipped work" entry noting v2 queue:

```markdown
- **`ObjectTable#intern` for frozen strings.** Unblocks unconditional
  ConstFoldEnvPass folding (today, the fold is skipped when the snapshot
  value isn't already in the object table). Encoder already knows how
  to decode T_STRING; append support needs a small branch in
  `write_special_const` + removing the "special-const only" guard in
  `intern`. Log reason `:env_value_not_interned` disappears once shipped.
- **`ConstFoldEnvPass` narrowing of taint classifier.** Currently any
  send on ENV (including read-only `fetch`, `to_h`, `key?`) taints the
  whole tree. Add a whitelist of read-only method names to fold past
  them. Requires reading the `opt_send_without_block` calldata mid.
```

Update the "Last updated" line at the top of the file to `2026-04-23 (after ConstFoldEnvPass Tier 4)`.

- [ ] **Step 6.2: Commit.**

```bash
jj commit -m "docs: TODO.md — Tier 4 const-fold (ENV) shipped"
```

---

## Self-review checklist (do NOT skip)

After all tasks complete:

- [ ] `opt_getconstant_path` operand shape: verified by **writing a diagnostic test** that decodes an `ENV["FOO"]` binary and prints `inst.operands.inspect` for the producer. The plan's `env_producer?` check (`operands.any? { |o| o == :ENV || (o.is_a?(Array) && o.include?(:ENV)) }`) is a best-effort match against the two shapes seen in `codec`-decoded IR. If the actual shape differs, fix the matcher and re-run. **Do this before Step 3.4 if the taint tests fail mysteriously.**
- [ ] Confirm `ConstFoldPass` still rejects `opt_plus` on String × String (plan intentionally doesn't fold `"a" + "b"`).
- [ ] Confirm `env_snapshot: nil` path: `Pipeline.default.run(ir, type_env: nil)` still works (the default value in `run`'s signature).
- [ ] Confirm fresh `ConstFoldEnvPass.new` per `Pipeline.default` call, so `@root` caching is scoped per run.

## Task summary

| Task | Files touched | Commit msg |
|---|---|---|
| 1 | `pipeline.rb`, `pipeline_test.rb` | `pipeline: thread env_snapshot: kwarg through run → apply` |
| 2 | `const_fold_pass.rb`, `const_fold_pass_test.rb` | `const_fold: fold String==String and String!=String triples` |
| 3 | NEW `const_fold_env_pass.rb` + test | `const_fold_env: scaffolding + whole-tree taint scanner` |
| 4 | `const_fold_env_pass.rb` + test | `const_fold_env: fold ENV[literal] 3-tuple to snapshot value` |
| 5 | `pipeline.rb`, `pipeline_test.rb` | `pipeline: register ConstFoldEnvPass before ConstFoldPass in .default` |
| 6 | `docs/TODO.md` | `docs: TODO.md — Tier 4 const-fold (ENV) shipped` |
