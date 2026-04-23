# DeadStashElimPass — design

Status: draft, 2026-04-23

## Motivation

InliningPass v3's argument-stash machinery emits adjacent
`setlocal X; getlocal X` pairs to pass a caller value into the inlined
body's first read of the argument. When the inlined body later folds
down to nothing (as happens on the polynomial fixture after
arith_reassoc v4.1 + identity_elim), the stash pair remains as a
redundant round-trip: the producer's value flows through the slot and
back to the stack with no observer between the two operations.

Classic dead-store elimination does NOT apply here. The store has a
consumer: the very next `getlocal` reads the slot. The slot is not
dead until after the reload. The correct shape is a *peephole*
recognising the store-and-only-consumer-is-adjacent-load pattern and
eliminating both instructions.

Shipping this is a prerequisite for unblocking three residual
instructions at every inliner call site, and — crucially — for
exposing the producer to whatever instruction follows the pair, so
that the arith/const-fold cascade keeps working past the stash.

## Scope

A new peephole pass `RubyOpt::Passes::DeadStashElimPass`. Narrow
target:

- Strictly adjacent `setlocal X; getlocal X` in the instruction stream
  (no tolerated instructions between them).
- Same slot (operand 0 of both instructions matches exactly).
- Same level (both WC_0, or both explicit `setlocal/getlocal` with
  matching non-zero level operand).
- The slot has **no other reference** at this level anywhere else in
  the function's instruction stream — no other setlocal, no other
  getlocal, at this slot and level.

When all gates hold, drop both instructions. The producer that fed
the `setlocal` is unchanged; its value simply remains on the operand
stack for the instruction that followed the `getlocal`.

**Explicitly non-goals:**

- Full dead-store elimination (stores with no subsequent read before
  next store). Listed as a separate TODO item; meaningfully bigger
  (needs a mini-dataflow walk and catch-table interaction analysis).
- Non-adjacent store-and-reload (`setlocal X; <inst>; getlocal X`) —
  would require per-opcode side-effect classification.
- Multi-reader collapse (`setlocal X; getlocal X; getlocal X; …`).
  Would need a `dup` insertion; clearly more work and not on any
  fixture yet.
- Cross-iseq reasoning. Per-function is sufficient for the inliner's
  output because `LocalTable#grow!` adds stash slots to the caller's
  local table and they are function-local.

## Mechanism

### Opcode recognition

The pass walks `function.instructions` and at each position `i` checks
whether `insts[i]` is a setlocal and `insts[i+1]` is a getlocal of the
matching shape.

Setlocal opcodes to recognise:
- `:setlocal_WC_0` — shorthand for level 0 (the common form).
- `:setlocal` — explicit level via operand 1.

Getlocal opcodes to recognise:
- `:getlocal_WC_0` — shorthand for level 0.
- `:getlocal` — explicit level via operand 1.

A matching pair has:
- Slot: `insts[i].operands[0] == insts[i+1].operands[0]` (slot index
  is operand 0 for all four opcodes).
- Level: either both opcodes are the `_WC_0` form, OR both are the
  explicit form with equal `operands[1]`. A `_WC_0` on one side and
  explicit-level-0 on the other is not treated as a match — the
  shorthand form is the signal, and mixing is too rare to invest in.

### "No other reference" scan

Before folding, walk the entire `function.instructions` once and
collect every setlocal/getlocal that references the candidate slot at
the candidate level. Count all references EXCEPT the two instructions
at positions `i` and `i+1`. If the count is zero, the pair is safe to
drop. If it is non-zero, skip (leave the pair in place).

The scan uses the same opcode-and-level matching rules as above.

### Rewrite

On a matching pair with a clean scan, splice `function.instructions`
to remove positions `i` and `i+1`. Log via `Log#rewrite` with reason
`:dead_stash_eliminated` (bumps `rewrite_count`, so the fixed-point
loop re-sweeps if another pass then exposes a cascade).

### Multiple pairs in one pass invocation

The walker scans the full instruction list in one pass, collects all
candidate pair positions, verifies each via the independent "no other
ref" scan, then performs the splices in one pass (from the end of the
list backward so indices don't shift under us). If a splice produces
a new adjacent pair (unlikely but theoretically possible), the
fixed-point loop's next iteration catches it.

### Pass metadata

- `one_shot?` returns `false` — iterative.
- `#name` returns `:dead_stash_elim`.

## Pipeline placement

Insert in `Pipeline.default` directly after `InliningPass`:

```ruby
Passes::InliningPass.new,
Passes::DeadStashElimPass.new,   # new
Passes::ArithReassocPass.new,
Passes::ConstFoldTier2Pass.new,
Passes::ConstFoldEnvPass.new,
Passes::ConstFoldPass.new,
Passes::IdentityElimPass.new,
Passes::DeadBranchFoldPass.new,
```

Placement rationale: eliminating the stash pair exposes the producer
(e.g. `putobject 42`) directly to arithmetic operators that follow,
so arith_reassoc's literal-run coalescing and the const-fold tiers
can now see through the former round-trip.

## Files

**Created:**
- `optimizer/lib/ruby_opt/passes/dead_stash_elim_pass.rb`
- `optimizer/test/passes/dead_stash_elim_pass_test.rb`

**Modified:**
- `optimizer/lib/ruby_opt/pipeline.rb` (require + registration in
  `Pipeline.default`)
- `optimizer/lib/ruby_opt/demo/markdown_renderer.rb` (one-line entry
  in `PASS_DESCRIPTIONS` — it's how walkthroughs label the pass)
- `docs/demo_artifacts/polynomial.md` (regenerated)
- `docs/TODO.md` (strike the polynomial-cascade-gap bullet that this
  resolves; add a new TODO entry for full DSE)

Walkthrough YAML sidecars (`optimizer/examples/*.walkthrough.yml`)
do NOT need updating — they list the pass order as a subset; the
demo runner takes whatever prefix subset is listed and runs that
through the pipeline. New-pass visibility in artifacts happens only
if the fixture author adds the pass name to the walkthrough list.
Leave them alone unless a walkthrough slide is specifically desired
for this pass on the polynomial fixture. (Deciding that is part of
the implementation plan, not the spec.)

## Tests

All in `optimizer/test/passes/dead_stash_elim_pass_test.rb`. Follow
the pattern used by existing per-pass tests: compile a Ruby source
string, decode into IR, invoke the pass, assert on
`function.instructions`, optionally `load_from_binary` + `.eval` to
prove semantic equivalence.

### Positive cases
- **Adjacent pair, slot unreferenced elsewhere, drops.** Construct an
  IR with `putobject 42; setlocal_WC_0 n@1; getlocal_WC_0 n@1; leave`
  where slot `n@1` has no other references. After the pass, expect
  `putobject 42; leave`. Assert a `:dead_stash_eliminated` log entry.
- **End-to-end.** Construct a fragment that executes correctly before
  and after the pass. `load_from_binary` + `.eval` returns the same
  value both times. (Value chosen so the producer is something
  specific — e.g., 42 — to sanity-check that the stack really does
  carry the value past the dropped pair.)

### Negative cases (pass leaves IR alone)
- **Second reader exists.** `setlocal X; getlocal X; getlocal X` →
  unchanged. The first `getlocal` could be the "adjacent" one but
  the slot has another reader, so the scan blocks the fold.
- **Later-in-iseq reader.** `setlocal X; getlocal X; … ; getlocal X`
  (another getlocal of same slot much later) → unchanged.
- **Later-in-iseq writer.** `setlocal X; getlocal X; … ; setlocal X`
  → unchanged. Collapsing the adjacent pair would eliminate a write
  whose observable state (post-later-write) depends on which write
  "won."
- **Level mismatch.** `setlocal X at level 1; getlocal X at level 0`
  → unchanged. Different variables.
- **Mixed shorthand vs explicit form.** `setlocal_WC_0 X;
  getlocal X at level 0` → unchanged, for simplicity (documented
  non-goal above).
- **Non-adjacent.** `setlocal X; putobject 1; getlocal X` →
  unchanged, even if `putobject` has no side effects relevant to X.

### Fixed-point integration
- After running the pass on a fixture with one eligible pair,
  `log.rewrite_count` equals the number of pairs dropped (1 for a
  single pair).

### End-to-end polynomial
- After this pass lands, regenerating
  `docs/demo_artifacts/polynomial.md` shows the `compute`-call
  site's `putobject 42; setlocal n@1; getlocal n@1; leave` shrink
  to `putobject 42; leave`. Similarly for the `compute(0)` call.
- Convergence count may drop from 3 → 2 iterations. Not guaranteed.
- Benchmark ratio likely moves upward slightly. Not worth
  predicting precisely.

## Risk

- **Correctness gate.** "No other reference" is a whole-function
  scan at the same level. The only way this could miss a reference
  is if the reference lives outside `function.instructions` — which
  is impossible by definition (locals are per-iseq). Catch tables
  reference instruction ranges, not locals directly; any local
  referenced from a catch-handler body is referenced via its own
  `getlocal` in that body's instruction stream, which IS scanned.
- **Interaction with InliningPass's stash slot naming.** Not a
  concern. DeadStashElim runs AFTER inlining, so by the time it
  fires the slots are present in the local table with normal
  setlocal/getlocal references. The pass doesn't need to know
  anything about how the slot got there.
- **Oscillation.** Strictly reduces instruction count per firing.
  No oscillation possible. Bounded by number of matching pairs.
  The fixed-point MAX_ITERATIONS cap is never approached by this
  rule.
- **Existing tests.** The pass never fires on a pattern that does
  not match its narrow gate. No existing test's input contains a
  store-reload pair to a single-use slot that the other passes
  would leave behind — the inliner's output has always been opaque
  to the rest of the pipeline, so this pass is adding capability,
  not changing anyone else's behavior.

## Related

- Enabled by: fixed-point iteration (lets the newly exposed
  `putobject`-to-next-inst adjacency cascade into const_fold /
  arith_reassoc in one pipeline run).
- Enabled by: arith_reassoc v4.1 (folded the polynomial body
  enough that the stash pair became the ONLY remaining clutter at
  the call site; without v4.1 the pair was sandwiched between
  other instructions and less visible in the talk).
- Source TODO bullet: `docs/TODO.md` under "Polynomial-demo
  cascade gaps (filed 2026-04-22)" — first bullet ("InliningPass
  v3 leaves a redundant setlocal/getlocal round-trip at the stash
  site").
- Follow-on TODO (to be added in the implementation plan): a
  proper dead-store-elimination pass for `setlocal X` with no
  subsequent read before the next `setlocal X`. Different mental
  model (dataflow, not peephole); bigger project.
