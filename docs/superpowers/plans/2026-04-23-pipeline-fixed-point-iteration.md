# Pipeline fixed-point iteration — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wrap `Pipeline#run` in a per-function fixed-point loop over iterative passes so cascades across passes happen automatically, retiring the phase-ordering class of bugs surfaced by the `polynomial` fixture.

**Architecture:** Log gains a `rewrite` method distinct from `skip` so fixed-point termination can gate on "was any IR actually rewritten this sweep?". Pass base class gains a `one_shot?` predicate (defaults false; InliningPass overrides true). Pipeline#run partitions passes, runs one-shots once per function, then loops the iterative passes until `log.rewrite_count` stops changing. Cap of 8 iterations; raise on overflow. Walkthrough progressive-prefix runs inherit the loop for free.

**Tech Stack:** Ruby, Minitest. No new deps.

**Spec:** `docs/superpowers/specs/2026-04-23-pipeline-fixed-point-iteration-design.md`.

---

## File Structure

**Created:**
- (none — this is an in-place refactor)

**Modified:**
- `optimizer/lib/optimize/log.rb` — add `rewrite`, `rewrite_count`, `convergence` map.
- `optimizer/lib/optimize/pass.rb` — add `one_shot?` default.
- `optimizer/lib/optimize/passes/inlining_pass.rb` — override `one_shot?`; migrate `:inlined` sites to `rewrite`.
- `optimizer/lib/optimize/passes/arith_reassoc_pass.rb` — migrate `:reassociated` sites to `rewrite`.
- `optimizer/lib/optimize/passes/const_fold_pass.rb` — migrate `:folded` sites to `rewrite`.
- `optimizer/lib/optimize/passes/const_fold_tier2_pass.rb` — migrate `:folded` sites to `rewrite`.
- `optimizer/lib/optimize/passes/const_fold_env_pass.rb` — migrate `:folded` sites to `rewrite`.
- `optimizer/lib/optimize/passes/identity_elim_pass.rb` — migrate `:identity_eliminated` to `rewrite`.
- `optimizer/lib/optimize/passes/dead_branch_fold_pass.rb` — migrate `:branch_folded`, `:short_circuit_folded` to `rewrite`.
- `optimizer/lib/optimize/pipeline.rb` — fixed-point loop, overflow class.
- `optimizer/lib/optimize/demo/markdown_renderer.rb` — convergence header line.
- `optimizer/test/pipeline_test.rb` — new cascade, overflow, no-change cases.
- `optimizer/test/log_test.rb` — new `rewrite` / `rewrite_count` / `convergence` cases.
- `docs/demo_artifacts/*.md` — regenerated artifacts for any fixture whose output changed.
- `docs/TODO.md` — strike polynomial cascade gaps; add fixed-point entry.

---

## How to run things (shared context)

- Ruby execution runs under the ruby-bytecode MCP server per the repo convention. Use `mcp__ruby-bytecode__run_ruby` with `args: ["-Ioptimizer/lib", "-Ioptimizer/test", ...]` rather than shelling `ruby` or `bundle exec`.
- Run the full optimizer test suite with: `mcp__ruby-bytecode__run_ruby` and `args: ["-Ioptimizer/lib", "-Ioptimizer/test", "optimizer/test/all.rb"]` if that exists, otherwise `args: ["-Ioptimizer/lib", "-Ioptimizer/test", "-rrake/test_task", "-e", "Dir['optimizer/test/**/*_test.rb'].each { |f| require File.expand_path(f) }"]`. Prefer `mcp__ruby-bytecode__run_ruby` + an inline `-e` driver that requires the specific test file when iterating on one file.
- Regenerate a demo artifact: `mcp__ruby-bytecode__run_ruby` with the `bin/demo <fixture>` driver (e.g. `args: ["optimizer/bin/demo", "polynomial"]`).
- Verify all artifacts: `rake demo:verify` (via `mcp__ruby-bytecode__run_ruby` + rake invocation, or skip Rake and require the same code path).
- Commits use `jj commit -m`, not `jj describe -m`. Target is `@` (working copy).

---

## Task 1: Log — add `rewrite`, `rewrite_count`, `convergence`

**Files:**
- Modify: `optimizer/lib/optimize/log.rb`
- Test: `optimizer/test/log_test.rb`

- [ ] **Step 1: Read the existing `Log` class to confirm current shape**

Read `optimizer/lib/optimize/log.rb` (23 lines) and `optimizer/test/log_test.rb`. Confirm `Entry = Struct.new(:pass, :reason, :file, :line, keyword_init: true)` and that `#skip` appends to `@entries`.

- [ ] **Step 2: Write failing test for `rewrite` and `rewrite_count`**

Add to `optimizer/test/log_test.rb`:

```ruby
def test_rewrite_appends_entry_and_bumps_rewrite_count
  log = Optimize::Log.new
  assert_equal 0, log.rewrite_count

  log.rewrite(pass: :const_fold, reason: :folded, file: "f.rb", line: 3)
  assert_equal 1, log.rewrite_count
  assert_equal 1, log.entries.size
  entry = log.entries.first
  assert_equal :const_fold, entry.pass
  assert_equal :folded, entry.reason
end

def test_skip_does_not_bump_rewrite_count
  log = Optimize::Log.new
  log.skip(pass: :const_fold, reason: :would_raise, file: "f.rb", line: 3)
  assert_equal 0, log.rewrite_count
  assert_equal 1, log.entries.size
end

def test_convergence_map_round_trips
  log = Optimize::Log.new
  log.record_convergence("fnA", 3)
  log.record_convergence("fnB", 1)
  assert_equal({ "fnA" => 3, "fnB" => 1 }, log.convergence)
end
```

- [ ] **Step 3: Run the new tests to verify they fail**

Run: `mcp__ruby-bytecode__run_ruby` with `args: ["-Ioptimizer/lib", "-Ioptimizer/test", "optimizer/test/log_test.rb"]`.
Expected: FAIL — `NoMethodError: undefined method 'rewrite'` / `'rewrite_count'` / `'record_convergence'`.

- [ ] **Step 4: Implement the new methods**

Replace `optimizer/lib/optimize/log.rb` with:

```ruby
# frozen_string_literal: true

module Optimize
  class Log
    Entry = Struct.new(:pass, :reason, :file, :line, keyword_init: true)

    def initialize
      @entries = []
      @rewrite_count = 0
      @convergence = {}
    end

    def entries
      @entries.dup.freeze
    end

    attr_reader :rewrite_count, :convergence

    # An optimization site that actually rewrote IR. Feeds fixed-point
    # termination via rewrite_count.
    def rewrite(pass:, reason:, file:, line:)
      @entries << Entry.new(pass: pass, reason: reason, file: file, line: line)
      @rewrite_count += 1
    end

    # An optimization site that declined to rewrite. Does NOT count toward
    # rewrite_count — fixed-point iteration must not treat a decline as a
    # change.
    def skip(pass:, reason:, file:, line:)
      @entries << Entry.new(pass: pass, reason: reason, file: file, line: line)
    end

    def record_convergence(function_key, iterations)
      @convergence[function_key] = iterations
    end

    def for_pass(pass)
      @entries.select { |e| e.pass == pass }
    end
  end
end
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: same command as step 3.
Expected: PASS — new tests green; existing tests (`log_test.rb`) unaffected.

- [ ] **Step 6: Commit**

```bash
jj commit -m "feat(log): add rewrite, rewrite_count, convergence for fixed-point gate

Log#rewrite records an entry AND bumps a rewrite counter. Log#skip
records an entry only. This lets Pipeline#run gate fixed-point
termination on actual IR rewrites, not skipped-optimization entries."
```

---

## Task 2: Migrate pass rewrite sites from `skip` to `rewrite`

Each pass has a known set of reasons that indicate IR changed. Migrate those sites; leave decline reasons on `skip`.

**Per-pass taxonomy (rewrite reasons only):**
- `inlining_pass.rb`: `:inlined` (3 sites)
- `arith_reassoc_pass.rb`: `:reassociated` (2 sites)
- `const_fold_pass.rb`: `:folded` (3 sites — lines 75, 94; also 87 is a skip `:non_integer_literal`, confirm)
- `const_fold_tier2_pass.rb`: `:folded` (1 site, line 61)
- `const_fold_env_pass.rb`: `:folded` (5 sites: 91, 100, 125, 137; confirm exact list by grep)
- `identity_elim_pass.rb`: `:identity_eliminated` (1 site, line 43)
- `dead_branch_fold_pass.rb`: `:branch_folded`, `:short_circuit_folded` (lines 59, 81)

One file per commit keeps the diff reviewable.

### Task 2a: `inlining_pass.rb`

- [ ] **Step 1: Locate rewrite sites**

Run: `grep -n "log.skip" optimizer/lib/optimize/passes/inlining_pass.rb`.
Confirm: only `reason: :inlined` indicates a successful inline (lines 118, 185, 291 in the current file). Every other reason is a decline.

- [ ] **Step 2: Edit**

For each of the three lines, change `log.skip(pass: :inlining, reason: :inlined,` to `log.rewrite(pass: :inlining, reason: :inlined,`. Preserve the file/line args.

- [ ] **Step 3: Run the inlining pass tests**

Run: `mcp__ruby-bytecode__run_ruby` with `args: ["-Ioptimizer/lib", "-Ioptimizer/test", "optimizer/test/passes/inlining_pass_test.rb"]`.
Expected: PASS. Any test that asserts on `log.entries` or `for_pass(:inlining)` continues to pass because `rewrite` still appends an Entry.

- [ ] **Step 4: Commit**

```bash
jj commit -m "refactor(inlining): log :inlined via Log#rewrite"
```

### Task 2b: `arith_reassoc_pass.rb`

- [ ] **Step 1: Locate rewrite sites**

Run: `grep -n "reason: :reassociated" optimizer/lib/optimize/passes/arith_reassoc_pass.rb`. Confirm 2 sites (around lines 320, 387).

- [ ] **Step 2: Edit**

Change both `log.skip(pass: :arith_reassoc, reason: :reassociated,` → `log.rewrite(...)`.

- [ ] **Step 3: Run the pass tests**

Run: `args: ["-Ioptimizer/lib", "-Ioptimizer/test", "optimizer/test/passes/arith_reassoc_pass_test.rb"]`.
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
jj commit -m "refactor(arith_reassoc): log :reassociated via Log#rewrite"
```

### Task 2c: `const_fold_pass.rb`

- [ ] **Step 1: Locate rewrite sites**

Run: `grep -n "reason:" optimizer/lib/optimize/passes/const_fold_pass.rb`. The `:folded` reason is a rewrite; `:non_integer_literal` and `:would_raise` are declines.

- [ ] **Step 2: Edit**

Change every `log.skip(pass: :const_fold, reason: :folded,` → `log.rewrite(...)`. Leave `:non_integer_literal` and `:would_raise` on `skip`.

- [ ] **Step 3: Run the pass tests**

Run: `args: ["-Ioptimizer/lib", "-Ioptimizer/test", "optimizer/test/passes/const_fold_pass_test.rb"]`.
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
jj commit -m "refactor(const_fold): log :folded via Log#rewrite"
```

### Task 2d: `const_fold_tier2_pass.rb`

- [ ] **Step 1: Edit**

The sole rewrite site is `reason: :folded` (around line 61). Change to `log.rewrite(...)`. `:reassigned`, `:non_literal_rhs`, `:non_top_level` stay on `skip`.

- [ ] **Step 2: Run the pass tests**

Run: `args: ["-Ioptimizer/lib", "-Ioptimizer/test", "optimizer/test/passes/const_fold_tier2_pass_test.rb"]`.
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
jj commit -m "refactor(const_fold_tier2): log :folded via Log#rewrite"
```

### Task 2e: `const_fold_env_pass.rb`

- [ ] **Step 1: Locate rewrite sites**

Run: `grep -n "reason: :folded" optimizer/lib/optimize/passes/const_fold_env_pass.rb`. Every `:folded` is a rewrite. Non-folded reasons (`:env_value_not_string`, `:fetch_key_absent`, `:env_write_observed`) are declines.

- [ ] **Step 2: Edit**

Change every `:folded` call site from `skip` to `rewrite`.

- [ ] **Step 3: Run the pass tests**

Run: `args: ["-Ioptimizer/lib", "-Ioptimizer/test", "optimizer/test/passes/const_fold_env_pass_test.rb"]`.
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
jj commit -m "refactor(const_fold_env): log :folded via Log#rewrite"
```

### Task 2f: `identity_elim_pass.rb`

- [ ] **Step 1: Edit**

Line 43: `log.skip(pass: :identity_elim, reason: :identity_eliminated,` → `log.rewrite(...)`.

- [ ] **Step 2: Run the pass tests**

Run: `args: ["-Ioptimizer/lib", "-Ioptimizer/test", "optimizer/test/passes/identity_elim_pass_test.rb"]`.
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
jj commit -m "refactor(identity_elim): log :identity_eliminated via Log#rewrite"
```

### Task 2g: `dead_branch_fold_pass.rb`

- [ ] **Step 1: Edit**

Lines 59, 81: `:branch_folded` and `:short_circuit_folded` → `log.rewrite(...)`.

- [ ] **Step 2: Run the pass tests**

Run: `args: ["-Ioptimizer/lib", "-Ioptimizer/test", "optimizer/test/passes/dead_branch_fold_pass_test.rb"]`.
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
jj commit -m "refactor(dead_branch_fold): log :branch_folded / :short_circuit_folded via Log#rewrite"
```

### Task 2h: Full-suite gate

- [ ] **Step 1: Run the full optimizer test suite**

Run: `mcp__ruby-bytecode__run_ruby` with args pointing at the whole test tree. Concretely:
`args: ["-Ioptimizer/lib", "-Ioptimizer/test", "-e", "Dir.glob('optimizer/test/**/*_test.rb').each { |f| require File.expand_path(f) }"]`.
Expected: all green. If anything fails, diagnose — a test that asserted `log.for_pass(:const_fold).any? { |e| e.reason == :folded }` still passes because `rewrite` appends to the same `@entries`; anything else is a bug.

- [ ] **Step 2: No commit** — this is a gate. If green, proceed to Task 3.

---

## Task 3: `Pass#one_shot?` + `InliningPass` override

**Files:**
- Modify: `optimizer/lib/optimize/pass.rb`
- Modify: `optimizer/lib/optimize/passes/inlining_pass.rb`
- Test: `optimizer/test/pipeline_test.rb` (smoke)

- [ ] **Step 1: Write failing test**

Append to `optimizer/test/pipeline_test.rb`:

```ruby
def test_pass_defaults_to_not_one_shot
  refute Optimize::Pass.new.one_shot?
end

def test_inlining_pass_is_one_shot
  require "optimize/passes/inlining_pass"
  assert Optimize::Passes::InliningPass.new.one_shot?
end

def test_other_passes_are_not_one_shot
  require "optimize/passes/arith_reassoc_pass"
  require "optimize/passes/const_fold_pass"
  refute Optimize::Passes::ArithReassocPass.new.one_shot?
  refute Optimize::Passes::ConstFoldPass.new.one_shot?
end
```

- [ ] **Step 2: Run to verify fail**

Run: `args: ["-Ioptimizer/lib", "-Ioptimizer/test", "optimizer/test/pipeline_test.rb"]`.
Expected: FAIL — `NoMethodError: undefined method 'one_shot?'`.

- [ ] **Step 3: Implement in `Pass`**

Edit `optimizer/lib/optimize/pass.rb`, add to `Pass`:

```ruby
def one_shot?
  false
end
```

- [ ] **Step 4: Override in `InliningPass`**

Edit `optimizer/lib/optimize/passes/inlining_pass.rb`, add in the class body:

```ruby
def one_shot?
  true
end
```

- [ ] **Step 5: Run to verify pass**

Run: same as step 2.
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
jj commit -m "feat(pass): add one_shot? predicate; InliningPass overrides true"
```

---

## Task 4: `Pipeline::FixedPointOverflow` + fixed-point loop

**Files:**
- Modify: `optimizer/lib/optimize/pipeline.rb`
- Test: `optimizer/test/pipeline_test.rb`

- [ ] **Step 1: Write failing test for cascade**

Append to `optimizer/test/pipeline_test.rb`:

```ruby
# A pass that rewrites instruction X→Y on each function that still contains X,
# logging :cascade_a. Idempotent once X is gone.
class CascadePassA < Optimize::Pass
  def apply(function, type_env:, log:, **_extras)
    return unless (function.instructions || []).any? { |i| i.opcode == :x_marker }
    function.instructions.each do |i|
      i.instance_variable_set(:@opcode, :y_marker) if i.opcode == :x_marker
    end
    log.rewrite(pass: :cascade_a, reason: :x_to_y, file: function.path || "", line: 0)
  end

  def name; :cascade_a; end
end

# A pass that rewrites Y→Z, logging :cascade_b. Idempotent once Y is gone.
class CascadePassB < Optimize::Pass
  def apply(function, type_env:, log:, **_extras)
    return unless (function.instructions || []).any? { |i| i.opcode == :y_marker }
    function.instructions.each do |i|
      i.instance_variable_set(:@opcode, :z_marker) if i.opcode == :y_marker
    end
    log.rewrite(pass: :cascade_b, reason: :y_to_z, file: function.path || "", line: 0)
  end

  def name; :cascade_b; end
end

def cascade_ir_with_marker
  ir = Optimize::Codec.decode(
    RubyVM::InstructionSequence.compile("def f; 1; end").to_binary
  )
  # Stick an :x_marker on each function so the cascade has something to chew on.
  walk = ->(fn) {
    (fn.instructions || []).each { |i| i.instance_variable_set(:@opcode, :x_marker) if i.opcode == :putobject_INT2FIX_1_ }
    (fn.children || []).each { |c| walk.call(c) }
  }
  walk.call(ir)
  ir
end

def test_fixed_point_loop_cascades_across_passes
  ir = cascade_ir_with_marker
  pipeline = Optimize::Pipeline.new([CascadePassA.new, CascadePassB.new])
  log = pipeline.run(ir, type_env: nil)
  # cascade_a ran once per function that had :x_marker.
  refute_empty log.for_pass(:cascade_a)
  # cascade_b must have fired too — a second sweep, after cascade_a exposed :y_marker.
  refute_empty log.for_pass(:cascade_b)
  # convergence map is populated.
  refute_empty log.convergence
end

def test_fixed_point_loop_converges_with_no_rewrites
  # Two no-op passes: single sweep, break immediately.
  t1 = TrackingPass.new(:first)
  t2 = TrackingPass.new(:second)
  pipeline = Optimize::Pipeline.new([t1, t2])
  pipeline.run(ir, type_env: nil)
  # Each pass visited each function exactly once (no iteration needed).
  assert_equal 4, t1.visited.size
  assert_equal 4, t2.visited.size
end

# A pass that always records a rewrite without changing IR — simulates a bug.
class ForeverRewritingPass < Optimize::Pass
  def apply(function, type_env:, log:, **_extras)
    log.rewrite(pass: :forever, reason: :always, file: function.path || "", line: 0)
  end

  def name; :forever; end
end

def test_fixed_point_loop_raises_on_overflow
  pipeline = Optimize::Pipeline.new([ForeverRewritingPass.new])
  assert_raises(Optimize::Pipeline::FixedPointOverflow) do
    pipeline.run(ir, type_env: nil)
  end
end

def test_one_shot_pass_runs_exactly_once_even_if_iterative_passes_loop
  # Build a one-shot tracking pass and a cascade pair so iteration > 1.
  one_shot = Class.new(Optimize::Pass) do
    attr_reader :call_count
    def initialize; @call_count = Hash.new(0); end
    def one_shot?; true; end
    def apply(function, type_env:, log:, **_extras)
      @call_count[function.name] += 1
    end
    def name; :one_shot_tracker; end
  end.new

  ir = cascade_ir_with_marker
  pipeline = Optimize::Pipeline.new([one_shot, CascadePassA.new, CascadePassB.new])
  pipeline.run(ir, type_env: nil)
  # Each function saw the one-shot pass exactly once, even though the
  # iterative passes looped.
  assert one_shot.call_count.values.all? { |c| c == 1 }, one_shot.call_count.inspect
end
```

- [ ] **Step 2: Run to verify fail**

Run: `args: ["-Ioptimizer/lib", "-Ioptimizer/test", "optimizer/test/pipeline_test.rb"]`.
Expected: FAIL — `cascade_b` empty (it never fires without the loop); `FixedPointOverflow` constant undefined; convergence map empty.

- [ ] **Step 3: Add `FixedPointOverflow` and `MAX_ITERATIONS`**

Edit `optimizer/lib/optimize/pipeline.rb`, inside `class Pipeline` (top):

```ruby
MAX_ITERATIONS = 8

class FixedPointOverflow < StandardError
  def initialize(function_name:, iterations:)
    super("pipeline did not converge after #{iterations} iterations on function #{function_name.inspect}")
    @function_name = function_name
    @iterations = iterations
  end
  attr_reader :function_name, :iterations
end
```

- [ ] **Step 4: Restructure `Pipeline#run` per-function body**

Replace the per-function body in `Pipeline#run` (current `@passes.each do |pass| ... end` block) with:

```ruby
one_shot_passes, iterative_passes = @passes.partition(&:one_shot?)

# One-shot passes: run exactly once per function.
one_shot_passes.each do |pass|
  run_single_pass(pass, function, type_env, log, object_table, callee_map,
                  slot_type_map, signature_map, env_snapshot)
end

# Iterative passes: sweep until rewrite_count stops growing. Cap at
# MAX_ITERATIONS; raising beyond that signals either pass oscillation
# or a pass that records rewrites without changing IR.
iterations = 0
if iterative_passes.any?
  loop do
    iterations += 1
    snapshot = log.rewrite_count
    iterative_passes.each do |pass|
      run_single_pass(pass, function, type_env, log, object_table, callee_map,
                      slot_type_map, signature_map, env_snapshot)
    end
    break if log.rewrite_count == snapshot
    if iterations >= MAX_ITERATIONS
      raise FixedPointOverflow.new(function_name: function.name, iterations: iterations)
    end
  end
end

log.record_convergence(function.name, iterations)
```

And extract the inner call into a private helper so we don't duplicate the rescue:

```ruby
private

def run_single_pass(pass, function, type_env, log, object_table, callee_map,
                    slot_type_map, signature_map, env_snapshot)
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
```

Leave `each_function`, `build_callee_map`, `build_type_maps` etc. untouched.

- [ ] **Step 5: Run to verify pass**

Run: same as step 2.
Expected: PASS for the new cases. `test_raising_pass_logs_and_continues` must still pass — the rescue moved into `run_single_pass` but behaves identically (still appends `:pass_raised` via `skip`, which does NOT bump `rewrite_count`, so the loop exits after one sweep, which is what the existing test expects).

- [ ] **Step 6: Commit**

```bash
jj commit -m "feat(pipeline): per-function fixed-point loop over iterative passes

One-shot passes (InliningPass) run exactly once; iterative peephole
passes sweep until Log#rewrite_count stops growing. Cap at 8 iterations;
raises FixedPointOverflow on overshoot (indicates pass oscillation or a
pass that records rewrites without changing IR)."
```

---

## Task 5: Full existing-test regression gate

**Files:** (verification only)

- [ ] **Step 1: Run the entire optimizer test suite**

Run: `args: ["-Ioptimizer/lib", "-Ioptimizer/test", "-e", "Dir.glob('optimizer/test/**/*_test.rb').sort.each { |f| require File.expand_path(f) }"]`.
Expected: all green.

- [ ] **Step 2: Triage any failures**

For each failure, determine which bucket:

- **Bucket A (regression — must fix):** existing behaviour broken. Examples: a test asserting on a specific log entry count that now includes convergence-triggered extra sweeps. Fix the implementation, not the test.
- **Bucket B (intentional improvement — approve):** test was asserting on pre-cascade output that is now strictly better. Update the test, commit separately with message explaining why the improvement is correct.
- **Bucket C (flake):** re-run to confirm. If stable, treat as A or B.

Record each failure's bucket in the commit message if any test is updated.

- [ ] **Step 3: No commit if clean; otherwise fix + commit**

If all green: no action, proceed. If any Bucket-A fixes needed: separate commit per fix, message format:
```
fix(<area>): <what regressed> under fixed-point loop
```
If any Bucket-B updates: separate commit:
```
test(<area>): update <test_name> — cascade now folds <before> → <after>
```

---

## Task 6: Regenerate demo artifacts

**Files:**
- Modify: `docs/demo_artifacts/polynomial.md`
- Modify: `docs/demo_artifacts/point_distance.md` (likely)
- Modify: `docs/demo_artifacts/sum_of_squares.md` (likely)
- `docs/demo_artifacts/claude_*.md` — untouched (not in Pipeline.default).

- [ ] **Step 1: Regenerate `polynomial`**

Run: `mcp__ruby-bytecode__run_ruby` with `args: ["optimizer/bin/demo", "polynomial"]`.
Expected: `docs/demo_artifacts/polynomial.md` rewritten. The diff should show visible changes on `arith_reassoc` and `identity_elim` slides. Inspect the diff to confirm the cascade landed (expect `n * 2 * 6 / 12` to collapse to something like `n * 1 → n`; trailing `+ 0` may remain pending the separate (C) fix).

- [ ] **Step 2: Regenerate `point_distance`**

Run: `args: ["optimizer/bin/demo", "point_distance"]`.
Expected: artifact may be identical or may gain tiny cascade-produced folds. Inspect diff.

- [ ] **Step 3: Regenerate `sum_of_squares`**

Run: `args: ["optimizer/bin/demo", "sum_of_squares"]`.
Expected: most passes remain `(no change)` since no shipped pass is loop-aware. Diff should be benchmark-line noise only.

- [ ] **Step 4: Verify all artifacts**

Run `rake demo:verify` equivalent: `mcp__ruby-bytecode__run_ruby` with `args: ["-Ioptimizer/lib", "-e", "require 'rake'; Rake.load_rakefile('optimizer/Rakefile'); Rake::Task['demo:verify'].invoke"]`.
Expected: `demo:verify OK (N fixtures + M claude)`. If any fixture fails, re-run its regeneration (Rake's verify masks benchmark noise; a diff beyond that indicates the artifact is stale).

- [ ] **Step 5: Commit artifacts**

```bash
jj commit -m "demo(artifacts): regenerate under fixed-point pipeline

polynomial now shows a cascaded collapse on arith_reassoc / identity_elim
(expected — phase ordering no longer blocks the fold). point_distance
and sum_of_squares unchanged except for benchmark-line noise."
```

---

## Task 7: Convergence count in walkthrough header

**Files:**
- Modify: `optimizer/lib/optimize/demo/markdown_renderer.rb`
- Modify: `optimizer/lib/optimize/demo/iseq_snapshots.rb` (expose convergence from full run)

- [ ] **Step 1: Expose convergence on `IseqSnapshots::Result`**

Edit `optimizer/lib/optimize/demo/iseq_snapshots.rb`:

Change `Result = Struct.new(:before, :after_full, :per_pass, keyword_init: true)` to:

```ruby
Result = Struct.new(:before, :after_full, :per_pass, :convergence, keyword_init: true)
```

In `generate`, capture the log from the full run. Modify `run_with_passes` to return both the disasm and the log. Simplest refactor:

```ruby
def run_with_passes(source, path, passes)
  iseq = RubyVM::InstructionSequence.compile(source, path, path)
  binary = iseq.to_binary
  ir = Codec.decode(binary)
  type_env = TypeEnv.from_source(source, path)
  log = Pipeline.new(passes).run(ir, type_env: type_env)
  modified = Codec.encode(ir)
  [RubyVM::InstructionSequence.load_from_binary(modified).disasm, log]
end
```

Then in `generate`:

```ruby
after_full_disasm, after_full_log = run_with_passes(source, fixture_path, Pipeline.default.passes)
per_pass = {}
walkthrough.each_with_index do |name, idx|
  prefix = walkthrough[0..idx].map { |n| pass_index.fetch(n) }
  per_pass[name], _ = run_with_passes(source, fixture_path, prefix)
end

Result.new(
  before: before,
  after_full: after_full_disasm,
  per_pass: per_pass,
  convergence: after_full_log.convergence,
)
```

- [ ] **Step 2: Write failing test for the header line**

In `optimizer/test/demo/markdown_renderer_test.rb` (create if absent; check first: `ls optimizer/test/demo/`), add:

```ruby
def test_heading_includes_convergence_when_present
  bench = Struct.new(:plain_ips, :optimized_ips).new(1000.0, 1010.0)
  md = Optimize::Demo::MarkdownRenderer.heading("polynomial", bench, convergence: { "compute" => 3 })
  assert_includes md, "converged in"
  assert_includes md, "3 iterations"
end

def test_heading_omits_convergence_when_absent
  bench = Struct.new(:plain_ips, :optimized_ips).new(1000.0, 1010.0)
  md = Optimize::Demo::MarkdownRenderer.heading("polynomial", bench, convergence: {})
  refute_includes md, "converged"
end
```

If `optimizer/test/demo/markdown_renderer_test.rb` doesn't exist, stub it with the standard `require "test_helper"; require "optimize/demo/markdown_renderer"` header plus a `class MarkdownRendererTest < Minitest::Test` wrapper.

- [ ] **Step 3: Run test to verify fail**

Run: `args: ["-Ioptimizer/lib", "-Ioptimizer/test", "optimizer/test/demo/markdown_renderer_test.rb"]`.
Expected: FAIL — `wrong number of arguments` or method signature mismatch on `heading`.

- [ ] **Step 4: Update `MarkdownRenderer`**

Edit `optimizer/lib/optimize/demo/markdown_renderer.rb`:

```ruby
def render(stem:, source:, walkthrough:, snapshots:, bench:)
  prev_norm = DisasmNormalizer.normalize(snapshots.before)
  sections = []
  sections << heading(stem, bench, convergence: snapshots.convergence || {})
  sections << source_section(source)
  # ... rest unchanged
end

def heading(stem, bench, convergence: {})
  ratio = bench.optimized_ips / bench.plain_ips
  lines = [
    "# #{stem} demo",
    "",
    "Pipeline.default: **#{format('%.2f', ratio)}x** vs unoptimized.",
  ]
  unless convergence.empty?
    max_iters = convergence.values.max
    lines << ""
    lines << "Converged in #{max_iters} iterations (max across functions)."
  end
  lines.join("\n")
end
```

- [ ] **Step 5: Run test to verify pass**

Run: same as step 3.
Expected: PASS.

- [ ] **Step 6: Regenerate artifacts (again) with the new header**

Re-run each `bin/demo <fixture>` as in Task 6. Expected: each artifact gains a `Converged in N iterations` line under the header. Inspect diffs.

- [ ] **Step 7: `rake demo:verify`**

Need to teach the verifier mask to allow the new header variation? Check `optimizer/Rakefile`: the existing `HEADER_RATIO_RE` already masks the ratio line. The new convergence line is deterministic — it should match exactly between regeneration and commit. No mask change needed unless `demo:verify` fails.

Run verify. If it fails on the new line, decide: either (a) the line is non-deterministic (shouldn't be — convergence count is deterministic), or (b) a stale artifact needs regenerating. In case (b), re-run `bin/demo` for that fixture.

- [ ] **Step 8: Full optimizer test suite + demo:verify**

Run both to gate. Expected: all green.

- [ ] **Step 9: Commit**

```bash
jj commit -m "feat(demo): convergence count in walkthrough header

IseqSnapshots::Result now carries the per-function convergence map from
the Log. MarkdownRenderer surfaces the max iteration count in the demo
artifact heading."
```

---

## Task 8: Update TODO.md

**Files:**
- Modify: `docs/TODO.md`

- [ ] **Step 1: Strike the polynomial cascade section**

Open `docs/TODO.md`. Find "Polynomial-demo cascade gaps (filed 2026-04-22)". The (B) fix and the concern about phase-ordering are now obsolete. Edit the section header and body to reflect: "Fixed-point loop shipped 2026-04-23 — phase-ordering issues in (B) are retired wholesale. (A) and (C) remain as future work since they're peephole-window bugs independent of ordering." Preserve the (A) and (C) entries as forward-looking items.

- [ ] **Step 2: Add a top-level line under "Three-pass plan: status"**

Under the `Last updated:` line near the top, bump the date to 2026-04-23 and add:

```
(2026-04-23: Pipeline fixed-point iteration shipped — cascades across
passes now happen automatically, retiring phase-ordering concerns.)
```

- [ ] **Step 3: Add a roadmap entry**

Under "Roadmap gap, ranked by talk-ROI", add a strike-through entry for this work with the spec + plan paths, in the format existing entries use.

- [ ] **Step 4: Commit**

```bash
jj commit -m "docs(todo): strike polynomial cascade gap (B) — fixed-point loop shipped"
```

---

## Final verification

- [ ] Run the full optimizer test suite one last time.
- [ ] Run `rake demo:verify`.
- [ ] Inspect `docs/demo_artifacts/polynomial.md` — confirm the arith_reassoc and identity_elim slides show real diffs and the header has a `Converged in N iterations` line.
- [ ] Check `jj log` shows the expected sequence of commits from Tasks 1–8 on top of `c24c445`.

---

## Self-review notes

- Every task has concrete file paths and code — no TBD/TODO placeholders.
- Rewrite-reason taxonomy is listed explicitly in Task 2 preamble so each sub-task has the list in context.
- Method names are consistent: `Log#rewrite`, `Log#rewrite_count`, `Log#record_convergence`, `Log#convergence`, `Pass#one_shot?`, `Pipeline::FixedPointOverflow`, `Pipeline::MAX_ITERATIONS`, `MarkdownRenderer.heading(stem, bench, convergence:)`.
- Regression gate is a named step (Task 5), not an afterthought.
- Artifact regeneration happens twice (Task 6 and Task 7 step 6) — this is intentional: Task 6 proves the loop works semantically; Task 7 adds the convergence header line. Splitting keeps each commit reviewable.
- Task 2 is split per-pass to keep diffs small and each commit reviewable in isolation.
