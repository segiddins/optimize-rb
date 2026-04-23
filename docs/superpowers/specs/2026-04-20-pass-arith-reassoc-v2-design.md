# Spec: Arithmetic Reassociation Pass — v2 (opt_mult, table-driven)

**Part of:** [Ruby the Hard Way](2026-04-19-talk-structure-design.md)
**Extends:** [ArithReassocPass v1](2026-04-20-pass-arith-reassoc-v1-design.md) — v1 ships literal-only `opt_plus` chains; this spec generalizes the pass to a table of operators and adds `opt_mult`.
**Depends on:** v1 shipped (`ArithReassocPass` with `opt_plus`), `LiteralValue` helper, `ObjectTable#intern` (special-const only), `IR::CFG.compute_leaders`, `IR::Function#splice_instructions!`.

## Purpose

Cover the second obvious reassociable operator. `x * 2 * 3 * 4` → `x * 24` is the symmetric counterpart to v1's `x + 1 + 2 + 3` → `x + 6`, and motivates the talk's "the table is the design" slide: every row is a fact about a commutative-associative operator with an identity element, and the pass is a loop over that table.

## Scope

Two transformations, one per table row:

1. v1's existing `opt_plus` chain collapse (unchanged behavior).
2. `opt_mult` chain collapse, identity `1`, reducer `:*`, Integer-literal-only, overflow-guarded.

### Explicitly in

- `opt_mult` chain detection and rewrite mirroring v1's `opt_plus` algorithm, with identity `1` and reducer `:*`.
- A class-level `REASSOC_OPS` table that holds `{ opcode:, identity:, reducer: }` per operator. `apply` iterates the table; each entry runs its own outer fixpoint.
- **Bignum overflow guard:** before emitting the folded literal, check that the result fits in a fixnum (see "Overflow" below). If not, log `:would_overflow_fixnum` and leave the chain alone.
- A first task that is a pure refactor of v1 to a one-entry table, zero behavior change, all 125 existing tests remain green.
- A second task that adds the `opt_mult` row, tests, and overflow guard.
- Corpus regression under the updated pipeline.

### Explicitly out (deferred to later plans)

- **Mixed same-precedence chains** (`+`/`-`, `*`/`/`). These require per-operand sign/inverse tracking and, for division, Integer floor-division semantics under negative divisors. Each precedence group is its own plan (v3: additive, v4: multiplicative).
- **`**`** — right-associative, non-commutative. Never joins any reassociation group.
- **Bignum literals in `ObjectTable#intern`.** v1 scoped intern to special-const; v2 does not widen that. Bignum results are skipped with `:would_overflow_fixnum`.
- RBS-driven typing of non-literal operands — same deferral as v1.
- Cross-block chains, multi-instruction operand producers — same as v1.

## Algorithm

**Table-driven.** The class carries:

```ruby
REASSOC_OPS = [
  { opcode: :opt_plus, identity: 0, reducer: :+ },
  { opcode: :opt_mult, identity: 1, reducer: :* },
].freeze
```

`apply` iterates `REASSOC_OPS`. For each entry, it runs the existing outer-fixpoint loop (v1's shape), passing the entry into `rewrite_once`. `rewrite_once`, `detect_chain`, and `try_rewrite_chain` all accept `op_spec:` and compare `insts[i].opcode == op_spec[:opcode]` wherever v1 hard-coded `:opt_plus`.

**Chain detection.** Unchanged from v1 in structure. The only edit is parameterizing the opcode comparison:

- The forward-scan predicate: `insts[i].opcode == op_spec[:opcode]` (was `== :opt_plus`).
- The backward-walk predicate: `insts[op_j].opcode == op_spec[:opcode]` (was `== :opt_plus`).

The `SINGLE_PUSH_OPERAND_OPCODES` allowlist is shared across all table entries — literals, getlocal*, ivar/cvar/gvar, putself are semantically safe to reorder past any commutative-associative op whose BOP is not redefined. No per-op allowlist is needed in v2.

**Reassociation rewrite.** Parameterized by `op_spec`:

- Read each producer via `LiteralValue.read`; classify as Integer literal, non-Integer literal, or non-literal (unchanged).
- Skip reasons unchanged: `:mixed_literal_types`, `:chain_too_short`.
- Reduce the Integer literals with `integer_literals.inject(op_spec[:identity], op_spec[:reducer])`.
- **Overflow guard (NEW):** after reducing, if `!fits_fixnum?(result)` log `:would_overflow_fixnum` and return `false` (no rewrite).
- Emit the folded literal via `LiteralValue.emit(result, line:, object_table:)`. For `opt_plus` (v1 path) this always succeeds because `fits_fixnum?` was checked; for `opt_mult` the guard is load-bearing — emitting a Bignum via `ObjectTable#intern` would blow up.
- Build replacement: non-literals in original order, folded-literal tail, then `n-1` instances of the original op (`opt_plus` for the additive entry, `opt_mult` for the multiplicative entry). Line inheritance per-op unchanged from v1.
- Log `:reassociated` with the pass name `:arith_reassoc` and the op's `chain_line`. The log entry does NOT carry the operator — the reader can distinguish `+` from `*` chains by reading the file+line if needed. This keeps the existing Log structure unchanged.

**Two-level fixpoint.** Inner fixpoint per operator (v1's shape); outer fixpoint across the whole table:

```ruby
loop do
  any_outer = false
  REASSOC_OPS.each do |op_spec|
    loop do
      break unless rewrite_once(insts, function, log, object_table, op_spec: op_spec)
      any_outer = true
    end
  end
  break unless any_outer
end
```

**Why the outer loop is needed** (and why this is a v1-spec correction, not an edge case): operators interact one-way. A mult rewrite can remove an `opt_mult` from the middle of a sequence, converting `... putobject 2; putobject 3; opt_mult ...` into `... putobject 6 ...`. That `putobject 6` is a single-push producer; the `opt_mult` wasn't. So a mult rewrite can expose a `+` chain that plus's first fixpoint missed, because plus's chain-detection stopped at the `opt_mult`. Concrete case: `x + 2 * 3 + 4`. Plus scans first, bails at `opt_mult`, does nothing. Mult folds `2*3 → 6`. Plus needs another shot to collapse `x + 6 + 4 → x + 10`. The outer loop gives it that shot.

The reverse direction does not occur: plus rewrites only touch `opt_plus` and producer instructions; they never remove an `opt_mult`, so plus cannot expose a new mult chain. If future operators are added that introduce new one-way exposures, the outer loop already handles them.

Termination: each rewrite strictly shrinks `insts.size` by at least 2 (v1 argument, unchanged). The outer loop runs at most `O(insts.size / 2)` iterations.

**Pipeline ordering.** Unchanged: `[ArithReassocPass.new, ConstFoldPass.new]`. ConstFoldPass already mops up any residual all-literal adjacency in arith's output, and in v2 the `opt_mult` row can produce such residues just like v1's row does.

## Overflow: `fits_fixnum?`

Ruby's fixnum on 64-bit CRuby occupies bits 1..62 of the tagged-pointer representation; the signed fixnum range is `-(2**62) .. (2**62 - 1)`. `ObjectTable#intern` in v1 is scoped to special-const and will reject Bignums.

Predicate:

```ruby
FIXNUM_MAX = (1 << 62) - 1
FIXNUM_MIN = -(1 << 62)
def fits_fixnum?(n) = n.is_a?(Integer) && n >= FIXNUM_MIN && n <= FIXNUM_MAX
```

The predicate deliberately bakes in 64-bit CRuby. 32-bit is out of scope for the talk; if it ever matters, this is one constant and one method to change.

Logging when the guard fires: `log.skip(pass: :arith_reassoc, reason: :would_overflow_fixnum, file:, line:)`. The chain is left alone; the VM will handle the bignum promotion at runtime as it did before the pass.

## Logging

Reuse `Log#skip(pass:, reason:, file:, line:)` with reasons:

- `:reassociated` — success, one entry per chain rewritten. (Unchanged.)
- `:mixed_literal_types` — chain contained a non-Integer literal. (Unchanged.)
- `:chain_too_short` — chain had < 2 Integer literals. (Unchanged.)
- `:would_overflow_fixnum` — **NEW** — reduced result would not fit in a fixnum; chain left alone.

Pass name: `:arith_reassoc` (unchanged).

## Interface

Unchanged from v1:

```ruby
class Optimize::Passes::ArithReassocPass < Optimize::Pass
  def name = :arith_reassoc
  def apply(function, type_env:, log:, object_table: nil)
end
```

`REASSOC_OPS` is a public-enough constant that tests can assert on it (e.g., "the pass knows about `:opt_mult`"), but it is not part of the `Pass` base-class contract.

## Files

```
optimizer/
  lib/optimize/
    passes/
      arith_reassoc_pass.rb              # MODIFIED — table refactor + opt_mult row + overflow guard
  test/
    passes/
      arith_reassoc_pass_test.rb         # MODIFIED — new opt_mult tests + overflow test
      arith_reassoc_pass_corpus_test.rb  # UNCHANGED — already exercises Pipeline.default
  README.md                              # MODIFIED — Passes entry updated to mention opt_mult
```

No new files. The pipeline is unchanged (v1 already wired `ArithReassocPass` in). No new skip-reason key in Log's schema (Log accepts arbitrary symbols already).

## Test strategy

Mirror v1's structure, adding opt_mult and overflow cases.

1. **Refactor task (see "Plan shape" below):** v1's tests stay green after the one-entry-table refactor. This is the whole test strategy for that task.

2. **opt_mult unit tests** (hand-built IR via `RubyVM::InstructionSequence.compile` → `Codec.decode`):
   - `def f(x); x * 2 * 3 * 4; end; f(10)` → single `opt_mult`, literal `24`, `.eval == 240`.
   - `def f(x); 2 * x * 3; end; f(5)` → single `opt_mult`, literal `6`, `x` preserved as non-literal, `.eval == 30`.
   - `def f(x, y); 2 * x * 3 * y * 4; end; f(10, 5)` → two `opt_mult`, literal `24`, `x` before `y`, `.eval == 1200`.
   - `def f(x); x * 1.5 * 2; end` → `:mixed_literal_types`, chain untouched.
   - `def f(x); x * 2; end` → `:chain_too_short`, no rewrite.
   - `def f(x, y, z); x * y * z; end` → no literals, no rewrite, untouched.
   - `def f; 2 * 3 * 4; end; f` → all-literal chain rewrites to literal `24`, zero `opt_mult`, `.eval == 24`.

3. **Overflow unit test:**
   - `def f(x); x * 1_000_000 * 1_000_000 * 1_000_000; end` → product `1e18` exceeds `2**62 - 1 ≈ 4.6e18`? Actually `1e18 < 2**62` (`2**62 ≈ 4.6e18`), so this stays in fixnum. Use `def f(x); x * (1 << 30) * (1 << 30) * (1 << 10); end` → `2**70`, clearly bignum → expect `:would_overflow_fixnum`, chain untouched, `.eval` still equals un-optimized.
   - Sanity: pick a product that *just* fits (`2**62 - 1`) — confirm it folds and round-trips.
   - Sanity: pick a product that *just* overflows (`2**62`) — confirm it's skipped.

4. **End-to-end** for every unit test: round-trip through `Codec.encode` + `load_from_binary.eval` and compare to un-optimized evaluation.

5. **Corpus regression:** `arith_reassoc_pass_corpus_test.rb` already runs `Pipeline.default` across `optimizer/test/codec/corpus/*.rb`. No changes needed; it will automatically cover the opt_mult path.

6. **Cross-operator interaction test (in-pass):** `def f(x); x + 2 * 3 + 4; end; f(10)` — within a single `ArithReassocPass.apply` call, confirm the outer fixpoint fires: mult collapses `2 * 3 → 6`, then plus re-runs and collapses `x + 6 + 4 → x + 10`. Assert the rewritten function has exactly one `opt_plus`, zero `opt_mult`, a literal `10`, and `.eval == 20`. This test locks in the outer-fixpoint behavior; without it the arith pass alone would only collapse the mult part.

7. **Interaction with const-fold (pipeline-level):** confirm `Pipeline.default` handles the same shape end-to-end. This is largely redundant with (6) plus the existing corpus test, but worth a targeted case for the talk slide.

8. **v1 regression:** every v1 test (additive chains, mixed-literal skip, chain-too-short skip, fixpoint, leader-crossing) remains green after both tasks.

## Interaction with const-fold

Unchanged from v1. ConstFoldPass runs second and catches any residual all-literal `(lit, lit, op)` triple that arith produced. With two operators in v2, ConstFoldPass's existing triple scan already covers `(lit, lit, opt_plus)` and `(lit, lit, opt_mult)` — no work needed.

## Not changing

- `Pass#apply` signature.
- `Pipeline.default` — already `[ArithReassocPass, ConstFoldPass]` from v1.
- `LiteralValue` / `ObjectTable#intern` scope.
- v1's `opt_plus` test expectations — the refactor task must preserve them verbatim.
- `SINGLE_PUSH_OPERAND_OPCODES` — shared across operators; no per-op allowlist.
- `IR::Function#splice_instructions!` — already handles arbitrary opcode replacements.

## Plan shape

Two tasks in the v2 plan (the brainstorming settled on (ii) — separate refactor commit):

- **Task 1: Refactor v1 to a one-entry `REASSOC_OPS` table.** Pure refactor: `apply` becomes a `REASSOC_OPS.each` loop with one entry; `detect_chain` and `try_rewrite_chain` take `op_spec:`. Identity value `0` and reducer `:+` move into the table entry. Zero behavior change; all 125 existing tests stay green. Commit: "ArithReassocPass: refactor to REASSOC_OPS table (no behavior change)".

- **Task 2: Add `opt_mult` row + outer table fixpoint + overflow guard + tests.** Append the multiplicative entry to `REASSOC_OPS`. Wrap the per-operator fixpoint in the outer any-rewrite fixpoint described in "Two-level fixpoint" above. Add `FIXNUM_MAX`/`FIXNUM_MIN` constants and `fits_fixnum?`. Add `:would_overflow_fixnum` skip-reason handling in `try_rewrite_chain`. Add opt_mult unit tests, the overflow sanity tests, and a cross-operator interaction test (`x + 2 * 3 + 4 → x + 10`). Commit: "ArithReassocPass: add opt_mult row + fixnum-overflow guard + cross-op fixpoint".

- **Task 3 (optional, only if README drifts):** README + benchmark. v1's README entry can be lightly edited to mention opt_mult alongside opt_plus, and one benchmark (`x * 2 * 3 * 4` vs `x * 24`) recorded. Commit: "Document ArithReassocPass opt_mult; record opt_mult benchmark baseline".

The plan writer may collapse Task 3 into Task 2 if the README change is small enough.

## Success criteria

1. After Task 1: all 125 existing tests green. No behavior change.
2. After Task 2: 125 + N new tests green, where N ≈ 10 (opt_mult unit + overflow sanity + end-to-end + interaction-with-const-fold). Corpus regression green.
3. A talk slide exists with `x * 2 * 3 * 4` before/after disassembly, paired with the v1 additive slide.
4. The `REASSOC_OPS` constant is the design. A reader who finds the pass file and reads only that constant can predict the pass's behavior.
