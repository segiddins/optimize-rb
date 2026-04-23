# Pipeline fixed-point iteration — design

Status: draft, 2026-04-23

## Motivation

Pipeline.default runs each pass once in a fixed order. This makes cascades
across passes order-sensitive: if pass A produces a literal that pass B
could fold, and A runs after B, the fold is missed until some future
pipeline run that never happens. The `polynomial` fixture surfaces this
concretely:

- ArithReassoc runs before ConstFoldTier2 rewrites `SCALE → 6`, so it
  sees `n * 2 * <getconstant> / 12`, can't reassociate across the
  non-literal, and gives up.
- IdentityElim runs once at the end; it can't see a rewrite produced by
  ArithReassoc in a *later* conceptual sweep.

Hand-tuning the order works fixture-by-fixture but keeps breaking: every
new program finds a new ordering gap. The standard compiler answer is to
iterate to convergence. This spec adopts that pattern.

## Scope

Wrap `Pipeline#run` in a per-function fixed-point loop over iterative
passes. `InliningPass` stays one-shot (runs once per function, on
iteration 1); the peephole passes iterate until a full sweep records no
new log entries.

**Non-goals** (see "Out of scope" below): changing any individual pass's
internal logic; making InliningPass iterative; rewriting the walkthrough
YAML sidecars; altering `DisasmNormalizer`.

## Mechanism

### Pass classification

`RubyOpt::Pass` (base class, `optimizer/lib/ruby_opt/pass.rb`) gains a
`one_shot?` predicate, default `false`. `InliningPass` overrides to
`true`. No other shipped pass needs the override.

### Log rewrite/skip split (prerequisite)

`Log#skip` today records both skipped-optimization entries (e.g.,
`:unsafe_divisor`, `:chain_too_short`, `:no_change`) and successful
rewrite entries (e.g., `:reassociated`, `:folded`). These must be
distinguished for fixed-point detection — a sweep that records only
skip entries made no IR changes and should terminate the loop.

Add `Log#rewrite(pass:, reason:, file:, line:)` alongside `skip`. It
appends the same `Entry` shape to `@entries` (so existing `for_pass` /
`entries` consumers are unaffected) AND increments an internal
`@rewrite_count` integer. `Log#rewrite_count` returns it.

Migrate each pass's known-rewrite call sites from `skip` to `rewrite`
based on the reason taxonomy. Skip entries (decisions *not* to rewrite)
stay on `skip`.

### Per-function loop in `Pipeline#run`

Current structure: `each_function { |fn| passes.each { |p| p.apply(fn, …) } }`.

New structure per function:

1. Partition `@passes` into `one_shot` and `iterative` by `one_shot?`.
2. Run each `one_shot` pass once.
3. Enter loop, bounded by `MAX_ITERATIONS = 8`:
   a. Snapshot `log.rewrite_count` before the sweep.
   b. Run each `iterative` pass once.
   c. If `log.rewrite_count == snapshot`, break — converged.
4. If the loop exits via the iteration cap (i.e., the final sweep still
   recorded rewrites), raise `Pipeline::FixedPointOverflow` with the
   function name and iteration count.
5. Record the per-function convergence count on a new
   `Log#convergence[fn_identity] = n` map (or equivalent), for the
   walkthrough renderer to surface.

### Callee recursion

`InliningPass` already triggers callee-function processing via
`ensure_callees_run` (or the existing seen-set traversal in
`Pipeline#run`). Each callee function passes through its own fixed-point
loop when the outer `each_function` iteration reaches it. No
special-casing required.

### Termination argument

Every shipped iterative pass strictly reduces the number of instructions
(or replaces a sequence with an equally-long sequence *and* records a
log entry exactly once per rewrite site, never oscillating). The loop
therefore converges in O(n) iterations over instruction count. The cap
of 8 is a safety net for bugs, not a soundness bound. Exceeding it
indicates either a pass that oscillates or a pass that records log
entries without changing IR — both are bugs.

## Walkthrough rendering

### `IseqSnapshots`

`run_with_passes(source, path, passes)` continues to build a progressive
prefix of passes and runs each prefix through `Pipeline#run`. Because
`Pipeline#run` now internally iterates, each progressive-prefix
invocation is itself run to convergence. Per-pass slide content
(`result.per_pass[name]`) therefore becomes "the iseq after running
this prefix of the pipeline to fixed-point", which is the natural
generalisation of today's behaviour.

### `MarkdownRenderer`

Gains a header line per function, sourced from the pipeline's
convergence map:

```
converged in N iterations
```

Placed directly under the existing per-function header. On the
`after_full` render only — per-pass prefixes do not surface their own
per-prefix iteration counts (too noisy; not the story the slide tells).

### `DisasmNormalizer`

Unchanged.

### Walkthrough YAML sidecars

Unchanged. The `walkthrough` list still names passes in Pipeline.default
order; the slide story is "with this prefix enabled, here's the
converged result".

## Logging

`Log` entries gain an optional `:iter` metadata key (the iteration
index at which the rewrite was recorded). Renderer ignores it for the
aggregate slide story. Kept for debuggability and for the unit test
below.

## Tests

### New

- `optimizer/test/pipeline_test.rb`:
  - A synthetic two-pass scenario (`PassA` rewrites shape X→Y, `PassB`
    rewrites Y→Z where Z only appears after X→Y) verifies the loop
    converges in 2 iterations and log entries carry the right `:iter`
    values.
  - A pathological pass (test-only) that always records a log entry
    without changing IR asserts `FixedPointOverflow` fires at
    iteration 8 with the function name in the message.
  - A no-cascade scenario (a single pass that converges in 1 iteration
    with zero rewrites on the first sweep) confirms the zero-cost
    path: `MAX_ITERATIONS` never exceeded, convergence count = 1.

### Existing (regression gate)

**Every existing e2e and integration test must pass unchanged.** This
is an explicit constraint on the implementation, not a hope:

- `optimizer/test/pipeline_test.rb` — existing pipeline behaviour
  tests.
- `optimizer/test/passes/**` — every per-pass unit test. Unaffected
  since individual passes' `apply` semantics don't change.
- `optimizer/test/demo/**` — walkthrough rendering tests.
- `optimizer/test/harness_test.rb` — end-to-end.
- `optimizer/test/contract_test.rb`, `log_test.rb`, `ir/**`,
  `codec/**`, `type_env_test.rb`, `rbs_parser_test.rb` — all continue
  to pass.

Any test that fails after this change is either (a) a bug introduced by
the loop, or (b) a test that was asserting on pre-cascade output that
is now strictly better. Case (b) must be triaged individually and the
change approved as an intentional improvement — not silently
regenerated.

### Demo artifacts

`rake demo:verify` must pass across all committed fixtures
(`point_distance`, `sum_of_squares`, `polynomial`, `claude_gag`,
`claude_loop`). Expected outcomes:

- **`polynomial`**: artifact changes. ArithReassoc and IdentityElim
  slides gain real diffs (likely `n * 2 * 6 / 12 → n` via ordered-group
  mult/div collapse + `*1` elim; trailing `+ 0` remains pending the
  separate (C) fix). Convergence count expected ≤ 3. Regenerate and
  commit.
- **`point_distance`**: no semantic change expected. Convergence count
  likely 1 or 2. Header line gets added; artifact regenerates trivially.
- **`sum_of_squares`**: no semantic change expected. Most passes still
  `(no change)` since no shipped pass is loop-aware. Convergence count
  likely 1. Header regenerates.
- **`claude_*`**: no change (Claude gag pass is not in Pipeline.default).

For every fixture whose artifact changes, regenerate via `bin/demo
<fixture>` and commit the new artifact in the same commit as the
pipeline change. `rake demo:verify` must be green at HEAD.

## Implementation order

1. Add `Log#rewrite` + `Log#rewrite_count`; migrate pass call sites from
   `skip` to `rewrite` based on reason taxonomy.
2. Add `Pass#one_shot?` with default `false`; override in `InliningPass`.
3. Add `Pipeline::FixedPointOverflow` error class and `MAX_ITERATIONS`.
4. Restructure `Pipeline#run` per-function loop.
5. Add convergence tracking to `Log`.
6. Write new `pipeline_test.rb` cases.
7. Run full test suite. Triage failures.
8. Regenerate demo artifacts. Run `rake demo:verify`.
9. Add `MarkdownRenderer` header line.
10. Re-run `rake demo:verify`, commit artifacts.

## Out of scope

- Making `InliningPass` iterative. Current inlining decisions depend on
  the call graph and `SlotTypeTable`, both built once upfront. Later
  passes don't expose new inline opportunities. Reconsider when/if a
  pass is added that does.
- `DeadBranchFoldPass` full CFG-level DCE (removing unreachable blocks,
  patching catch-tables). Still out of scope per the main TODO.
- IR-hash-based convergence detection. The log-based check is sufficient
  given walkthrough rendering already trusts log accuracy.
- Extracting a separate `PeepholePipeline` class. The one-shot/iterative
  split is cheap enough to live inside `Pipeline#run`.

## Risk

A pass that records a log entry without changing IR would cause the
loop to run to the 8-iteration cap and raise. Mitigation: this bug
would already have broken the walkthrough renderer (which depends on
log entries describing real rewrites), so it would have been caught
upstream. Not adding IR-diff verification.

A pass that mutates IR without recording a log entry would cause the
loop to terminate too early, missing cascades that should have
iterated. Mitigation: the pass walkthrough tests already gate on log
accuracy — such a pass would show `(no change)` in its walkthrough
slide despite mutating, which is an existing-test failure.

## Related

- Source: `docs/TODO.md` "Polynomial-demo cascade gaps (filed
  2026-04-22)".
- Supersedes the "reorder arith_reassoc after Tier 2" option from the
  same TODO entry. The fixed-point loop retires that class of
  phase-ordering fix wholesale.
