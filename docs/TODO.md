# TODO — Roadmap gap

Snapshot of what the original specs (docs/superpowers/specs/2026-04-19-*)
called for vs. what has actually shipped. Use this as the starting-point
reference when opening a new session.

Last updated: 2026-04-27 (after ConstFoldEnvPass — ENV.fetch literal-key fold).

## Three-pass plan: status

| Pass | Original scope | Shipped | Remaining |
|---|---|---|---|
| Inlining | Full pass — call-graph, receiver resolution via RBS, wrapper-method flattening, CFG splicing | v1+v2: zero-arg and one-arg FCALL inline (constant-body, single-local callees) with local-table growth + level-0 LINDEX shift | multi-arg, kwargs, blocks, receivers via RBS, CFG splicing across BBs |
| Arithmetic specialization | Reassoc of `+ - * / %` chains under "no BOP redef"; RBS-typed operands; sub-chain folding; post-inlining collapse | ArithReassoc v1–v4 (`opt_plus`, `opt_mult`, `opt_minus`, `opt_div`) + IdentityElim v1. **Literal-only operands, no RBS typing.** | `opt_mod`; true Integer-typed operand proofs; post-inlining demo |
| Constant folding | 4 tiers: literal / frozen-constant / type-guided identity / ENV | Tier 1 (ConstFoldPass, now also String==String/String!=String). Tier 2 (ConstFoldTier2Pass): top-level frozen constants with literal RHS — Integer/String/true/false/nil — whole-tree pre-scan; reassigned or non-top-level names are tainted. Cascades through Tier 1 (e.g. `FOO + 1 → 43`). Tier 3 *partially* via IdentityElim v1 (sound-in-practice, not type-guided). Tier 4 (ConstFoldEnvPass): `ENV["LIT"]` fold with whole-IR-tree taint pre-scan; String snapshot values interned on-the-fly (no skip); read-only sends (`fetch`, `to_h`, `key?`, …) no longer taint the tree (argc≤1); `ENV.fetch("LIT")` argc=1 is now folded when snapshot carries the key (snapshot-presence check preserves runtime KeyError semantics; `:fetch_key_absent` log on miss). | Tier 3 proper (RBS-typed identities). Tier 2 follow-ups: Symbols, nested `M::FOO`, frozen Array/Hash literals. Tier 4 follow-ups: argc≥2 safe sends, block-passing sends, `ENV.fetch(LIT, default)`, generic `send` opcode. |

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

1. **RBS type environment.** Prerequisite for "sound in principle"
   across every pass and for the object-y `Point#distance_to` demo.
   Big spec on its own (~option F in the session-ladder history). v2
   inlining shipped, so the next narrative beat is receiver-resolution
   which this unblocks.
2. **Demo programs wired end-to-end** with benchmark harness output.
   Open questions before building: (a) talk-time output shape — static
   iseq dump slide, live `benchmark_ips`, or both? (b) fixture
   location — probably `optimizer/examples/`? (c) does it round-trip
   through full `Pipeline.default` or a named subset? (d) what's the
   "before" baseline — unoptimized iseq, or a `-O0` variant? v1 pick is
   `sum_of_squares` (likely `def sum_of_squares(n); (1..n).sum { |x| x*x }; end`);
   `Point#distance_to` blocks on RBS. Confirm exact shape against
   `docs/superpowers/specs/2026-04-19-talk-structure-design.md`.
3. ~~**Const-fold Tier 2 (frozen constants).** Needs the
   constant-assignment scanner but is otherwise self-contained.~~
   **Shipped 2026-04-26.** Plan: `docs/superpowers/plans/2026-04-26-const-fold-tier2.md`.
4. **`opt_mod`** in the arith family. Non-commutative/associative —
   skip-heavy, small fold set. May not justify its own slide.
5. **Claude Code gag pass.** §7 close. Scripted output is fine.
6. **Tier 4 classifier v2 — argc-generic safe sends.** Extend
   `ConstFoldEnvPass#consumer_safe?` to look at `insts[i + 1 + argc]`
   for argc 0..MAX_SAFE_ARGC (3 is plenty). Unlocks
   `ENV.values_at("A","B","C")` without tainting. Half-session slice.
   Validate by flipping `test_env_values_at_two_args_still_taints_v1`
   to "does not taint" and adding an argc=3 companion.
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

Filed in session memory / pass-identity-elim-design but not yet picked up:

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

## Explicitly out of scope (original talk-structure spec)

Kept here so future sessions don't rediscover these:

- Dead-branch elimination as its own pass (we emit folded branch
  conditions; if the VM's own optimizer collapses the dead arm, we
  benefit; otherwise we live with it).
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

## Maintenance note

When you finish a roadmap item, **update this file in the same commit**
as the work. Keep the "Three-pass plan: status" table accurate — it's
the one future sessions read first.
