# Spec: Arithmetic Reassociation Pass — v3 (additive group: opt_plus + opt_minus)

**Part of:** [Ruby the Hard Way](2026-04-19-talk-structure-design.md)
**Extends:** [ArithReassocPass v2](2026-04-20-pass-arith-reassoc-v2-design.md) — v2 ships `opt_plus` + `opt_mult` as two independent single-operator rows; v3 generalizes a row into a *group* of operators sharing an identity and reducer, and adds `opt_minus` to the additive group.
**Depends on:** v2 shipped (`ArithReassocPass` with `REASSOC_OPS`, two-level fixpoint, `INTERN_BIT_LENGTH_LIMIT` guard), `LiteralValue` helper, `ObjectTable#intern` (special-const only), `IR::CFG.compute_leaders`, `IR::Function#splice_instructions!`, `ConstFoldPass` already handling `opt_minus`.

## Purpose

Cover the additive group. `x + 1 - 2 + 3 → x + 2` is the shape this pass now nails. v3 is also the spec that earns the word *group* on the talk slide: v1 and v2 shipped two independent one-operator rows; v3 is the moment the table's row becomes richer (a keyed map of operators + their literal-combiner), which is exactly how v4's `opt_mult + opt_div` row will slot in later.

## Scope

One structural change and one transformation:

1. `REASSOC_OPS` is renamed to `REASSOC_GROUPS`, and each entry's `{opcode:, reducer:}` becomes `{ops:, primary_op:}` where `ops` is an `opcode → combiner_method` map. The rename + shape change is its own task with zero behavior change.
2. `opt_minus` is added to the additive group's `ops` map. Chain detection, sign tracking, and the rewrite gain sign-aware non-literal reordering so `x + 1 - y + 2 → x - y + 3` is supported.

### Explicitly in

- Additive chains containing any mix of `opt_plus` and `opt_minus` links, Integer literals only, fold to a single literal tail emitted as `push <reduced>; opt_plus`.
- Non-literal operands in a folded chain are partitioned by effective sign and emitted as `pos ++ neg`, with intermediate ops (`opt_plus` / `opt_minus`) filled in from adjacent signs.
- Skip with new reason `:no_positive_nonliteral` when all non-literals have effective sign `−` (a.k.a. the leading-negative-nonliteral case). Chain left alone.
- Overflow guard unchanged: `fits_intern_range?(reduced)` with `bit_length < 62`, symmetric across negative values.
- Cross-group fixpoint: existing v2 two-level loop handles mixed shapes like `x + 2 * 3 - 4 → x + 2`.
- A task-1 pure refactor (`REASSOC_OPS` → `REASSOC_GROUPS`), zero behavior change, all existing tests stay green.
- A task-2 implementation of the additive-group extension + sign-aware rewrite + reordering + new skip reason + tests.
- Folding in the v2 loose-end `opt_mult` no-literal test (`def f(x, y, z); x * y * z; end`) since the test file is already being edited.
- Corpus regression under the updated pipeline.

### Explicitly out (deferred to later plans)

- **Multiplicative group with `opt_div`.** Integer division isn't total (`/0`) and floor-division breaks the abelian structure under negative divisors. v4's own spec.
- **`**`.** Right-associative, non-commutative. Never joins any reassociation group.
- **Leading-negative unary emission.** When all non-literals have effective sign `−`, v3 skips. A future v3.1 could emit `push 0; <nonliteral>; opt_minus; ...` to unblock these. Out of scope here.
- **Bignum literals in `ObjectTable#intern`.** Same deferral as v2. Overflow is skipped with `:would_exceed_intern_range`.
- **RBS-driven typing of non-literal operands, cross-block chains, multi-instruction operand producers.** Same deferral as v1/v2.

## Algorithm

**Groups table.** The class carries:

```ruby
REASSOC_GROUPS = [
  { ops: { opt_plus: :+, opt_minus: :- }, identity: 0, primary_op: :opt_plus },
  { ops: { opt_mult: :*                }, identity: 1, primary_op: :opt_mult },
].freeze
```

`ops` is an insertion-ordered `opcode → combiner_method` map. `primary_op` is the opcode used to emit the single literal-carrying trailing op in a rewritten chain.

Task 1 lands the shape change with singleton `ops` maps for both entries (additive = `{opt_plus: :+}`, multiplicative = `{opt_mult: :*}`), which is identical behavior to v2.

Task 2 adds `opt_minus: :-` to the additive entry.

`apply` iterates `REASSOC_GROUPS`. For each entry, it runs the existing inner fixpoint (v2's shape), passing the entry as `group:` to `rewrite_once`. `rewrite_once`, `detect_chain`, and `try_rewrite_chain` all take `group:` in place of v2's `op_spec:`. The outer any-rewrite fixpoint over the full `REASSOC_GROUPS` list is unchanged.

**Chain detection.** `detect_chain` mirrors v2's structure. The link predicate changes from `insts[op_j].opcode == op_spec[:opcode]` to `group[:ops].key?(insts[op_j].opcode)`. Same forward-scan change on the end-of-chain anchor. `SINGLE_PUSH_OPERAND_OPCODES` is unchanged and shared across all groups.

`detect_chain` now returns its op positions as `[{idx:, opcode:}, ...]` in source order (instead of v2's bare `op_indices`). Producer indices are unchanged.

**Sign/op tracking.** Each producer in the chain is tagged with a *combiner* — the Symbol method used to fold that producer into the accumulator. The combiner is determined by the op immediately to the producer's left in the chain:

- First (leftmost) producer: `group[:ops][group[:primary_op]]`. For the additive group this is `:+`; for the multiplicative group, `:*`. Equivalent to "the leading producer is folded as if preceded by the group's primary op."
- Producer at position `k > 0`: `group[:ops][ops_meta[k-1][:opcode]]` — for the additive group, `:+` if preceded by `opt_plus` and `:-` if preceded by `opt_minus`.

For the multiplicative group (today `{opt_mult: :*}`), every producer has combiner `:*`, so the tagging is a no-op and the combined reducer remains `acc * lit`. The *effective sign* of a non-literal is a derived concept — `+` if combiner is `:+`, `−` if combiner is `:-` — used only in the non-literal partitioning step below.

**Literal reduction.** Classify each producer via `LiteralValue.read`/`literal?` as Integer literal, non-Integer literal, or non-literal. Each classified producer carries its combiner from the step above. The reduced literal is:

```ruby
reduced = classified_integer_literals.inject(group[:identity]) do |acc, (val, combiner)|
  acc.send(combiner, val)
end
```

**Non-literal reordering (Q1-B from brainstorming).** Non-literal operands are tagged with their effective sign at classification time, then partitioned:

- `pos` — non-literals with effective sign `+`, original order preserved.
- `neg` — non-literals with effective sign `−`, original order preserved.

If `pos.empty? && !neg.empty?`, skip the chain: log `:no_positive_nonliteral`, return `false` from `try_rewrite_chain`, leave the chain alone. This is the safety net for `1 - x + 2 → 3 - x`-shape chains where the leading operand would need runtime negation; v3 does not emit that.

Otherwise, emit non-literals as `pos ++ neg`. The leading operand is a `pos`, so it pushes cleanly. Intermediate ops between consecutive entries:

- `pos[i], pos[i+1]` → `opt_plus`.
- `pos[-1], neg[0]` → `opt_minus`.
- `neg[i], neg[i+1]` → `opt_minus`.

Tail: `push <reduced>; opt_plus` when `|non_literals| >= 1`, using `primary_op` for the literal-carrying op. When the chain is all-literal (`non_literals.empty?`), the replacement is just `push <reduced>` — zero tail op — mirroring v2.

**Safety of reordering.** `SINGLE_PUSH_OPERAND_OPCODES` is literal producers + `getlocal*` + `getinstancevariable` + `getclassvariable` + `getglobal` + `putself`. All side-effect-free w.r.t. each other — swapping their push order does not change observable Ruby semantics. The allowlist is the invariant that makes non-literal reordering legal; losing or widening it without re-examining this invariant is a mistake. A comment in the pass file should call this out (see "Not changing" for the enforcement rule).

**Emit shape for negative folded literal (Q3-A).** Always `putobject <literal>; opt_plus`, even when `literal < 0`. Reasons:

1. Keeps the rewrite tail symmetric with v2's shape: one literal, one primary op.
2. `putobject <small negative int>` round-trips through `RubyVM::InstructionSequence.to_binary` + `load_from_binary` cleanly at talk-scale values; the known codec segfault with large putobject integers (v2 follow-up 1) is a bit-width issue, not a sign issue.
3. The non-literal portion of the tail already mixes `opt_plus`/`opt_minus` freely (that's the whole point of the additive group); normalizing the single literal-carrying op to `primary_op` is a mild consistency win.

**Chain-too-short & mixed-types.** Same rules as v2:

- Fewer than 2 Integer literals in the chain → `:chain_too_short`, skip.
- Any non-Integer literal in the chain (e.g., Float, String) → `:mixed_literal_types`, skip.

**Overflow guard.** Unchanged from v2:

```ruby
INTERN_BIT_LENGTH_LIMIT = 62
def fits_intern_range?(n) = n.is_a?(Integer) && n.bit_length < INTERN_BIT_LENGTH_LIMIT
```

`bit_length` is magnitude-based, so the check is symmetric across negative values. On failure, log `:would_exceed_intern_range`, chain left alone.

**Two-level fixpoint.** Unchanged from v2. Minus joins the additive group at the inner level — `x + 1 - 2 + 3` collapses in one inner pass over the additive group; no outer hop needed. The outer loop still exists for cross-group exposure: `x + 2 * 3 - 4` → inner mult pass folds `2*3 → 6` → outer re-runs additive pass and folds `x + 6 - 4 → x + 2`.

Termination: each rewrite strictly shrinks `insts.size` by at least 2 (v1/v2 argument, unchanged).

**Pipeline ordering.** Unchanged: `[ArithReassocPass, ConstFoldPass]`. `ConstFoldPass` already handles `opt_minus` (it's in `ConstFoldPass::BINOPS`), so any residual all-literal `(lit, lit, opt_minus)` triple that arith's all-literal path might leave is mopped up naturally.

## Logging

Reuse `Log#skip(pass:, reason:, file:, line:)` with reasons:

- `:reassociated` — success, one entry per chain rewritten. (Unchanged.)
- `:mixed_literal_types` — chain contained a non-Integer literal. (Unchanged.)
- `:chain_too_short` — chain had `< 2` Integer literals. (Unchanged.)
- `:would_exceed_intern_range` — reduced result would not fit in the intern range. (Unchanged from v2.)
- `:no_positive_nonliteral` — **NEW** — all non-literals in the chain have effective sign `−`, would require runtime negation; chain left alone.

Pass name: `:arith_reassoc` (unchanged).

The log entry does not carry the operator or the group identity. As in v2, a reader can distinguish additive from multiplicative chains by reading the file+line.

## Interface

Unchanged from v1/v2:

```ruby
class Optimize::Passes::ArithReassocPass < Optimize::Pass
  def name = :arith_reassoc
  def apply(function, type_env:, log:, object_table: nil)
end
```

`REASSOC_GROUPS` is a pass-private constant that tests may read (e.g., "the pass's additive group knows about `:opt_minus`"), but it is not part of the `Pass` base-class contract.

## Files

```
optimizer/
  lib/optimize/
    passes/
      arith_reassoc_pass.rb              # MODIFIED — REASSOC_OPS → REASSOC_GROUPS + opt_minus
  test/
    passes/
      arith_reassoc_pass_test.rb         # MODIFIED — v3 unit tests + v2 mult-no-literal loose end
      arith_reassoc_pass_corpus_test.rb  # UNCHANGED
README.md                                # MODIFIED — mention opt_minus in the additive-group row
```

No new files. No new public interfaces. `REASSOC_OPS` is renamed in Task 1; the only readers are the pass itself and its test file.

## Test strategy

1. **Task 1 (refactor):** all 134 existing tests green, zero new tests. Any test asserting on `REASSOC_OPS` (if any exist) is renamed to `REASSOC_GROUPS` and shape-updated.

2. **Task 2 unit tests** (hand-built IR via `RubyVM::InstructionSequence.compile` → `Optimize::Codec.decode`; round-trip every case through `Optimize::Codec.encode` + `RubyVM::InstructionSequence.load_from_binary(...).eval` and compare to un-optimized evaluation):

   - `def f(x); x + 1 - 2 + 3; end; f(10)` → exactly one `opt_plus`, zero `opt_minus`, a literal `2`, `.eval == 12`. Baseline additive-group test.
   - `def f(x); x - 1 - 2 - 3; end; f(10)` → exactly one `opt_plus`, zero `opt_minus`, a literal `-6`, `.eval == 4`. Negative-literal emission test.
   - `def f(x); x - 5 + 3; end; f(10)` → exactly one `opt_plus`, zero `opt_minus`, literal `-2`, `.eval == 8`.
   - `def f(x, y); x + 1 - y + 2; end; f(10, 4)` → `pos=[x]`, `neg=[y]`. Emit `x - y + 3`. Exactly one `opt_plus` (literal tail), exactly one `opt_minus` (between x and y), literal `3`, `.eval == 9`.
   - `def f(x, y); 1 - x + 2 - y + 3; end; f(10, 4)` → `pos=[]`, `neg=[x, y]`. Chain left alone, `:no_positive_nonliteral` logged. Assert un-optimized `.eval` equals optimized `.eval`. Assert the rewritten function still contains both `opt_plus` and `opt_minus`.
   - `def f(x); 1 - x + 2; end; f(4)` → `pos=[]`, `neg=[x]`. Chain left alone, `:no_positive_nonliteral` logged. Simplest form of the leading-negative wedge.
   - `def f(x); x + 1 - 1.5; end` → `:mixed_literal_types`, chain untouched.
   - `def f(x); x - 1; end` → `:chain_too_short`, chain untouched.
   - `def f(x, y, z); x - y + z; end` → no literals in the chain, chain untouched, no rewrite.
   - `def f; 3 - 1 - 1; end; f` → all-literal chain, rewrites to single literal `1`, zero add/sub ops, `.eval == 1`.

3. **Cross-group interaction test** (in-pass):

   - `def f(x); x + 2 * 3 - 4; end; f(10)` — inner mult pass folds `2 * 3 → 6`, outer re-runs additive pass, folds `x + 6 - 4 → x + 2`. Assert: exactly one `opt_plus`, zero `opt_mult`, zero `opt_minus`, literal `2`, `.eval == 12`. Locks in the outer fixpoint for the additive group after the `opt_minus` addition.

4. **v2 loose-end (folded in here since the test file is being edited):**

   - `def f(x, y, z); x * y * z; end` → no literals in the chain, chain untouched, no rewrite. Closes v2 follow-up 3.

5. **Overflow:**

   - Negative-side overflow sanity: `def f(x); x - (1 << 62); end` → chain-too-short path fires first (only one literal), so this doesn't exercise overflow. Better: `def f(x); x + (1 << 40) + (1 << 30) - 0; end` is awkward. The simplest direct test: `def f(x); x - (1 << 30) - (1 << 30) - (1 << 30) - (1 << 30); end` — reduced `≈ -4 * 2^30 ≈ -2^32`, fits fine in the intern range. The "just-overflows-negative" test is held by the same codec-segfault caveat that gated v2's just-fits test. v3 does not add a new boundary test; it just confirms the existing guard logic is symmetric. This is explicitly called out in the plan, not papered over.

6. **Corpus regression:** `arith_reassoc_pass_corpus_test.rb` unchanged; it already runs `Pipeline.default` across `optimizer/test/codec/corpus/*.rb`. Any corpus file that uses subtraction will now exercise the additive-group path automatically.

7. **v1/v2 regression:** every pre-existing test green after both tasks.

## Interaction with const-fold

Unchanged in shape. `ConstFoldPass` already covers `opt_minus` in its `BINOPS` table, so residual all-literal triples left by arith's rewrite (or passed through unchanged) fold cleanly. No const-fold changes needed for v3.

## Not changing

- `Pass#apply` signature.
- `Pipeline.default` — still `[ArithReassocPass, ConstFoldPass]`.
- `LiteralValue` / `ObjectTable#intern` scope.
- v1 and v2 test expectations — the Task 1 refactor must preserve them verbatim.
- `SINGLE_PUSH_OPERAND_OPCODES` — shared across groups; no per-group allowlist. Widening this list in a future pass requires re-examining the "all entries are side-effect-free w.r.t. each other" invariant that makes non-literal reordering legal.
- `IR::Function#splice_instructions!` — handles arbitrary opcode replacements.
- `Log` schema — the new `:no_positive_nonliteral` reason does not require a schema change; `Log#skip` accepts arbitrary symbols.

## Plan shape

Three tasks, mirroring v2's two-then-optional-third structure:

- **Task 1: Rename `REASSOC_OPS` → `REASSOC_GROUPS` and change entry shape.** Each entry becomes `{ops:, identity:, primary_op:}` where `ops` is a single-entry `opcode → combiner_method` map. `rewrite_once`, `detect_chain`, `try_rewrite_chain` take `group:` in place of `op_spec:`. The link predicate becomes `group[:ops].key?(...)`. `detect_chain` returns op positions as `[{idx:, opcode:}, ...]`. Task 1 emits the literal-carrying tail op as `primary_op`, which is identical to v2 since each group has exactly one op. Zero behavior change; all 134 existing tests green. Commit: `ArithReassocPass: refactor REASSOC_OPS → REASSOC_GROUPS (no behavior change)`.

- **Task 2: Add `opt_minus` to the additive group + sign-aware rewrite + non-literal reordering + new skip reason + tests.** Append `opt_minus: :-` to the additive group's `ops` map. Classification now tags each producer with its effective sign (derived from the op to its right). Literal reduction iterates `(val, combiner)` pairs. Non-literals partition into `pos`/`neg`; if `pos.empty? && !neg.empty?`, skip with `:no_positive_nonliteral`. Otherwise emit `pos ++ neg` with intermediate ops filled in by adjacent signs, tail `push <reduced>; opt_plus`. Adds the 10 additive-group unit tests, the cross-group interaction test, and the v2 loose-end mult-no-literal test. Commit: `ArithReassocPass: add opt_minus to additive group + sign-aware reorder`.

- **Task 3 (optional; may collapse into Task 2): README + benchmark.** README passes entry updated to name the additive-group contents (`opt_plus`, `opt_minus`) and the multiplicative-group contents (`opt_mult`). One `mcp__ruby-bytecode__benchmark_ips` run for `x + 1 - 2 + 3` vs `x + 2` recorded as the v3 baseline. Commit: `Document ArithReassocPass opt_minus; record additive-group benchmark baseline`.

## Success criteria

1. After Task 1: 134 existing tests green. No behavior change. `REASSOC_GROUPS` is the sole structural difference.
2. After Task 2: 134 + ~11 tests green (10 v3 unit + 1 v2 loose-end + 1 cross-group interaction, minus any overlaps). Corpus regression green. v2 follow-up 3 closed.
3. Talk slide: `x + 1 - 2 + 3` before/after disassembly, paired with the v1 additive slide and the v2 multiplicative slide. The slide emphasizes that the pass's additive row grew one cell (`opt_minus: :-`) and the algorithm picked up sign-aware reordering as a consequence.
4. The `REASSOC_GROUPS` constant remains the design. A reader who finds the pass file and reads only that constant can predict which ops reassociate together, which ops normalize the literal tail, and — by noticing that `**` and `opt_div` are absent — which ops deliberately do not.
