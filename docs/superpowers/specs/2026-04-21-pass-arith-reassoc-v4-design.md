# Spec: Arithmetic Reassociation Pass — v4 (multiplicative group: opt_mult + opt_div)

**Part of:** [Ruby the Hard Way](2026-04-19-talk-structure-design.md)
**Extends:** [ArithReassocPass v3](2026-04-21-pass-arith-reassoc-v3-design.md) — v3 ships the additive group (`opt_plus` + `opt_minus`) driven by `REASSOC_GROUPS` with an abelian reduction algorithm; v4 adds a second *kind* of group — `:ordered` — to handle multiplicative chains that include integer division.
**Depends on:** v3 shipped (`REASSOC_GROUPS`, two-level fixpoint, `INTERN_BIT_LENGTH_LIMIT` guard, sign-aware rewrite for abelian groups), `LiteralValue` helper, `ObjectTable#intern` (special-const only), `IR::CFG.compute_leaders`, `IR::Function#splice_instructions!`.

## Purpose

Cover the multiplicative group, including `opt_div`. `x * 2 * 3 → x * 6` (v2's shape) and `x / 2 / 3 → x / 6` (new) are what this pass now nails; chains like `x * 2 * 3 / 4 / 5 → x * 6 / 20` are the interesting mixed case. v4 is also the spec that earns the word *kind* on the talk slide: v3's group shape assumed an abelian reduction (partition non-literals by sign, inject literals via a single combiner). That algorithm is unsound for `*`/`/` — Ruby integer `/` is floor-division, not field inversion, so `(a * L1) / L2 ≠ a * (L1 / L2)` in general. v4 is the moment the pass grows a second algorithm, dispatched by a new `kind:` field on each group entry.

## Scope

One structural change and one transformation:

1. Each `REASSOC_GROUPS` entry gains a `kind:` field (`:abelian` or `:ordered`). The existing additive entry becomes `kind: :abelian`. The existing single-op multiplicative entry is *replaced* by a richer entry `{ ops: { opt_mult: :*, opt_div: :/ }, identity: 1, primary_op: :opt_mult, kind: :ordered }`. `try_rewrite_chain` dispatches on `kind:` to either the existing v3 algorithm (`:abelian`) or a new ordered-fold algorithm (`:ordered`).
2. The new `:ordered` algorithm walks the chain left-to-right with a single literal accumulator, folding contiguous same-op literal runs (`* L1 * L2 → * (L1·L2)` and `/ L1 / L2 → / (L1·L2)`) but refusing to fold across a `*`/`/` boundary. Chains with any `≤0` literal divisor are bailed wholesale.

### Explicitly in

- Multiplicative chains containing any mix of `opt_mult` and `opt_div` links, Integer literals only (all literal divisors must be `> 0`), fold per the run-decomposition rule described below.
- Pure `opt_mult` chains continue to fold as v2 did — the `:ordered` algorithm reduces to v2's behavior when no `/` is present.
- Non-literal operands in the chain are preserved in original position. The `:ordered` algorithm does not reorder non-literals, and it does not reorder literals across a non-literal.
- Skip with new reason `:unsafe_divisor` when any `(opt_div, lit)` in the chain has `lit ≤ 0` or `lit` is a non-Integer literal. Chain left alone so CRuby's runtime trap (ZeroDivisionError) and floor-div sign semantics are preserved at the original call site.
- Skip with new reason `:no_change` when the walk produces a stream identical in shape to the input. Required to keep the outer fixpoint idempotent — without it, re-emitting an unchanged-but-canonicalized chain loops.
- Overflow guard unchanged in intent: `fits_intern_range?` with `bit_length < 62`, symmetric across negative values. The check now runs on *every* committed literal (the ordered algorithm can emit multiple literals, e.g. `x * 6 / 20`), not once on a single reduced value.
- Cross-group fixpoint: existing v3 two-level loop handles mixed shapes like `x + 2 * 3 - 4 → x + 2` and now also mixed shapes involving `/`, e.g. `x + 6 / 2 + 1`.
- A task-1 pure refactor (add `kind:` field + dispatch, replace multiplicative entry), zero behavior change on the existing test suite, all 148 existing tests stay green.
- A task-2 implementation of the `:ordered` algorithm, new skip reasons, and tests.

### Explicitly out (deferred to later plans)

- **Exact-divisibility folds.** `x * 6 / 2 → x * 3` is sound (`2 | 6`, divisor positive) but requires an exact-divisibility simulator rather than the run-decomposition rule. Brainstormed as option (iii); deferred to a hypothetical v4.1. The `:ordered` algorithm here leaves `x * 6 / 2` unchanged.
- **Negative literal divisors.** Ruby floor-div with negative divisors (`5 / -2 = -3`, not `-2`) means associativity breaks sign-dependently. v4 bails on any `≤0` literal divisor rather than encode the case analysis. A future pass could specialize.
- **`**`.** Right-associative, non-commutative. Never joins any reassociation group.
- **Bignum literals in `ObjectTable#intern`.** Same deferral as v1/v2/v3. Overflow is skipped with `:would_exceed_intern_range`. Note: the known bignum-codec segfault (v2 follow-up 1, bit_length ≳ 30) is unchanged by v4. Chains that fold to a large-but-in-range result (`bit_length < 62`) will still trip it if they flow through `iseq_to_binary`; v4 does not make this worse but also does not fix it.
- **Leading-negative unary emission for the additive group.** Unrelated to v4.
- **Non-literal reordering for `:ordered` groups.** The `:ordered` algorithm does not reorder non-literals. A chain like `x * y * 2 * 3` still folds (both non-literals stay put, literals `2`, `3` coalesce at the tail of their contiguous run).
- **RBS-driven typing of non-literal operands, cross-block chains, multi-instruction operand producers.** Same deferral as v1/v2/v3.

## Algorithm

**Groups table.** The class carries:

```ruby
REASSOC_GROUPS = [
  { ops: { opt_plus: :+, opt_minus: :- }, identity: 0, primary_op: :opt_plus, kind: :abelian },
  { ops: { opt_mult: :*, opt_div:   :/ }, identity: 1, primary_op: :opt_mult, kind: :ordered },
].freeze
```

`kind:` is the new field. `:abelian` preserves v3's algorithm verbatim. `:ordered` selects the new walker.

Task 1 lands the `kind:` field with both existing entries at `:abelian` and the multiplicative entry still single-op (`{opt_mult: :*}`). No behavior change yet.

Task 2 flips the multiplicative entry to `kind: :ordered` with both ops, and implements the `:ordered` walker.

**Chain detection.** `detect_chain` is unchanged. The link predicate is still `group[:ops].key?(insts[op_j].opcode)`, which naturally picks up `opt_div` once it's in the `ops` map. `SINGLE_PUSH_OPERAND_OPCODES` is unchanged. The returned `op_positions` and `producer_indices` shape is unchanged.

**Dispatch.** `try_rewrite_chain` branches on `group[:kind]`:

```ruby
case group[:kind]
when :abelian then try_rewrite_chain_abelian(...)   # v3's body, renamed
when :ordered then try_rewrite_chain_ordered(...)   # new
end
```

The shared preamble (classify producers via `LiteralValue`, compute `chain_line`) can stay at the top of `try_rewrite_chain` or be duplicated in each branch — implementation choice, no behavioral consequence. Plan will specify.

**`:ordered` algorithm.** Build an op-tagged operand stream from the chain:

```
stream = [(primary_op, p_0), (op_positions[0].opcode, p_1), ..., (op_positions[-1].opcode, p_n)]
```

where `p_0` is the leading producer (it has no preceding op in source, so we assign the group's `primary_op`) and each subsequent `op_k` is the opcode of the op immediately to the left of `p_k` in source order.

**Pre-scan guards** (performed before any walk):

- If any `(opt_div, lit)` in the stream has `lit <= 0` or `lit` is a non-Integer literal → log `:unsafe_divisor`, return `false`.
- If any other literal in the stream is a non-Integer → log `:mixed_literal_types`, return `false`. (Matches v3.)
- If the stream contains fewer than 2 integer literals → log `:chain_too_short`, return `false`. Coarse filter; the walk's `:no_change` bail is the fine filter.

**Walk.** Maintain:

- `emitted`: list of `(op, operand)` pairs.
- `acc`: `{value: Integer, line: Integer}` or `nil` — pending literal accumulator.
- `acc_op`: `:opt_mult` or `:opt_div` — the op that will combine `acc` with whatever precedes it in `emitted`.

For each `(op_k, p_k)`:

- **p_k is an Integer literal:**
  - If `acc` is `nil` → start: `acc = {value: p_k.value, line: p_k.line}`, `acc_op = op_k`.
  - Else, if `acc_op == op_k` (same-op literal run — either `*` followed by `*`, or `/` followed by `/`) → `acc.value = acc.value * p_k.value`. (Note: for the `/`-run case, literal divisors coalesce into a single larger divisor via `*`, not via `/` — `(a/L1)/L2 = a/(L1·L2)`.)
  - Else (`*`/`/` boundary between two literals) → commit `(acc_op, acc)` to `emitted`, start new `acc = {value: p_k.value, line: p_k.line}`, `acc_op = op_k`.
- **p_k is non-literal** (or a classified-out non-Integer, which would have been caught by the pre-scan):
  - If `acc` is not `nil` and `acc_op != op_k` (this non-literal sits on the *other* side of a `*`/`/` boundary from the accumulator) → commit `(acc_op, acc)` to `emitted`, then `acc = nil`. Otherwise the accumulator survives: within a same-op run, literals freely commute past non-literals (sound by `*`-commutativity inside a pure-`*` sub-run; sound by the integer floor-div identity inside a pure-`/` sub-run, given the positive-literal guarantee from the pre-scan).
  - Append `(op_k, p_k)` to `emitted`.

  **Why this rule, not "commit on every non-literal":** a stricter "commit on every non-literal" would fail to fold v2-compatible chains like `x * y * 2 * 3`, because the two `*`-literals sit on opposite sides of a `*`-non-literal. v2 commutes those literals through because `*` is abelian within a pure-`*` run. The same reasoning carries over here: inside a same-op sub-run the algebra is still abelian. The `*`/`/` boundary is the only place where order actually matters, and it's exactly where this rule forces a commit.

After the walk: if `acc` is not `nil`, commit it.

**Fits-intern check.** Once the walk completes, check `fits_intern_range?(committed.value)` for every committed literal in `emitted`. If any fail → log `:would_exceed_intern_range`, return `false`.

**No-change check.** Compute `literal_count(stream)` and `literal_count(emitted)`. If equal → log `:no_change`, return `false`. This is the idempotence guarantee for the outer fixpoint.

**Emission.** Walk `emitted` in order, building the instruction replacement:

- Index 0: `push p_0.inst` if non-literal, or `putobject acc.value` if a committed literal. The leading entry's op is the primary op (`opt_mult`), which is implicit — no op instruction emitted before the first push.
- Index `k > 0`: `push p_k.inst` / `putobject acc.value`, followed by an op instruction `IR::Instruction.new(opcode: op_k, operands: first_op_inst.operands, line: first_op_inst.line)`.

This yields `push v_0; push v_1; op_1; push v_2; op_2; …` — the same "interleaved" layout v3 adopted, which is semantically identical to v1/v2's "all pushes first, all ops last" for commutative/associative ops and also valid for ordered mixed-op chains.

**Examples** (semantics table):

| Chain | Stream | Emitted | Output |
|---|---|---|---|
| `x * 2 * 3` | `(*,x) (*,2) (*,3)` | `(*,x) (*,6)` | `x * 6` (v2 regression) |
| `x / 2 / 3` | `(*,x) (/,2) (/,3)` | `(*,x) (/,6)` | `x / 6` |
| `2 * 3 / 6 * x` | `(*,2) (*,3) (/,6) (*,x)` | `(*,6) (/,6) (*,x)` | `6 / 6 * x` (no further fold; see insight) |
| `x * 2 / 3 * 4` | `(*,x) (*,2) (/,3) (*,4)` | identical | unchanged, `:no_change` |
| `x * 2 * 3 / 4 / 5` | `(*,x) (*,2) (*,3) (/,4) (/,5)` | `(*,x) (*,6) (/,20)` | `x * 6 / 20` |
| `x / 0` | bail `:unsafe_divisor` | — | unchanged; CRuby traps at runtime |
| `x / -3 / -2` | bail `:unsafe_divisor` | — | unchanged |
| `x * y * 2 * 3` | `(*,x) (*,y) (*,2) (*,3)` | `(*,x) (*,y) (*,6)` | `x * y * 6` (v2 behavior preserved) |

**Why `2 * 3 / 6 * x → 6 / 6 * x` does not further reduce.** An exact-divisibility simulator would fold `6 / 6 → 1`, then `1 * x → x`. The `:ordered` rule is deliberately coarser: it folds contiguous same-op literal runs but does not fold a literal `/ L2` into a preceding accumulated-literal `* L1` by integer division, because the general case requires exact-divisibility reasoning that also has to survive non-literal reordering (which `:ordered` doesn't do). Trading this class of fold for a one-sentence rule is the explicit design choice.

**Safety of the rule** (informal argument):

- Same-op `*`-run: `(a * L1) * L2 = a * (L1 * L2)` — standard associativity.
- Same-op `/`-run: `(a / L1) / L2 = a / (L1 * L2)` when `L1, L2` are positive integers — standard integer floor-div identity, guaranteed by the `≤0` pre-scan.
- `*`/`/` boundary between literals: `(a * L1) / L2` is emitted unchanged (`L1` and `L2` remain separate committed literals). No algebraic rewrite happens across the boundary.
- Non-literal operands: always emitted in original position with their original op. The `:ordered` walker never reorders non-literals. *Literals*, however, may commute past a non-literal when both sit inside the same same-op sub-run (e.g. `x * y * 2 * 3 → x * y * 6` folds the `2` and `3` past the `x * y` prefix). That motion is sound: `*` is abelian within a pure-`*` run, and `/` is right-associative-across-positive-literals within a pure-`/` run. The `*`/`/` boundary is the only place where order matters, and it's exactly where the walker forces a commit.

**Two-level fixpoint.** Unchanged from v3. A successful `:ordered` rewrite strictly shrinks the literal count in the chain (same-op run of N literals collapses to 1), so termination is guaranteed by the existing argument. The `:no_change` bail handles the edge where `literal_count(emitted) == literal_count(stream)`.

**Pipeline ordering.** Unchanged: `[ArithReassocPass, ConstFoldPass]`. `ConstFoldPass` already handles `opt_mult` and `opt_div` (both are in `ConstFoldPass::BINOPS`), so any residual all-literal triple that the ordered walk emits (e.g. the `6 / 6` in the boundary example) is mopped up by const-fold on the next pipeline step.

## Logging

Reuse `Log#skip(pass:, reason:, file:, line:)` with reasons:

- `:reassociated` — success, one entry per chain rewritten. (Unchanged.)
- `:mixed_literal_types` — chain contained a non-Integer literal. (Unchanged.)
- `:chain_too_short` — chain had fewer than 2 Integer literals. (Unchanged.)
- `:would_exceed_intern_range` — any committed literal fails `fits_intern_range?`. (Existing reason; now may fire on any of multiple committed literals, not just a single reduced value.)
- `:no_positive_nonliteral` — **abelian-only.** Unchanged from v3. Never fires for `:ordered`.
- `:unsafe_divisor` — **NEW** — any `(opt_div, lit)` in the chain has `lit ≤ 0` or is non-Integer. Chain left alone.
- `:no_change` — **NEW** — the `:ordered` walk produced an emitted stream with the same literal count as the input. Chain left alone to preserve fixpoint idempotence.

Pass name: `:arith_reassoc` (unchanged).

The log entry does not carry the operator, the group identity, or the `kind`. As before, a reader distinguishes additive from multiplicative chains, and `:abelian` from `:ordered` paths, by reading the file+line.

## Interface

Unchanged from v1/v2/v3:

```ruby
class Optimize::Passes::ArithReassocPass < Optimize::Pass
  def name = :arith_reassoc
  def apply(function, type_env:, log:, object_table: nil)
end
```

`REASSOC_GROUPS` remains a pass-private constant that tests may read. The addition of the `kind:` field and the `opt_div: :/` entry are the only structural differences.

## Files

```
optimizer/
  lib/optimize/
    passes/
      arith_reassoc_pass.rb              # MODIFIED — kind: field + :ordered walker
  test/
    passes/
      arith_reassoc_pass_test.rb         # MODIFIED — v4 unit tests
      arith_reassoc_pass_corpus_test.rb  # MODIFIED — add mixed */ corpus fixture
  test/codec/corpus/
    arith_multdiv.rb                     # NEW — corpus fixture exercising * and / chains
README.md                                # MODIFIED — mention opt_div in the multiplicative-group row, note :ordered kind
```

No new public interfaces.

## Test strategy

All unit tests hand-build IR via `RubyVM::InstructionSequence.compile` → `Optimize::Codec.decode`; round-trip every case through `Optimize::Codec.encode` + `RubyVM::InstructionSequence.load_from_binary(...).eval` and compare to un-optimized evaluation. Tests are routed through the `ruby-bytecode` MCP tools (no host shell).

1. **Task 1 (refactor):** all 148 existing tests green, zero new tests. The `kind:` field is added with both entries at `:abelian` (multiplicative still single-op, behavior identical to v3).

2. **Task 2 unit tests:**

   - `def f(x); x / 2 / 3; end; f(60)` → one `opt_div`, zero `opt_mult`, literal `6`, `.eval == 10`. Baseline same-op `/` fold.
   - `def f(x); x * 2 * 3 / 4 / 5; end; f(100)` → one `opt_mult`, one `opt_div`, literals `6` and `20`, `.eval == 30`. Mixed-run fold.
   - `def f(x); 2 * 3 / 6 * x; end; f(5)` → literals `6` and `6`, one `opt_mult`, one `opt_div`, one push of `x`, `.eval == 5`. Verifies the `*`/`/` boundary does not allow `6/6` to further reduce within this pass. Const-fold (run after arith_reassoc in the default pipeline) is expected to mop this up; the unit test asserts the *arith_reassoc* output shape, and a separate pipeline-level test asserts the post-const-fold shape.
   - `def f(x); x * 2 / 3 * 4; end; f(6)` → chain untouched, `:no_change` logged, `.eval == 16`. Verifies the boundary bail.
   - `def f(x); x / 0; end` → chain untouched, `:unsafe_divisor` logged. Confirm that `RubyVM::InstructionSequence.load_from_binary(...)` still compiles and that calling the method raises `ZeroDivisionError` at the original site (not at a folded-away compile-time error).
   - `def f(x); x / -3 / -2; end; f(12)` → chain untouched, `:unsafe_divisor` logged. `.eval` of the optimized iseq equals `.eval` of the unoptimized iseq.
   - `def f(x); x * 2 * 3; end; f(5)` → v2 regression. Literal `6`, `.eval == 30`. Confirms pure-`*` behavior preserved under `:ordered`.
   - `def f(x); x * 2 * 1.5; end` → `:mixed_literal_types`, chain untouched.
   - `def f(x); x / 2 / "foo"; end` → `:unsafe_divisor` (the pre-scan's `(opt_div, lit)` non-Integer check fires before the general `:mixed_literal_types` scan). Chain untouched.
   - `def f(x); x * (1 << 31) * (1 << 31); end` → reduced product `2^62` overflows `bit_length < 62`. `:would_exceed_intern_range`, chain untouched.
   - `def f(x, y); x * y * 2 * 3; end; f(5, 4)` → literals fold to `6`, one `opt_mult` between x/y and another between y and `6`. `.eval == 120`. Non-literals preserved in original position.
   - `def f(x); x * 2 * 3; x * 2 * 3; end` — idempotence. Run the pass twice; assert the second run produces zero rewrites (`:no_change` or chain already absent).
   - `def f(x); x * 2 * 3 / 4 / 5; x * 2 * 3 / 4 / 5; end` — same idempotence test for the mixed case.

3. **Cross-group interaction test:**

   - `def f(x); x + 6 / 2 + 1; end; f(10)` — within a single basic block, the multiplicative `:ordered` pass is a no-op (`6 / 2` is a same-op-run of length 1 embedded in an additive chain; detection picks up only the additive chain). `ConstFoldPass` folds `6 / 2 → 3`, then arith_reassoc's outer fixpoint folds `x + 3 + 1 → x + 4`. Locks in pipeline behavior for mixed `*`/`/` inside an additive context.

4. **Corpus test** (`optimizer/test/codec/corpus/arith_multdiv.rb`, new fixture):

   - A small program with several `*`/`/` chains — `x / 2 / 3`, `x * 2 * 3 / 4 / 5`, `2 * 3 / 6 * x`, at minimum. Corpus runner asserts: (a) disasm before vs after differs in the expected shape, (b) `run_ruby` on the optimized iseq produces identical output to `run_ruby` on the unoptimized iseq across a small set of inputs (at minimum: positive, zero, negative operands for non-literal slots). This is the real soundness net.

5. **v1/v2/v3 regression:** every pre-existing test green after both tasks. Particular attention to the v2 multiplicative regression tests, since the multiplicative entry is being replaced.

## Interaction with const-fold

`ConstFoldPass` already covers `opt_mult` and `opt_div` in its `BINOPS` table. Residual all-literal triples that the `:ordered` walker emits (e.g. `6 / 6` in the boundary example) fold cleanly on the next pipeline step. No const-fold changes needed for v4.

One subtle point: if const-fold later folds `6 / 6 → 1` and then `1 * x` remains, const-fold's identity-elimination (if present) or a future multiplicative-identity pass could reduce further. v4 does not add this; const-fold's current scope is the baseline.

## Not changing

- `Pass#apply` signature.
- `Pipeline.default` — still `[ArithReassocPass, ConstFoldPass]`.
- `LiteralValue` / `ObjectTable#intern` scope.
- v1/v2/v3 test expectations — the Task 1 refactor (adding `kind:`) must preserve them verbatim.
- `SINGLE_PUSH_OPERAND_OPCODES` — shared across groups. The `:ordered` walker does not reorder non-literals, so the "side-effect-free w.r.t. each other" invariant is load-bearing only for `:abelian`. But: if a future `:ordered` variant wants to reorder, it must re-examine the same invariant.
- `IR::Function#splice_instructions!` — handles arbitrary opcode replacements.
- `Log` schema — new `:unsafe_divisor` and `:no_change` reasons are arbitrary symbols passed to `Log#skip`; no schema change.
- The bignum-codec segfault (v2 follow-up 1) remains open. v4 does not depend on it being fixed.

## Plan shape

Three tasks, mirroring v3's two-then-optional-third structure:

- **Task 1: Add `kind:` field to `REASSOC_GROUPS` + dispatch in `try_rewrite_chain`.** Both existing entries tagged `:abelian`. Multiplicative entry remains single-op (`{opt_mult: :*}`) — no `opt_div` yet. The `try_rewrite_chain` body is extracted into `try_rewrite_chain_abelian`, and the top-level `try_rewrite_chain` becomes a `case group[:kind]` dispatch with only the `:abelian` branch live. Zero behavior change. All 148 existing tests green. Commit: `ArithReassocPass: add kind: field to REASSOC_GROUPS (no behavior change)`.

- **Task 2: Flip multiplicative entry to `:ordered` + implement `:ordered` walker + tests.** Append `opt_div: :/` to the multiplicative entry's `ops` map and change `kind:` to `:ordered`. Implement `try_rewrite_chain_ordered`: pre-scan for `:unsafe_divisor`, `:mixed_literal_types`, `:chain_too_short`; build op-tagged stream; walk with `(acc, acc_op, emitted)`; per-commit `fits_intern_range?` check; `:no_change` bail; emission as interleaved `push; op; push; op; …`. Add the ~13 unit tests, the cross-group interaction test, and the corpus fixture. Commit: `ArithReassocPass: add :ordered kind + opt_mult/opt_div fold`.

- **Task 3 (optional; may collapse into Task 2): README + benchmark.** README passes entry updated to name the multiplicative-group contents (`opt_mult`, `opt_div`) and the `:ordered` kind. One `mcp__ruby-bytecode__benchmark_ips` run for `x * 2 * 3 / 4 / 5` vs `x * 6 / 20` recorded as the v4 baseline. Commit: `Document ArithReassocPass opt_div; record multiplicative-group benchmark baseline`.

## Success criteria

1. After Task 1: 148 existing tests green. No behavior change. `kind:` field is the sole structural difference in the pass file.
2. After Task 2: 148 + ~14 tests green (~13 v4 unit + 1 cross-group interaction + corpus fixture). `run_ruby` on optimized vs unoptimized iseqs produces identical output on the corpus fixture across positive/zero/negative inputs.
3. Talk slide: `x * 2 * 3 / 4 / 5` before/after disassembly, paired with the `x / 0` and `x / -3 / -2` bail cases as "here's what soundness with floor-div costs." The slide emphasizes that the multiplicative row grew one cell (`opt_div: :/`) *and* a new `kind:`, because the generic abelian algorithm stopped being sound.
4. The `REASSOC_GROUPS` constant, augmented with `kind:`, remains the design. A reader who finds the pass file and reads only that constant can predict which ops reassociate together, which kind of algorithm applies to each group, and — by noticing that `**` is absent and that `opt_div` appears only under `:ordered` — which design choices were deliberate.
