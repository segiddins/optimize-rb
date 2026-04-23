# ArithReassoc v4.1 — exact-divisibility fold (design)

Status: draft, 2026-04-23

## Motivation

After the pipeline fixed-point loop shipped, the polynomial demo's
arithmetic chain collapses `n * 2 * SCALE / 12` down to `n * 12 / 12`
(via Tier 2 folding `SCALE → 6` and the same-op mult literal run
coalescing `2 * 6 → 12`). The final step — recognising that `12 / 12`
is the identity and dropping it — is blocked in the current walker
because the cross-op boundary between `* 12` and `/ 12` commits the
pending accumulator without attempting an exact-divisibility fold.

No shipped pass knows the identity `(x * a) / b = x * (a/b)` when
`b | a`. Adding it here cascades through the existing IdentityElim v1
`x * 1 → x` rule (because `12 / 12 = 1`), and the fixed-point loop
makes the cascade happen automatically in a single pipeline run.

## Scope

One new rule in `ArithReassocPass#try_rewrite_chain_ordered`'s literal
branch: when the pending accumulator holds a literal at op `:opt_mult`
and the next literal has op `:opt_div`, and `acc_value` is a multiple
of the divisor literal, absorb the divisor into the accumulator.

**Direction:** `* then /` only. The symmetric `/ then *` direction is
unsound under integer-division truncation (`(x / a) * b` is not
equivalent to `x * (b/a)` even when `a | b`; `x` may not be a multiple
of `a`, and the truncation at `x / a` loses information that
`x * (b/a)` cannot recover).

**Non-goals:**

- Div-then-mult folding.
- gcd-based partial folding (`x * 12 / 8 → x * 3 / 2`).
- Non-Integer operand types.
- Any changes to IdentityElim, ConstFold, or other passes.

## Walker change

Inside `try_rewrite_chain_ordered` at
`optimizer/lib/ruby_opt/passes/arith_reassoc_pass.rb`, the literal
branch of the `stream.each` walk currently has three cases:

```ruby
if e[:is_literal]
  if acc.nil?                                         # case A: seed
    acc = e[:value]; acc_op = e[:op]
  elsif acc_op == e[:op] && (associative || emitted.empty?)
    acc = acc.send(run_combiner, e[:value])           # case B: same-op run
  else
    commit.call                                       # case C: cross-op
    acc = e[:value]; acc_op = e[:op]
  end
```

Insert a new case B2 between B and C:

```ruby
elsif acc_op == :opt_mult && e[:op] == :opt_div &&
      associative && acc.is_a?(Integer) && acc % e[:value] == 0
  acc = acc / e[:value]
  # acc_op stays :opt_mult; the divisor is absorbed.
  log.rewrite(pass: :arith_reassoc, reason: :exact_divisibility_fold,
              file: function.path, line: chain_line)
```

### Gate rationale

- `acc_op == :opt_mult && e[:op] == :opt_div` — the only sound direction.
- `associative` — belt-and-suspenders; the mult/div group is marked
  `associative: true`, and any future `:ordered` group that wanted
  different semantics should not pick up this fold without thinking.
- `acc.is_a?(Integer)` — the same-op-run combiner can leave `acc` as
  whatever `Integer#*` produces, which is always Integer for two
  Integers; defensive guard is free.
- `acc % e[:value] == 0` — the correctness predicate.
- `e[:value] > 0` is already guaranteed by the existing "unsafe
  divisor" pre-scan at the top of the method (rejects any `:opt_div`
  / `:opt_mod` with a literal that is zero, negative, or non-Integer).

### Log reason

New reason `:exact_divisibility_fold` routed through `Log#rewrite`
(introduced in the fixed-point-iteration work). Bumps `rewrite_count`
so the fixed-point loop sees the change and will re-sweep. Distinct
from the existing `:reassociated` reason so walkthrough narration can
call out the fold step specifically.

## Interaction with existing pass behavior

- **Case B (same-op literal run) runs before B2.** `x * 2 * 6 / 4`:
  acc accumulates `2 * 6 → 12` via case B, then sees `/ 4`. 12 % 4 = 0,
  B2 fires: acc := 3. End-of-stream commits `3` with op `*`. Emits
  `x * 3`.
- **Non-exact divisibility falls through to case C** (commit + start
  fresh) — unchanged behavior. `x * 12 / 5` emits unchanged.
- **`acc` value shrinks on B2**, so the existing
  `fits_intern_range?` check is trivially preserved.
- **No-change guard** tracks input vs output literal counts. B2
  consumes a divisor literal without producing a new one, so output
  count strictly decreases by 1 per fold. Guard doesn't trip.
- **Cascade to IdentityElim v1.** A `12 / 12 → 1` fold emits `x * 1`.
  IdentityElim v1's `x * 1 → x` rule strips it. With the fixed-point
  loop (shipped earlier today), this happens in one `pipeline.run`
  call without the caller needing to invoke the pipeline twice.

## Tests

Extend `optimizer/test/passes/arith_reassoc_pass_test.rb`:

- `test_exact_divisibility_fold_x_times_k_over_k` — `x * 12 / 12` emits
  `x * 1`. Assert a `:exact_divisibility_fold` entry in the log.
- `test_exact_divisibility_fold_x_times_12_over_4` — `x * 12 / 4` emits
  `x * 3`.
- `test_exact_divisibility_cascades_through_same_op_run` —
  `x * 2 * 6 / 4` emits `x * 3`. Verifies that the pre-existing same-op
  run coalesces before the new rule fires.
- `test_non_exact_divisibility_preserves_chain` — `x * 12 / 5` emits
  unchanged. Assert no `:exact_divisibility_fold` entry; the existing
  `:no_change` pathway should fire.
- `test_div_then_mult_not_folded` — `x / 4 * 12` emits unchanged.
  Regression guard against accidentally adding the unsound symmetric
  direction.
- `test_exact_divisibility_zero_accumulator_preserves_fold` —
  `x * 0 * 5 / 5` folds to `x * 0` (same-op run sets acc=0, exact-div
  folds `0 / 5 = 0`). The `x * 0 → 0` absorbing-zero rule is separate
  (IdentityElim v2 future work); assert that the fold happens and
  produces `x * 0`, nothing more.

## Demo artifacts

After this lands, regenerate `docs/demo_artifacts/polynomial.md`. Expected
changes:

- `arith_reassoc` walkthrough slide gains the exact-divisibility fold —
  instead of stopping at `n * 12 / 12`, it now emits `n * 1`.
- `identity_elim` slide shows `n * 1 → n` cascading off the new fold.
- Trailing `+ 0` remains (separate IdentityElim extension is tracked
  in TODO).
- Header ratio likely improves from 1.09x to a higher number; not
  worth predicting precisely.
- Convergence count (from the fixed-point header line) may drop from
  3 to 2 iterations, since the cascade lands in fewer sweeps.

`point_distance.md` and `sum_of_squares.md` should not change
semantically; any diff there should be benchmark-line noise.

`rake demo:verify` must pass (subject to the pre-existing T_NODE
artifact-instability flake documented in
`docs/TODO.md` under "Polynomial-demo artifact instability
(filed 2026-04-23)"; per-fixture `bin/demo` regen is the documented
workaround).

## Out of scope (confirmed)

- Symmetric `/ then *` direction — unsound without proving `x` is a
  multiple of the first divisor. Would require static analysis or
  typed operand info well beyond v4.1.
- gcd-based partial folds (`x * 12 / 8 → x * 3 / 2`). Strictly more
  general but meaningfully more walker work and a new mental model;
  deferred.
- Non-Integer numerics (Float / Rational) — excluded by the existing
  `mixed_literal_types` pre-scan.
- Any IdentityElim changes — the `x * 1 → x` cascade uses only
  existing v1 behavior.

## Risk

- **Correctness of the gate.** The identity `(x * a) / b = x * (a/b)`
  when `b | a` is a standard integer-arithmetic result and
  independent of `x`'s runtime value. The gate `acc % e[:value] == 0`
  is necessary and sufficient; pre-scan excludes zero/negative/non-Integer
  divisors.
- **Oscillation / fixed-point safety.** The fold strictly reduces
  output literal count per firing. A chain can fold at most as many
  times as it has `/` literals. Bounded; no oscillation possible. The
  fixed-point loop's MAX_ITERATIONS=8 cap is never approached by this
  rule.
- **Walkthrough artifact churn.** Expected and desired. Two artifacts
  change (polynomial and whichever non-polynomial has any trailing
  `n * 1` pattern — likely none).

## Related

- Source: `docs/TODO.md` "Roadmap gap, ranked by talk-ROI" item 10
  "ArithReassoc v3.1" and the exploratory "v4.1 exact-divisibility
  folds" sub-bullet under "Refinements of shipped work". (v4.1 is
  landing before v3.1 because the polynomial cascade makes it the
  higher-ROI next step.)
- Enabled by: fixed-point iteration
  (`docs/superpowers/specs/2026-04-23-pipeline-fixed-point-iteration-design.md`) —
  without the loop, the `x * 1 → x` cascade would require running the
  pipeline twice. With it, one `Pipeline#run` suffices.
