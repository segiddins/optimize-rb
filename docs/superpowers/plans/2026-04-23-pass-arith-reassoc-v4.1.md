# ArithReassoc v4.1 — exact-divisibility fold (implementation plan)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Teach `ArithReassocPass`'s `:ordered` walker to fold `x * a / b` to `x * (a/b)` when `b | a`, unblocking the polynomial demo's final cascade (`n * 12 / 12 → n * 1 → n` via IdentityElim v1).

**Architecture:** One new case in `try_rewrite_chain_ordered`'s literal branch, between the existing same-op-run and cross-op-commit cases. Gated on `acc_op == :opt_mult && e[:op] == :opt_div && associative && acc % e[:value] == 0`. Logs via `Log#rewrite` with new reason `:exact_divisibility_fold`. One-direction only; `/ then *` is unsound under integer truncation.

**Tech Stack:** Ruby, Minitest. No new deps.

**Spec:** `docs/superpowers/specs/2026-04-23-pass-arith-reassoc-v4.1-design.md`.

---

## File Structure

**Modified:**
- `optimizer/lib/ruby_opt/passes/arith_reassoc_pass.rb` — add case B2 in the `:ordered` walker's literal branch; capture `chain_line` is already in scope. No other pass-file changes.
- `optimizer/test/passes/arith_reassoc_pass_test.rb` — append new test cases at the bottom of the class.
- `docs/demo_artifacts/polynomial.md` — regenerated with the additional arith_reassoc + identity_elim cascade slides showing real diffs.
- `docs/TODO.md` — strike the v4.1 entry, add shipped note.

**Created:**
- (none)

---

## Shared context

- Ruby 4.0 in Docker. Tests via `mcp__ruby-bytecode__run_optimizer_tests` (mounts `optimizer/`). Arbitrary Ruby via `mcp__ruby-bytecode__run_ruby` (sandboxed — no repo mount).
- Demo artifact regeneration must happen in Docker with both `optimizer/` and `docs/` mounted so disasm paths produce `/w/examples/<fixture>.rb` rather than a macOS path. Command:
  ```
  docker run --rm \
    -v "$(pwd)/optimizer:/w" \
    -v "$(pwd)/docs:/docs" \
    -w /w \
    ruby:4.0.2 \
    bash -c "bundle config set --local path vendor/bundle >/dev/null && bundle install --quiet && bundle exec ruby -Ilib bin/demo polynomial"
  ```
- jj, not git. Use `jj commit -m "msg" <files>` with explicit paths.
- `Log#rewrite` (shipped 2026-04-23) bumps the fixed-point rewrite counter; `Log#skip` does not. New rewrite reasons go through `rewrite`.
- The `:no_change` guard in `try_rewrite_chain_ordered` compares input literal count to output literal count. B2 strictly decreases output count — the guard won't trip.

---

## Task 1: Implement the exact-divisibility fold

**Files:**
- Modify: `optimizer/lib/ruby_opt/passes/arith_reassoc_pass.rb` (insert one `elsif` case around line 249, plus a log call).
- Test: `optimizer/test/passes/arith_reassoc_pass_test.rb` (append new test cases).

### Step 1: Write the failing tests

Append to `optimizer/test/passes/arith_reassoc_pass_test.rb`, inside the `ArithReassocPassTest` class (before the final `end`):

```ruby
# ---- v4.1 exact-divisibility fold ----

def test_exact_divisibility_fold_x_times_k_over_k
  src = "def f(x); x * 12 / 12; end; f(7)"
  ir = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
  ot = ir.misc[:object_table]
  f = find_iseq(ir, "f")
  log = RubyOpt::Log.new
  RubyOpt::Passes::ArithReassocPass.new.apply(f, type_env: nil, log: log, object_table: ot)

  # Expect `x * 1`: one opt_mult, zero opt_div, and a literal 1 in the stream.
  assert_equal 1, f.instructions.count { |i| i.opcode == :opt_mult }
  assert_equal 0, f.instructions.count { |i| i.opcode == :opt_div }
  refute_nil f.instructions.find { |i| RubyOpt::Passes::LiteralValue.read(i, object_table: ot) == 1 }

  # And a log entry records the exact-divisibility step.
  refute_empty log.for_pass(:arith_reassoc).select { |e| e.reason == :exact_divisibility_fold },
               "expected at least one :exact_divisibility_fold log entry"

  loaded = RubyVM::InstructionSequence.load_from_binary(RubyOpt::Codec.encode(ir))
  assert_equal 7, loaded.eval
end

def test_exact_divisibility_fold_x_times_12_over_4
  src = "def f(x); x * 12 / 4; end; f(5)"
  ir = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
  ot = ir.misc[:object_table]
  f = find_iseq(ir, "f")
  RubyOpt::Passes::ArithReassocPass.new.apply(f, type_env: nil, log: RubyOpt::Log.new, object_table: ot)

  assert_equal 1, f.instructions.count { |i| i.opcode == :opt_mult }
  assert_equal 0, f.instructions.count { |i| i.opcode == :opt_div }
  refute_nil f.instructions.find { |i| RubyOpt::Passes::LiteralValue.read(i, object_table: ot) == 3 }

  loaded = RubyVM::InstructionSequence.load_from_binary(RubyOpt::Codec.encode(ir))
  assert_equal 15, loaded.eval
end

def test_exact_divisibility_cascades_through_same_op_run
  src = "def f(x); x * 2 * 6 / 4; end; f(5)"
  ir = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
  ot = ir.misc[:object_table]
  f = find_iseq(ir, "f")
  RubyOpt::Passes::ArithReassocPass.new.apply(f, type_env: nil, log: RubyOpt::Log.new, object_table: ot)

  # `2 * 6` coalesces to 12 via the same-op run, then `12 / 4` folds to 3.
  assert_equal 1, f.instructions.count { |i| i.opcode == :opt_mult }
  assert_equal 0, f.instructions.count { |i| i.opcode == :opt_div }
  refute_nil f.instructions.find { |i| RubyOpt::Passes::LiteralValue.read(i, object_table: ot) == 3 }

  loaded = RubyVM::InstructionSequence.load_from_binary(RubyOpt::Codec.encode(ir))
  assert_equal 15, loaded.eval
end

def test_non_exact_divisibility_preserves_chain
  src = "def f(x); x * 12 / 5; end; f(5)"
  ir = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
  ot = ir.misc[:object_table]
  f = find_iseq(ir, "f")
  before_opcodes = f.instructions.map(&:opcode)
  log = RubyOpt::Log.new
  RubyOpt::Passes::ArithReassocPass.new.apply(f, type_env: nil, log: log, object_table: ot)

  # The chain can't fold (5 does not divide 12). Expect unchanged opcodes and
  # no :exact_divisibility_fold entry. The existing :no_change pathway fires.
  assert_equal before_opcodes, f.instructions.map(&:opcode)
  assert_empty log.for_pass(:arith_reassoc).select { |e| e.reason == :exact_divisibility_fold }
end

def test_div_then_mult_not_folded
  # `x / 4 * 12` is NOT equivalent to `x * 3` under integer truncation
  # (e.g. x=5: (5/4)*12 = 12; 5*3 = 15). Regression guard.
  src = "def f(x); x / 4 * 12; end; f(20)"
  ir = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
  ot = ir.misc[:object_table]
  f = find_iseq(ir, "f")
  before_opcodes = f.instructions.map(&:opcode)
  log = RubyOpt::Log.new
  RubyOpt::Passes::ArithReassocPass.new.apply(f, type_env: nil, log: log, object_table: ot)

  assert_equal before_opcodes, f.instructions.map(&:opcode),
               "div-then-mult must not be folded (unsound under integer truncation)"
  assert_empty log.for_pass(:arith_reassoc).select { |e| e.reason == :exact_divisibility_fold }
end

def test_exact_divisibility_zero_accumulator_preserves_fold
  # `x * 0 * 5 / 5` collapses the mult run to acc=0 (via existing same-op
  # combiner), then folds `0 / 5 = 0`. Result: `x * 0`. The `x * 0 → 0`
  # absorbing-zero rule is separate (IdentityElim v2 future work) — just
  # assert our fold happened and produced `x * 0`.
  src = "def f(x); x * 0 * 5 / 5; end; f(7)"
  ir = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
  ot = ir.misc[:object_table]
  f = find_iseq(ir, "f")
  RubyOpt::Passes::ArithReassocPass.new.apply(f, type_env: nil, log: RubyOpt::Log.new, object_table: ot)

  assert_equal 1, f.instructions.count { |i| i.opcode == :opt_mult }
  assert_equal 0, f.instructions.count { |i| i.opcode == :opt_div }
  refute_nil f.instructions.find { |i| RubyOpt::Passes::LiteralValue.read(i, object_table: ot) == 0 }

  loaded = RubyVM::InstructionSequence.load_from_binary(RubyOpt::Codec.encode(ir))
  assert_equal 0, loaded.eval
end
```

### Step 2: Run tests to verify they fail

Use `mcp__ruby-bytecode__run_optimizer_tests` with `test_filter: "test/passes/arith_reassoc_pass_test.rb"`.

Expected: the new `test_exact_divisibility_*` cases fail (`x * 12 / 12` currently emits `x * 12 / 12` unchanged — no fold). `test_non_exact_divisibility_preserves_chain` and `test_div_then_mult_not_folded` likely pass already (the walker does nothing on those today). `test_exact_divisibility_zero_accumulator_preserves_fold` likely fails — today the walker commits `0` and `5` separately without folding `/ 5`.

### Step 3: Implement the walker branch

Open `optimizer/lib/ruby_opt/passes/arith_reassoc_pass.rb`. Find the literal branch of `stream.each` inside `try_rewrite_chain_ordered` (around line 244-262). The current shape:

```ruby
stream.each do |e|
  if e[:is_literal]
    if acc.nil?
      acc = e[:value]
      acc_op = e[:op]
    elsif acc_op == e[:op] && (associative || emitted.empty?)
      # Same-op literal run: combine into the accumulator using the
      # group's run combiner. For non-associative groups this branch
      # is gated on `emitted.empty?` — once a non-literal has been
      # emitted, `(y op lit1) op lit2 ≠ y op (lit1 combiner lit2)`
      # and we must commit each literal on its own.
      acc = acc.send(run_combiner, e[:value])
    else
      # Cross-op boundary between literals, or post-non-literal run in
      # a non-associative group: commit and start fresh.
      commit.call
      acc = e[:value]
      acc_op = e[:op]
    end
```

Add a new `elsif` between the same-op-run branch and the final `else`:

```ruby
elsif acc_op == :opt_mult && e[:op] == :opt_div &&
      associative && acc.is_a?(Integer) && acc % e[:value] == 0
  # v4.1 exact-divisibility fold: (x * a) / b with b | a rewrites to
  # x * (a/b). Safe under integer truncation because `x * a` loses no
  # information before the division; `(a/b) * b == a` exactly.
  # Unsound in the reverse direction (`x / a * b`) — see spec for why.
  acc = acc / e[:value]
  # acc_op stays :opt_mult; the divisor is absorbed.
  log.rewrite(pass: :arith_reassoc, reason: :exact_divisibility_fold,
              file: function.path, line: chain_line)
```

The full resulting block:

```ruby
stream.each do |e|
  if e[:is_literal]
    if acc.nil?
      acc = e[:value]
      acc_op = e[:op]
    elsif acc_op == e[:op] && (associative || emitted.empty?)
      acc = acc.send(run_combiner, e[:value])
    elsif acc_op == :opt_mult && e[:op] == :opt_div &&
          associative && acc.is_a?(Integer) && acc % e[:value] == 0
      acc = acc / e[:value]
      log.rewrite(pass: :arith_reassoc, reason: :exact_divisibility_fold,
                  file: function.path, line: chain_line)
    else
      commit.call
      acc = e[:value]
      acc_op = e[:op]
    end
  else
    if !acc.nil? && (acc_op != e[:op] || !commutative)
      commit.call
    end
    emitted << e
  end
end
```

### Step 4: Run the new tests to verify they pass

Same command as Step 2. Expected: all six new tests pass.

### Step 5: Run the full arith_reassoc test suite

Same command as Step 2 (runs the entire file). Expected: every pre-existing test still passes — the new branch never fires on any input that doesn't match its narrow gate.

### Step 6: Run the full optimizer test suite

Use `mcp__ruby-bytecode__run_optimizer_tests` with no `test_filter`. Expected: all tests green (should be 380 runs, up from 374 — six new cases).

### Step 7: Commit

```bash
jj commit -m "feat(arith_reassoc): v4.1 exact-divisibility fold

New case in :ordered walker: when acc holds a literal at op :opt_mult
and the next literal has op :opt_div, and acc is divisible by the
divisor, absorb the divisor into the accumulator. Unlocks the final
step of the polynomial demo cascade (n * 12 / 12 -> n * 1, then
IdentityElim v1 strips *1 -> n).

One direction only; /-then-* is unsound under integer truncation
because x / a loses information that x * (b/a) cannot recover.

Spec: docs/superpowers/specs/2026-04-23-pass-arith-reassoc-v4.1-design.md" \
  optimizer/lib/ruby_opt/passes/arith_reassoc_pass.rb \
  optimizer/test/passes/arith_reassoc_pass_test.rb
```

---

## Task 2: Regenerate the polynomial demo artifact

**Files:**
- Modify: `docs/demo_artifacts/polynomial.md`

### Step 1: Regenerate in Docker

From the repo root:

```bash
docker run --rm \
  -v "$(pwd)/optimizer:/w" \
  -v "$(pwd)/docs:/docs" \
  -w /w \
  ruby:4.0.2 \
  bash -c "bundle config set --local path vendor/bundle >/dev/null && bundle install --quiet && bundle exec ruby -Ilib bin/demo polynomial"
```

Expected: `wrote /docs/demo_artifacts/polynomial.md` and exit 0.

### Step 2: Inspect the diff

```bash
jj diff docs/demo_artifacts/polynomial.md
```

Expected semantic changes:

- Header ratio improves (probably 1.09x → a higher number; don't assert a specific value, benchmarks vary).
- Header `Converged in N iterations` line may drop (3 → 2) since the cascade lands sooner.
- `arith_reassoc` walkthrough slide: the `compute` method iseq no longer ends with `putobject 12; opt_mult; putobject 12; opt_div; putobject_INT2FIX_0_; opt_plus`. Instead it should show the cascade landing — either ending at `putobject 1; opt_mult; putobject_INT2FIX_0_; opt_plus` (after arith_reassoc alone) or further reduced by the prefix `[inlining, arith_reassoc]` depending on walkthrough order.
- `identity_elim` walkthrough slide: shows `opt_mult` being stripped. Previously `(no change)`.
- `after_full` iseq for `compute`: previously ended `getlocal; putobject 12; opt_mult; putobject 12; opt_div; putobject_INT2FIX_0_; opt_plus; leave`. New shape ends with the mult-and-div gone: something like `getlocal; putobject_INT2FIX_0_; opt_plus; leave`. The trailing `+ 0` remains pending IdentityElim v2.

Only benchmark-line noise and the above semantic changes should appear. If anything else changes (disasm paths, platform strings), the regen happened outside Docker — re-run.

### Step 3: Commit

```bash
jj commit -m "demo(artifacts): polynomial cascade lands x*12/12 -> x

arith_reassoc v4.1 exact-divisibility fold, combined with IdentityElim
v1's x*1 -> x, now collapses the polynomial fixture's mult/div chain
end-to-end. arith_reassoc and identity_elim walkthrough slides gain
real diffs. Trailing + 0 still remains (separate IdentityElim v2
future work)." docs/demo_artifacts/polynomial.md
```

---

## Task 3: Update TODO.md

**Files:**
- Modify: `docs/TODO.md`

### Step 1: Strike the v4.1 entry

Open `docs/TODO.md`. Find the "ArithReassoc v4.1 — exact-divisibility folds (`x*6/2 → x*3`)" bullet under "Refinements of shipped work — Filed in session memory / pass-identity-elim-design but not yet picked up" (near line 211).

Replace that bullet with:

```
- ~~**ArithReassoc v4.1** — exact-divisibility folds (`x*6/2 → x*3`).
  Requires divisibility tracking in the `:ordered` walker.~~
  **Shipped 2026-04-23.** Spec:
  `docs/superpowers/specs/2026-04-23-pass-arith-reassoc-v4.1-design.md`.
  Plan: `docs/superpowers/plans/2026-04-23-pass-arith-reassoc-v4.1.md`.
  New case in `:ordered` walker (mult→div direction only; reverse is
  unsound). Unblocks the polynomial demo's final cascade:
  `n * 12 / 12 → n * 1 → n` via IdentityElim v1's `x * 1` rule,
  happening automatically in one pipeline run thanks to fixed-point
  iteration.
```

### Step 2: Bump the "Last updated" line

Find:

```
Last updated: 2026-04-23 (pipeline fixed-point iteration shipped — cascades
across passes now automatic, phase-ordering concerns retired wholesale).
```

Replace with:

```
Last updated: 2026-04-23 (arith_reassoc v4.1 exact-divisibility fold
shipped; polynomial demo now collapses mult/div chain end-to-end).
```

### Step 3: Commit

```bash
jj commit -m "docs(todo): strike arith_reassoc v4.1 — shipped 2026-04-23" docs/TODO.md
```

---

## Final verification

- [ ] Full optimizer test suite green (`mcp__ruby-bytecode__run_optimizer_tests` with no filter).
- [ ] `docs/demo_artifacts/polynomial.md` shows the new cascade with no non-semantic diff (paths still `/w/examples/polynomial.rb`).
- [ ] `jj log -r 'c24c445..@-' --no-graph --template 'description.first_line() ++ "\n"'` shows three new commits on top of the fixed-point-iteration work: feat(arith_reassoc), demo(artifacts), docs(todo).

---

## Self-review notes

- Every step has concrete code or commands — no placeholders.
- Method and reason names consistent: `:exact_divisibility_fold`, `Log#rewrite`, `try_rewrite_chain_ordered`.
- Test cases cover: positive fold (three variants), negative preservation (non-exact, div-then-mult), edge case (zero accumulator).
- Div-then-mult regression guard explicitly prevents a future contributor from adding the unsound symmetric direction.
- Regeneration command matches the one the controller used successfully earlier today.
