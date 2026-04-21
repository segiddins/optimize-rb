# TODO — Roadmap gap

Snapshot of what the original specs (docs/superpowers/specs/2026-04-19-*)
called for vs. what has actually shipped. Use this as the starting-point
reference when opening a new session.

Last updated: 2026-04-21 (after InliningPass v1).

## Three-pass plan: status

| Pass | Original scope | Shipped | Remaining |
|---|---|---|---|
| Inlining | Full pass — call-graph, receiver resolution via RBS, wrapper-method flattening, CFG splicing | v1: zero-arg FCALL inline of constant-body callees (no locals, no branches, no catch, no nested sends) | args, receivers via RBS, wrapper flattening, CFG splicing |
| Arithmetic specialization | Reassoc of `+ - * / %` chains under "no BOP redef"; RBS-typed operands; sub-chain folding; post-inlining collapse | ArithReassoc v1–v4 (`opt_plus`, `opt_mult`, `opt_minus`, `opt_div`) + IdentityElim v1. **Literal-only operands, no RBS typing.** | `opt_mod`; true Integer-typed operand proofs; post-inlining demo |
| Constant folding | 4 tiers: literal / frozen-constant / type-guided identity / ENV | Tier 1 (ConstFoldPass). Tier 3 *partially* via IdentityElim v1 (sound-in-practice, not type-guided). | Tier 2 (frozen top-level constants), Tier 3 proper (RBS-typed identities), Tier 4 (ENV folding) |

## Cross-cutting infrastructure not yet built

- **RBS inline signature parsing → type environment.** Called out in
  `2026-04-19-talk-structure-design.md` as what makes inlining and
  specialization *sound in principle*. Every shipped pass is literal-only
  because of this gap. Unblocks: inlining, RBS-typed arith, const-fold
  tier 3, upgrading IdentityElim's "sound in practice" guarantee.
- **Call graph / `resolve_call`.** Prerequisite for inlining.
- **Constant-assignment scanner.** Prerequisite for const-fold tier 2.
- **Demo programs.** The talk names two (`sum_of_squares` numeric kernel
  and `Point#distance_to` object-y method). Neither is wired. We've only
  benchmarked the synthetic `2*3/6*x → x` payoff.
- **Claude Code gag pass.** §7 of talk-structure. Not specced.

## Roadmap gap, ranked by talk-ROI

1. **Inlining v2 — one-arg FCALL with local-table growth.** v1 shipped
   (zero-arg, constant-body). v2 unblocks the wrapper-flattening demo
   and requires `local_table` codec extension to allocate a caller-side
   slot for the passed arg. The "often only exposed *after* inlining"
   const-fold slide still wants v2 to fully land.
2. **RBS type environment.** Prerequisite for "sound in principle"
   across every pass and for the object-y demo. Big spec on its own
   (~option F in the session-ladder history).
3. **Const-fold Tier 4 (ENV).** Contract-slide showpiece. Small, doesn't
   need RBS. High narrative ROI per unit effort.
4. **Demo programs wired end-to-end** with benchmark harness output.
5. **Const-fold Tier 2 (frozen constants).** Needs the
   constant-assignment scanner but is otherwise self-contained.
6. **`opt_mod`** in the arith family. Non-commutative/associative —
   skip-heavy, small fold set. May not justify its own slide.
7. **Claude Code gag pass.** §7 close. Scripted output is fine.

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
- **InliningPass v2** — one-arg FCALL inline with caller local-table
  extension for arg passing; prerequisite for wrapper flattening. Needs
  codec work: growing `local_table` bytes, updating `local_table_size`
  in `misc`, stack_max recomputation for the additional setlocal.

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

## Maintenance note

When you finish a roadmap item, **update this file in the same commit**
as the work. Keep the "Three-pass plan: status" table accurate — it's
the one future sessions read first.
