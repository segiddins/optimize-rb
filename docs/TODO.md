# TODO — Roadmap gap

Snapshot of what the original specs (docs/superpowers/specs/2026-04-19-*)
called for vs. what has actually shipped. Use this as the starting-point
reference when opening a new session.

Last updated: 2026-04-22 (after RBS type env v1 — receiver-resolving inlining for Point#distance_to).

## Three-pass plan: status

| Pass | Original scope | Shipped | Remaining |
|---|---|---|---|
| Inlining | Full pass — call-graph, receiver resolution via RBS, wrapper-method flattening, CFG splicing | v1+v2+v3: zero-arg and one-arg FCALL inline; typed-receiver argc=1 OPT_SEND inline (self-stash + putself-rewrite; permits nested plain sends in body; multi-local callees rejected). SlotTypeTable seeded from RBS signature params + Ruby 3.x/4.x .new constructor-prop; cross-iseq-level parent chain; Pipeline pre-builds slot_type_map + signature_map; callee_map keyed by [class_name, :mid] with definemethod fallback. INLINE_BUDGET bumped 8→16. End-to-end fixture lands 1 :inlined entry on the 1M.times { p.distance_to(q) } block. | multi-arg OPT_SEND (argc ≥ 2); getinstancevariable/setinstancevariable (VM-level GET_SELF limitation — attr_reader-style method calls work instead); callee-internal locals; kwargs; blocks; forward type-prop through arithmetic/assignment; subtype matching; constructor-prop across branches; CFG splicing across BBs. |
| Arithmetic specialization | Reassoc of `+ - * / %` chains under "no BOP redef"; RBS-typed operands; sub-chain folding; post-inlining collapse | ArithReassoc v1–v4 (`opt_plus`, `opt_mult`, `opt_minus`, `opt_div`) + IdentityElim v1. **Literal-only operands, no RBS typing.** | `opt_mod`; true Integer-typed operand proofs; post-inlining demo |
| Constant folding | 4 tiers: literal / frozen-constant / type-guided identity / ENV | Tier 1 (ConstFoldPass, now also String==String/String!=String). Tier 2 (ConstFoldTier2Pass): top-level frozen constants with literal RHS — Integer/String/true/false/nil — whole-tree pre-scan; reassigned or non-top-level names are tainted. Cascades through Tier 1 (e.g. `FOO + 1 → 43`). Tier 3 *partially* via IdentityElim v1 (sound-in-practice, not type-guided). Tier 4 (ConstFoldEnvPass): `ENV["LIT"]` fold with whole-IR-tree taint pre-scan; String snapshot values interned on-the-fly (no skip); read-only sends (`fetch`, `to_h`, `key?`, …) no longer taint the tree (argc≤1); `ENV.fetch("LIT")` argc=1 is now folded when snapshot carries the key (snapshot-presence check preserves runtime KeyError semantics; `:fetch_key_absent` log on miss). Taint classifier v2: read-only sends whitelist is argc-generic via forward-scan (first-send-encountered must match cd.argc and safe mid); `ENV.values_at("A","B","C")` siblings no longer taint. argc=2 `ENV.fetch(LIT, pure-default)` now folds — default must be a single pure producer (`putnil`/`putobject`/`put[chilled]string`/`putself`); on key hit the default is dropped, on miss the default becomes the fold result. Peephole **DeadBranchFoldPass** (2026-04-22) runs last in `Pipeline.default`: collapses `<literal>; branchif\|branchunless\|branchnil` to `jump target` (taken) or drop (not taken), cascading off every const-fold tier. | Tier 3 proper (RBS-typed identities). Tier 2 follow-ups: Symbols, nested `M::FOO`, frozen Array/Hash literals. Tier 4 follow-ups: block-passing sends, generic `send` opcode, non-String snapshot values. Full CFG-level DCE (remove unreachable blocks, patch catch-table). |

## Cross-cutting infrastructure not yet built

- **RBS inline signature parsing → type environment.** Called out in
  `2026-04-19-talk-structure-design.md` as what makes inlining and
  specialization *sound in principle*. Every shipped pass is literal-only
  because of this gap. Unblocks: inlining, RBS-typed arith, const-fold
  tier 3, upgrading IdentityElim's "sound in practice" guarantee.
- **Call graph / `resolve_call`.** Prerequisite for inlining.
- ~~**Constant-assignment scanner.** Prerequisite for const-fold tier 2.~~
  *Shipped 2026-04-26 as ConstFoldTier2Pass's in-pass whole-tree
  `scan_tree`. If a future pass needs to reuse it, extract a shared
  `const_table.rb` module — but v1 lives inside the pass.*
- **Demo programs.** The talk names two (`sum_of_squares` numeric kernel
  and `Point#distance_to` object-y method). Neither is wired. We've only
  benchmarked the synthetic `2*3/6*x → x` payoff.
- **Claude Code gag pass.** §7 of talk-structure. Not specced.

## Roadmap gap, ranked by talk-ROI

1. ~~**RBS type environment.**~~ **Shipped 2026-04-22.** Plan:
   `docs/superpowers/plans/2026-04-22-rbs-type-env-v1.md`. Spec:
   `docs/superpowers/specs/2026-04-22-rbs-type-env-v1-design.md`.
   Delivers receiver-resolving inlining for `Point#distance_to` end-to-end
   (SlotTypeTable + cross-level lookup + Pipeline wiring + InliningPass v3
   with self-stash). Follow-ups: RBS-typed IdentityElim/ArithReassoc
   (upgrades those passes from "sound in practice" to "sound in
   principle"); multi-arg OPT_SEND; subtype matching.
2. ~~**Demo programs wired end-to-end** with benchmark harness output.~~
   **Partially shipped 2026-04-22** (one fixture). Spec:
   `docs/superpowers/specs/2026-04-22-demo-programs-benchmark-harness-design.md`.
   Plan: `docs/superpowers/plans/2026-04-22-demo-programs-benchmark-harness.md`.
   Shipped: `RubyOpt::Demo::{Walkthrough,DisasmNormalizer,IseqSnapshots,Benchmark,MarkdownRenderer,Runner}`
   + `bin/demo` driver + YAML sidecars + `rake demo:verify` freshness
   check. `docs/demo_artifacts/point_distance.md` committed — shows a
   visible inlining diff at the `p.distance_to(q)` call site under
   `Pipeline.default`. Benchmark number (~1.01x) is honest: inlining
   shifts work from call-and-return to inline instructions without
   shrinking the receiver-method sequence. Follow-ups:
   - **`sum_of_squares` fixture blocked.** The Codec can't decode
     *any* `while` loop: `OFFSET raw=(2**64 - n) in branchif targets
     slot ... with no corresponding instruction`. Negative branch
     offsets aren't sign-extended in `codec/instruction_stream.rb:360`.
     File as a separate codec fix; once green, restore
     `examples/sum_of_squares.{rb,walkthrough.yml}` (they were
     reverted in `revert(examples): drop sum_of_squares …`) and
     regenerate `docs/demo_artifacts/sum_of_squares.md`.
   - `const_fold` + `dead_branch_fold` slides show `(no change)` for
     `point_distance`. Once post-inlining folds fire on the inlined
     body, expect cascading diffs there.
3. ~~**Const-fold Tier 2 (frozen constants).** Needs the
   constant-assignment scanner but is otherwise self-contained.~~
   **Shipped 2026-04-26.** Plan: `docs/superpowers/plans/2026-04-26-const-fold-tier2.md`.
4. **`opt_mod`** in the arith family. Non-commutative/associative —
   skip-heavy, small fold set. May not justify its own slide.
5. **Claude Code gag pass.** §7 close. Scripted output is fine.
6. ~~**Tier 4 classifier v2 — argc-generic safe sends.** Extend
   `ConstFoldEnvPass#consumer_safe?` to look at `insts[i + 1 + argc]`
   for argc 0..MAX_SAFE_ARGC (3 is plenty). Unlocks
   `ENV.values_at("A","B","C")` without tainting. Half-session slice.
   Validate by flipping `test_env_values_at_two_args_still_taints_v1`
   to "does not taint" and adding an argc=3 companion.~~
   **Shipped 2026-04-28.** Plan: `docs/superpowers/plans/2026-04-28-env-taint-classifier-v2.md`.
7. ~~**Tier 4 fold — `ENV.fetch("LIT")` with literal key.**~~
   **Shipped 2026-04-27.** Plan: `docs/superpowers/plans/2026-04-27-env-fetch-literal-key.md`.
8. **IdentityElim v2 — absorbing zero.** `x*0 → 0`, `0*x → 0`,
   `0/x → 0`. Extends v1 cleanly; `SAFE_PRODUCER_OPCODES` earns its
   keep. `0/x` needs the same ZeroDivisionError guard Tier 1 already
   has. Self-ops (`x-x → 0`, `x/x → 1`) need operand-equality and —
   for `x/x` — an `x≠0` argument; defer self-ops.
9. **ArithReassoc v3.1 — leading-negative emission.**
   `1 - x + 2 → 3 - x`. Currently skipped via `:no_positive_nonliteral`.
   Self-contained, small.

## Refinements of shipped work (not roadmap progress, but talk-adjacent)

### Polynomial-demo cascade gaps (filed 2026-04-22)

The `polynomial` demo (exercising inlining + tier 2 + tier 1 + identity
+ dead-branch-fold end-to-end) surfaced three places where passes
don't compose as tightly as the slide would suggest. Each is a
self-contained fix; none is a talk blocker.

- **InliningPass v3 leaves a redundant `setlocal/getlocal` round-trip
  at the stash site.** The self-stash + arg-stash emit
  `setlocal n@K; getlocal n@K` for a slot that's never read again
  before being overwritten. On `(n * 2 * SCALE / 12) + 0` with `n = 42`
  this breaks the literal-pair window that Tier 1 needs (`putobject
  42; setlocal n@1; getlocal n@1; putobject 2; opt_mult` — the
  `42; 2; opt_mult` triple isn't adjacent). Fix: emit a peephole
  cleanup in InliningPass (or a new pass) that drops
  `setlocal X; getlocal X` when the slot has no other reader between
  the stash and the next write. Would unlock Tier 1 cascading across
  inlined arguments — the polynomial demo's arithmetic would collapse.

- **ArithReassoc runs before Tier 2 / Inlining expose literal
  operands.** Pipeline.default order is `inlining → arith_reassoc →
  tier2 → … → tier1`. On the polynomial fixture, by the time Tier 2
  rewrites `SCALE` to `6`, arith_reassoc has already walked the
  chain and given up (it saw `42 * 2 * <getconstant> / 12`, couldn't
  reassociate across the non-literal). Fix option A: run
  arith_reassoc twice — once pre-Tier 2, once post-Tier 2 (and
  post-inlining). Option B: move arith_reassoc to after Tier 2 in
  Pipeline.default. Option B is probably right — it's strictly more
  informed. Check whether any existing test relies on the current
  order before swapping.

- **IdentityElim doesn't fire on `n + 0` when the `0` is
  `putobject_INT2FIX_0_` after a multi-instruction producer.** On
  `(… opt_div …) + 0`, the three-instruction window walker expects
  a simple literal producer for the LHS; the actual LHS is a whole
  arithmetic chain. Extend v1 to recognise `SAFE_PRODUCER_OPCODES`
  + `putobject_INT2FIX_0_` + `opt_plus` as a valid shape (drop the
  `INT2FIX_0_` producer and the `opt_plus`). Same treatment for
  `+ 0 / - 0 / * 1 / / 1` where the zero/one operand is the
  shortcut opcode (`putobject_INT2FIX_0_`, `putobject_INT2FIX_1_`).
  Once this lands, the polynomial demo's trailing `+ 0` will
  disappear — and by implication, IdentityElim should get a new
  walkthrough slide with a real diff instead of `(no change)`.

---

Filed in session memory / pass-identity-elim-design but not yet picked up:

- **RBS-typed IdentityElim / ArithReassoc.** Now that `SlotTypeTable`
  exists, extend IdentityElim's `x*1 → x` and ArithReassoc's literal
  folds to accept Integer-typed operands (not just literal integer
  operands). Use `slot_table.lookup(slot, level)` at each operand
  site to gate the rewrite. Self-contained follow-up; each pass is
  ~20 LoC. Upgrades both passes from "sound in practice" to "sound
  in principle" using v1's existing type plumbing.
- **InliningPass v4 — multi-arg OPT_SEND (argc ≥ 2).** Extends v3 by
  growing N+1 stash slots (self-stash + one per arg), mirroring the
  existing one-arg LINDEX math. Unblocks inlining `Point.new(x, y)`
  and any method with 2+ args. Key codec work already done in v2;
  v4 just generalizes the shift-by-N LINDEX remap.
- **IdentityElim v2** — absorbing zero (`x*0→0`, `0*x→0`, `0/x→0`) and
  self-ops (`x-x→0`, `x/x→1`). Extends v1's "sound in practice" story
  cleanly; absorbing zero is where `SAFE_PRODUCER_OPCODES` really earns
  its keep. Self-ops need operand-equality; `x/x` needs a `x≠0` argument.
- **ArithReassoc v3.1** — leading-negative unary emission
  (`1 - x + 2 → 3 - x`). Currently skipped via `:no_positive_nonliteral`.
  Small and self-contained.
- **ArithReassoc v4.1** — exact-divisibility folds (`x*6/2 → x*3`).
  Requires divisibility tracking in the `:ordered` walker.
- **ArithReassocPass helper extraction.** The `:abelian` and `:ordered`
  kind branches duplicate a ~10-line prologue. Worth extracting if a
  third kind lands.
- **InliningPass v3** — multi-arg FCALL inline (merge callee locals
  into caller table, rewrite all LINDEX refs, not just the +1 shift).
  Prerequisite for `Point#distance_to`-style demos taking 2+ args.
  Key codec work already done in v2 (`Codec::LocalTable` with `grow!`
  + encoder guard for body-record drift); v3 just needs a more general
  LINDEX-remap pass (shift by N, and merge callee-side slot indices
  past v2's "single local at EP 3" invariant).
- **Extract v2's LINDEX-shift loop into `LocalTable`.** Currently
  inlined in `InliningPass#try_inline_one_arg`; belongs next to
  `grow!` since the "local_table_size grew by 1 so EP offsets shift"
  reasoning lives in that module. Good first step into v3 — the
  extracted helper generalises to `shift_level0_lindex!(fn, by: N)`.

## Known bugs / blockers

- **Codec segfault on `putobject <int>` with `bit_length ≳ 30`** in
  CRuby's `load_from_binary`. Independent of the 9-byte small_value
  framing; lives in bignum-digit encoding (`object_table.rb:373`, uses
  `write_u64`/`read_u64`). Blocks the overflow-boundary test and any
  widening of `INTERN_BIT_LENGTH_LIMIT` (currently 62; effective safe
  limit is smaller because of this).
- **Codec fails to decode backward branches (`while` loops).**
  `codec/instruction_stream.rb:360` interprets a negative branch
  offset as a huge unsigned integer and aborts with
  `OFFSET raw=<2^64 - n> in branchif targets slot <2^64 - m> with
  no corresponding instruction`. Reproduces on any trivial loop,
  e.g. `def f(n); i=0; while i<n; i+=1; end; end`. Blocks the
  `sum_of_squares` demo fixture and any future loop-based demo.

## Explicitly out of scope (original talk-structure spec)

Kept here so future sessions don't rediscover these:

- ~~Dead-branch elimination as its own pass (we emit folded branch
  conditions; if the VM's own optimizer collapses the dead arm, we
  benefit; otherwise we live with it).~~ **Peephole variant shipped
  2026-04-22** as `DeadBranchFoldPass`: folds `<literal>; branchif|
  branchunless|branchnil` into `jump target` (taken) or a drop (not
  taken), feeding off whatever ConstFold*/IdentityElim produced.
  Runs last in `Pipeline.default`. Full CFG-level DCE (removing the
  now-unreachable basic blocks themselves, patching catch-table
  ranges) is still out of scope. Short-circuit extension same day:
  4-instruction window `<literal>; dup; branch*; pop` (the shape
  Ruby emits for `LIT && rhs` / `LIT || rhs`) folds when the short-
  circuit is NOT taken, dropping the prefix and leaving rhs intact.
  The taken case (`false && rhs`, `true || rhs` — rhs becomes dead
  code) requires deleting rhs up to the branch target, which is
  CFG-shaped and still out of scope.
- Non-Integer numerics (`Float`, `Rational`).
- `InstructionSequence.load_from_binary` / persistence as a *talk
  topic*. (Internally we rely on it and have shipped codec specs for
  bugs found there; it stays an implementation detail.)
- YJIT / MJIT comparison.
- Production hotspot war stories.

## Exploratory, not yet on any roadmap

- **Stack-type inference.** A cheaper alternative to full RBS parsing
  that could upgrade IdentityElim-style passes from "sound in practice"
  to "sound in principle" for numeric receivers. Big spec, but smaller
  than RBS.
- **Comparison-chain specialization** (`x < 10 && x > 0`). Would be the
  first pass to cross control flow.
- **Hoist frozen empty literals** (`[].freeze`, `{}.freeze`). Each call
  allocates a fresh object today; a pass could detect the
  `newarray 0 / newhash 0` + `opt_send_without_block :freeze` shape and
  rewrite to a single `putobject <frozen_empty>` that references an
  interned frozen `[]` / `{}` in the object table. Once interned, all
  call sites share the same VALUE — no per-call allocation. Depends on
  extending `ObjectTable#intern` to accept `Array`/`Hash` (currently
  special-const + String only after 2026-04-24). Talk-adjacent: a
  visible allocation-count delta in `benchmark_ips` / `ObjectSpace`.
- **Purity / idempotency annotations.** A contract-level marker
  (`# @pure` or `# @idempotent` on a def, or an allowlist of
  stdlib methods like `Math.sqrt`, frozen `String#+@`, etc.) that
  unlocks two new passes: (a) CSE-for-sends — two identical calls
  with identical args in the same basic block collapse to one
  compute + reuse; (b) dead-call elimination — a pure call whose
  result is dropped (`pop` immediately follows) is removed entirely.
  Under the contract-rule framing, same shape as the "no BOP redef"
  and "truthful RBS" rules — the programmer promises purity, the
  optimizer cashes it in. Not shipped; not specced. Worth a slide
  if the talk has time. Overlaps with the RBS-v1 story since purity
  could live alongside type annotations in the same rbs-inline
  comments.

## Maintenance note

When you finish a roadmap item, **update this file in the same commit**
as the work. Keep the "Three-pass plan: status" table accurate — it's
the one future sessions read first.
