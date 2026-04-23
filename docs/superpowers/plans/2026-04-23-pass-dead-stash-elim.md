# DeadStashElimPass — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a peephole pass that eliminates adjacent `setlocal X; getlocal X` pairs where slot X has no other references at that level, collapsing the inliner's redundant argument-stash round-trip.

**Architecture:** One new `Pass` subclass iterating each function's instruction stream; for each adjacent `setlocal/getlocal` pair that matches on slot + level and whose slot has no other references, splice both out. Registered iteratively in `Pipeline.default` directly after `InliningPass` so the newly exposed producer cascades through arith/const-fold within the same fixed-point iteration.

**Tech Stack:** Ruby, Minitest. No new deps.

**Spec:** `docs/superpowers/specs/2026-04-23-pass-dead-stash-elim-design.md`.

---

## File Structure

**Created:**
- `optimizer/lib/ruby_opt/passes/dead_stash_elim_pass.rb` — the pass.
- `optimizer/test/passes/dead_stash_elim_pass_test.rb` — unit tests.

**Modified:**
- `optimizer/lib/ruby_opt/pipeline.rb` — require + register in `Pipeline.default`.
- `optimizer/lib/ruby_opt/demo/markdown_renderer.rb` — one-line entry in `PASS_DESCRIPTIONS`.
- `docs/demo_artifacts/polynomial.md` — regenerated.
- `docs/TODO.md` — strike the cascade-gap bullet this resolves; add a new entry for full DSE.

---

## Shared context

- Ruby 4.0 in Docker. Tests via `mcp__ruby-bytecode__run_optimizer_tests`.
- Demo artifact regeneration from the repo root:
  ```
  docker run --rm \
    -v "$(pwd)/optimizer:/w" \
    -v "$(pwd)/docs:/docs" \
    -w /w \
    ruby:4.0.2 \
    bash -c "bundle config set --local path vendor/bundle >/dev/null && bundle install --quiet && bundle exec ruby -Ilib bin/demo polynomial"
  ```
- jj, not git. `jj commit -m "msg" <paths>`.
- `Log#rewrite` bumps the fixed-point counter; `Log#skip` doesn't. New rewrite reasons go through `rewrite`.
- Existing `Pass` base class: `optimizer/lib/ruby_opt/pass.rb`. Subclasses override `#apply` and optionally `#name` / `#one_shot?`. Default `#one_shot?` is false.
- IR model: `function.instructions` is an Array of `RubyOpt::IR::Instruction`. Each has `opcode` (Symbol), `operands` (Array), `line` (Integer or nil). `function.splice_instructions!(range, replacement)` is the documented mutation API (used by ArithReassoc and others).
- InliningPass runs first in `Pipeline.default` and is the current source of the pattern. After inlining, the stash slot appears as `setlocal_WC_0 n@K` followed by `getlocal_WC_0 n@K` where K is a slot index added to the caller's local table via `LocalTable#grow!`.

---

## Task 1: Create `DeadStashElimPass` with tests (TDD)

**Files:**
- Create: `optimizer/lib/ruby_opt/passes/dead_stash_elim_pass.rb`
- Create: `optimizer/test/passes/dead_stash_elim_pass_test.rb`

### Step 1: Write the failing tests

Create `optimizer/test/passes/dead_stash_elim_pass_test.rb`:

```ruby
# frozen_string_literal: true
require "test_helper"
require "ruby_opt/codec"
require "ruby_opt/log"
require "ruby_opt/ir/function"
require "ruby_opt/ir/instruction"
require "ruby_opt/passes/dead_stash_elim_pass"

class DeadStashElimPassTest < Minitest::Test
  # Build a minimal IR::Function whose body is the given array of Instruction
  # objects. Slot `n@1` is in the local table so set/get-local operands resolve.
  def build_fn(insts, local_table: [{ name: :n, type: :local }])
    fn = RubyOpt::IR::Function.new(
      type: :method, name: "f",
      path: "/t", first_lineno: 1,
      local_table: local_table,
      instructions: insts,
      children: [],
    )
    fn
  end

  def inst(opcode, operands, line: 1)
    RubyOpt::IR::Instruction.new(opcode: opcode, operands: operands, line: line)
  end

  def apply(fn, log: RubyOpt::Log.new)
    RubyOpt::Passes::DeadStashElimPass.new.apply(fn, type_env: nil, log: log)
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

    opcodes = fn.instructions.map(&:opcode)
    assert_equal %i[putobject leave], opcodes
    refute_empty log.for_pass(:dead_stash_elim).select { |e| e.reason == :dead_stash_eliminated }
  end

  def test_end_to_end_preserves_value_through_dropped_pair
    src = "def f; 42; end; f"
    ir = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    f = find_iseq(ir, "f")
    # Synthesise a stash pair around the leading producer.
    # Grow the local table by one slot at level 0.
    f.local_table << { name: :stash, type: :local }
    stash_idx = f.local_table.size  # 1-indexed in disasm but operand is the slot count
    # Splice setlocal/getlocal after the first non-trace instruction.
    producer_idx = f.instructions.find_index { |i| i.opcode == :putobject || i.opcode.to_s.start_with?("putobject") }
    skip("no producer") unless producer_idx
    f.instructions.insert(producer_idx + 1,
      RubyOpt::IR::Instruction.new(opcode: :setlocal_WC_0, operands: [stash_idx], line: 1),
      RubyOpt::IR::Instruction.new(opcode: :getlocal_WC_0, operands: [stash_idx], line: 1),
    )

    # Sanity: pre-pass the stash pair is present.
    assert_includes f.instructions.map(&:opcode), :setlocal_WC_0
    assert_includes f.instructions.map(&:opcode), :getlocal_WC_0

    apply(f)

    # Post-pass the stash pair is gone.
    refute_includes f.instructions.map(&:opcode), :setlocal_WC_0
    refute_includes f.instructions.map(&:opcode), :getlocal_WC_0

    loaded = RubyVM::InstructionSequence.load_from_binary(RubyOpt::Codec.encode(ir))
    assert_equal 42, loaded.eval
  end

  def test_leaves_pair_when_second_reader_exists
    fn = build_fn([
      inst(:putobject, [42]),
      inst(:setlocal_WC_0, [1]),
      inst(:getlocal_WC_0, [1]),
      inst(:getlocal_WC_0, [1]),   # second reader — must block
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
      inst(:getlocal_WC_0, [1]),   # later reader elsewhere in iseq
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
      inst(:setlocal_WC_0, [1]),   # later writer elsewhere in iseq
      inst(:leave, []),
    ])
    before = fn.instructions.map(&:opcode)
    apply(fn)
    assert_equal before, fn.instructions.map(&:opcode)
  end

  def test_leaves_pair_when_levels_differ
    fn = build_fn([
      inst(:putobject, [42]),
      inst(:setlocal, [1, 1]),     # level 1
      inst(:getlocal, [1, 0]),     # level 0
      inst(:leave, []),
    ])
    before = fn.instructions.map(&:opcode)
    apply(fn)
    assert_equal before, fn.instructions.map(&:opcode)
  end

  def test_leaves_pair_when_shorthand_and_explicit_mix
    # Explicit non-goal from the spec: WC_0 shorthand on one side and
    # explicit level-0 on the other is not matched.
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
      inst(:putobject, [1]),       # anything between the two
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
    opcodes = fn.instructions.map(&:opcode)
    assert_equal %i[putobject pop putobject leave], opcodes
    assert_equal 2, log.for_pass(:dead_stash_elim)
                     .count { |e| e.reason == :dead_stash_eliminated }
  end

  def test_rewrite_count_increments_on_fold
    fn = build_fn([
      inst(:putobject, [42]),
      inst(:setlocal_WC_0, [1]),
      inst(:getlocal_WC_0, [1]),
      inst(:leave, []),
    ])
    log = RubyOpt::Log.new
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
```

Check the existing `IR::Function` constructor signature before running — if the keyword argument names or requirements differ, adjust the `build_fn` helper to match. Look at `optimizer/lib/ruby_opt/ir/function.rb` for the canonical shape. Do NOT change the function class; adapt the test helper.

### Step 2: Run the tests to verify they fail

```
mcp__ruby-bytecode__run_optimizer_tests
  test_filter: "test/passes/dead_stash_elim_pass_test.rb"
```

Expected: `cannot load such file -- ruby_opt/passes/dead_stash_elim_pass` or similar.

### Step 3: Implement the pass

Create `optimizer/lib/ruby_opt/passes/dead_stash_elim_pass.rb`:

```ruby
# frozen_string_literal: true
require "ruby_opt/pass"

module RubyOpt
  module Passes
    # Peephole: drop adjacent `setlocal X; getlocal X` pairs where slot X has
    # no other references at the matching level in the same function.
    #
    # The producer that fed the setlocal has already pushed its value onto
    # the operand stack; the getlocal was just reading it back. Dropping
    # both leaves the value where subsequent instructions expect it.
    #
    # Narrow by design:
    #   - strictly adjacent (no tolerated instructions between)
    #   - same slot (operand[0] of both)
    #   - same level (both WC_0 shorthand, OR both explicit with equal level)
    #   - no other setlocal/getlocal references this slot+level anywhere in
    #     function.instructions
    #
    # Mixed shorthand+explicit-level-0 is explicitly NOT matched (documented
    # non-goal in the spec).
    class DeadStashElimPass < RubyOpt::Pass
      SETLOCAL_OPCODES = %i[setlocal setlocal_WC_0].freeze
      GETLOCAL_OPCODES = %i[getlocal getlocal_WC_0].freeze
      LOCAL_OPCODES    = (SETLOCAL_OPCODES + GETLOCAL_OPCODES).freeze

      def name
        :dead_stash_elim
      end

      def apply(function, type_env:, log:, **_extras)
        insts = function.instructions
        return unless insts && insts.size >= 2

        # Collect all candidate pair positions (indices into insts where a
        # matching pair begins). Don't splice during the scan — splicing
        # invalidates subsequent indices.
        candidates = []
        i = 0
        while i < insts.size - 1
          a = insts[i]
          b = insts[i + 1]
          if matching_pair?(a, b) && slot_has_no_other_refs?(insts, i, a)
            candidates << i
            i += 2 # skip past the pair — don't overlap pairs
          else
            i += 1
          end
        end

        return if candidates.empty?

        # Splice from the end so earlier indices stay valid.
        candidates.reverse_each do |idx|
          function.splice_instructions!(idx..idx + 1, [])
          log.rewrite(
            pass: :dead_stash_elim, reason: :dead_stash_eliminated,
            file: function.path, line: insts_line_at(function, idx),
          )
        end
      end

      private

      # Does this setlocal/getlocal pair match on slot and level?
      def matching_pair?(a, b)
        return false unless SETLOCAL_OPCODES.include?(a.opcode)
        return false unless GETLOCAL_OPCODES.include?(b.opcode)
        return false unless a.operands[0] == b.operands[0]

        a_wc0 = a.opcode == :setlocal_WC_0
        b_wc0 = b.opcode == :getlocal_WC_0
        # Both WC_0, or both explicit with matching level.
        if a_wc0 && b_wc0
          true
        elsif !a_wc0 && !b_wc0
          a.operands[1] == b.operands[1]
        else
          false
        end
      end

      # Does any other setlocal/getlocal in the function reference the same
      # slot + level as the candidate pair? Excludes the two pair instructions
      # themselves.
      def slot_has_no_other_refs?(insts, pair_idx, pair_first)
        slot = pair_first.operands[0]
        level = pair_first.opcode == :setlocal_WC_0 ? 0 : pair_first.operands[1]
        insts.each_with_index.none? do |inst, j|
          next false if j == pair_idx || j == pair_idx + 1
          next false unless LOCAL_OPCODES.include?(inst.opcode)
          inst_slot  = inst.operands[0]
          inst_level = inst.opcode.to_s.end_with?("_WC_0") ? 0 : inst.operands[1]
          inst_slot == slot && inst_level == level
        end
      end

      # Best-effort line number for the log entry. Falls back to the
      # function's first line if the instruction didn't carry one.
      def insts_line_at(function, idx)
        (function.instructions[idx]&.line) || function.first_lineno || 0
      end
    end
  end
end
```

Notes:
- If `IR::Instruction#operands` uses a different access pattern (e.g. a separate `level` reader), adjust the private helpers to match. Inspect `optimizer/lib/ruby_opt/ir/instruction.rb` before implementing. Do NOT change the Instruction class.
- If `Function#splice_instructions!` does not exist, grep for how `ArithReassocPass` mutates the instruction list (it uses the same API). If the API differs, follow that.

### Step 4: Run the tests to verify they pass

Same command as Step 2. Expected: all 10 tests pass.

### Step 5: Run the full optimizer test suite

```
mcp__ruby-bytecode__run_optimizer_tests
  (no test_filter)
```

Expected: all green. Previous count was 380; with 10 new tests expect 390.

### Step 6: Commit

```bash
jj commit -m "feat(dead_stash_elim): drop adjacent setlocal/getlocal pairs with unique slot

New peephole pass. For each adjacent \`setlocal X; getlocal X\` where
slot X has no other references at that level in the function, drop
both instructions. The producer's value stays on the operand stack
for subsequent instructions.

Closes the inliner-v3 arg-stash round-trip after arith/identity have
folded the inlined body. Does NOT implement general DSE — that's
tracked as a separate TODO.

Spec: docs/superpowers/specs/2026-04-23-pass-dead-stash-elim-design.md" \
  optimizer/lib/ruby_opt/passes/dead_stash_elim_pass.rb \
  optimizer/test/passes/dead_stash_elim_pass_test.rb
```

---

## Task 2: Register in `Pipeline.default` + add pass description

**Files:**
- Modify: `optimizer/lib/ruby_opt/pipeline.rb`
- Modify: `optimizer/lib/ruby_opt/demo/markdown_renderer.rb`

### Step 1: Require + register

Open `optimizer/lib/ruby_opt/pipeline.rb`. At the top of the file, alongside the other `require "ruby_opt/passes/..."` lines (there are 7 of them currently), add:

```ruby
require "ruby_opt/passes/dead_stash_elim_pass"
```

In `Pipeline.default`, insert the new pass directly after `InliningPass`:

```ruby
def self.default
  new([
    Passes::InliningPass.new,
    Passes::DeadStashElimPass.new,   # new — peephole cleanup of inliner stash
    Passes::ArithReassocPass.new,
    # ... existing comments and entries below ...
  ])
end
```

Preserve all existing comments on other entries.

### Step 2: Add pass description for demo rendering

Open `optimizer/lib/ruby_opt/demo/markdown_renderer.rb`. The file has a `PASS_DESCRIPTIONS` hash (around line 11). Add a new entry:

```ruby
dead_stash_elim:  "Drop `setlocal X; getlocal X` pairs whose slot has no other refs.",
```

Keep the existing entries in the same hash; preserve their alignment style.

### Step 3: Run the full test suite

```
mcp__ruby-bytecode__run_optimizer_tests
  (no test_filter)
```

Expected: all 390 tests still pass. (The new pass is in `Pipeline.default` but its gate is narrow; it never fires on existing test inputs.)

### Step 4: Commit

```bash
jj commit -m "feat(pipeline): register DeadStashElimPass after InliningPass

Cleans up the inliner's argument-stash round-trip so the producer
value is exposed directly to following instructions in the same
pipeline run (via fixed-point iteration)." \
  optimizer/lib/ruby_opt/pipeline.rb \
  optimizer/lib/ruby_opt/demo/markdown_renderer.rb
```

---

## Task 3: Regenerate `polynomial.md`

**Files:**
- Modify: `docs/demo_artifacts/polynomial.md`

### Step 1: Regen in Docker

```bash
docker run --rm \
  -v "$(pwd)/optimizer:/w" \
  -v "$(pwd)/docs:/docs" \
  -w /w \
  ruby:4.0.2 \
  bash -c "bundle config set --local path vendor/bundle >/dev/null && bundle install --quiet && bundle exec ruby -Ilib bin/demo polynomial"
```

Expected: `wrote /docs/demo_artifacts/polynomial.md`.

### Step 2: Inspect the diff

```bash
jj diff docs/demo_artifacts/polynomial.md
```

Expected semantic changes:

- Both `poly.compute(42)` and `poly.compute(0)` call sites drop the
  `setlocal n@1; getlocal n@1` (and `setlocal n@2; getlocal n@1`
  depending on the else-branch shape) round-trip. The compute-call
  sequence shrinks.
- Header benchmark ratio likely improves (not strictly — depends on
  the inlined call site's share of runtime; may be noise).
- Convergence count may drop (3 → 2 iterations) or stay at 3. Don't
  predict.
- `inlining` walkthrough slide is unchanged (the stash was already
  there). The new `dead_stash_elim` entry in `PASS_DESCRIPTIONS`
  isn't surfaced as a walkthrough slide unless the fixture's
  `walkthrough.yml` lists it. The polynomial YAML will NOT be
  updated in this task — that's a separate choice about whether we
  want a slide for this pass in the talk. (Defer.)

Expected non-semantic changes:
- Benchmark-line noise (masked by `rake demo:verify`).

If you see anything else, the regen happened outside Docker — re-run
with the full command.

### Step 3: Commit

```bash
jj commit -m "demo(artifacts): polynomial call sites drop inliner stash pair

DeadStashElimPass folds the argument-stash round-trip at each inlined
call site. compute(42) and compute(0) both shrink." \
  docs/demo_artifacts/polynomial.md
```

### Step 4 (optional, defer decision to user): update walkthrough YAML

Skip unless explicitly asked. If wanted: edit `optimizer/examples/polynomial.walkthrough.yml` to add `- dead_stash_elim` between `- inlining` and `- const_fold_tier2` in the `walkthrough:` list, re-run Step 1, re-commit the artifact. NOT part of this plan's default flow.

---

## Task 4: TODO updates

**Files:**
- Modify: `docs/TODO.md`

### Step 1: Strike the polynomial-cascade-gap bullet

Find the "Polynomial-demo cascade gaps (filed 2026-04-22)" section (around line 132). The first bullet starts with `**InliningPass v3 leaves a redundant setlocal/getlocal round-trip at the stash site.**`. Replace that entire bullet with:

```
- ~~**InliningPass v3 leaves a redundant `setlocal/getlocal` round-trip
  at the stash site.**~~ **Shipped 2026-04-23** as `DeadStashElimPass`.
  Spec: `docs/superpowers/specs/2026-04-23-pass-dead-stash-elim-design.md`.
  Plan: `docs/superpowers/plans/2026-04-23-pass-dead-stash-elim.md`.
  Narrow peephole: drops strictly-adjacent `setlocal X; getlocal X`
  pairs when slot X has no other reference at the matching level in
  the function. Runs directly after InliningPass in
  `Pipeline.default`, so the newly exposed producer cascades through
  arith_reassoc and the const-fold tiers within the same fixed-point
  iteration.
```

### Step 2: Add a new TODO for full DSE

Under "Exploratory, not yet on any roadmap" (around line 275), append a new bullet:

```
- **Full dead-store elimination.** DeadStashElimPass (shipped
  2026-04-23) handles a narrow peephole — strictly adjacent
  `setlocal X; getlocal X` with a single-use slot. A proper DSE pass
  would remove any `setlocal X` whose target has no subsequent read
  before the next `setlocal X` (classic DSE). That's a dataflow
  problem, not a peephole, and requires reasoning about control flow
  (branches, loops, catch tables) to determine "subsequent read."
  Not needed for any current fixture, but would generalise beyond
  inliner-emitted patterns once a future pass creates other dead
  stores. Bigger project — probably its own multi-session spec.
```

### Step 3: Bump the "Last updated" line

Find:

```
Last updated: 2026-04-23 (arith_reassoc v4.1 exact-divisibility fold
shipped; polynomial demo now collapses `(n*2*SCALE/12)+0` end-to-end
to `n` via the cascade through IdentityElim v1).
```

Replace with:

```
Last updated: 2026-04-23 (DeadStashElimPass shipped — inliner's
argument-stash round-trip now eliminated, exposing producers to the
arith/const-fold cascade).
```

### Step 4: Commit

```bash
jj commit -m "docs(todo): strike inliner-stash bullet — shipped as DeadStashElimPass

Also add a new TODO entry for full dead-store elimination (the
bigger, dataflow-based generalisation)." docs/TODO.md
```

---

## Final verification

- [ ] Full optimizer test suite green (`mcp__ruby-bytecode__run_optimizer_tests`, no filter).
- [ ] `docs/demo_artifacts/polynomial.md` shows the stash pair dropped at both call sites; no non-semantic path/platform diff.
- [ ] `jj log -r 'c24c445..@-' --no-graph --template 'description.first_line() ++ "\n"'` includes the four new commits on top of the arith_reassoc v4.1 work: feat(dead_stash_elim), feat(pipeline), demo(artifacts), docs(todo).

---

## Self-review notes

- No placeholders — every step shows the exact code or command.
- Pass name and reason symbol consistent across tasks: `DeadStashElimPass`, `#name` returns `:dead_stash_elim`, log reason `:dead_stash_eliminated`.
- Task 1 tests cover both positive and negative shapes from the spec (second reader, later reader, later writer, level mismatch, shorthand/explicit mix, non-adjacent).
- Regeneration command matches the one used for the arith_reassoc v4.1 artifact regen earlier today (which succeeded).
- Explicit guidance to inspect `IR::Function` / `IR::Instruction` before implementing so the test helper and pass code match the canonical API — avoiding drift if the ctor signatures differ from my assumptions.
