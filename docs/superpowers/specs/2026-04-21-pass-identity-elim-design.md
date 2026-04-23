# Spec: Identity Elimination Pass — v1

**Part of:** [Ruby the Hard Way](2026-04-19-talk-structure-design.md)
**Depends on:** `ConstFoldPass`, `ArithReassocPass` v1–v4 (all shipped), `LiteralValue` helper, `IR::Function#splice_instructions!`.

## Purpose

Strip arithmetic identities that the upstream passes leave behind. `x * 1`, `x + 0`, `x - 0`, `x / 1` collapse to `x`. This is the slide that completes v4's boundary example:

```
2 * 3 / 6 * x
  ├─ ArithReassocPass :ordered → 6 / 6 * x
  ├─ ConstFoldPass             → 1 * x
  └─ IdentityElimPass          → x
```

Three passes, three tables, one final shape.

## Scope

Exactly one transformation: given a triple `producer_lit; producer_nonlit; op` (or `producer_nonlit; producer_lit; op`, subject to operator direction), where `producer_lit` reads as the op's integer identity and `producer_nonlit` is a whitelisted side-effect-free producer, splice the triple down to the single non-literal producer.

### Explicitly in

- A class-level `IDENTITY_OPS` table:

  ```ruby
  IDENTITY_OPS = {
    opt_plus:  { identity: 0, sides: :either },
    opt_mult:  { identity: 1, sides: :either },
    opt_minus: { identity: 0, sides: :right  },
    opt_div:   { identity: 1, sides: :right  },
  }.freeze
  ```

  `:either` — the identity-literal may be on the left or the right. `:right` — identity only vanishes if it's the right operand (`0 - x ≠ x`; `1 / x ≠ x`).

- A `SAFE_PRODUCER_OPCODES` set mirroring `ArithReassocPass::SINGLE_PUSH_OPERAND_OPCODES`: literal-producers, `getlocal*`, `getinstancevariable`, `getclassvariable`, `getglobal`, `putself`. An identity elimination fires only when the **non-literal** producer is in this set.
- Integer identity only: the literal's `LiteralValue.read` result must be an `Integer` equal to the op's identity. Float `0.0` / `1.0` do not fire (see Q3 of the design brainstorm; floats are their own essay).
- An outer fixpoint mirroring `ConstFoldPass`: collapse repeatedly until stable. Handles `x * 1 * 1 * 1` cascades where each pass strips one identity and exposes the next.
- Insertion into the default pipeline after `ConstFoldPass`:

  ```ruby
  Pipeline.default = [ArithReassocPass, ConstFoldPass, IdentityElimPass]
  ```

### Explicitly out (deferred to later plans)

- **Absorbing zero** (`x * 0 → 0`, `0 * x → 0`, `0 / x → 0`). Requires side-effect analysis even within the whitelist — eliding the non-literal producer would change program output for every observable side of its execution. Talk beat for a later slide.
- **Self-ops** (`x - x → 0`, `x / x → 1`). Requires operand-equality on the stack producers plus a `x ≠ 0` proof for `x / x`.
- **Float identities.** `-0.0` and `NaN` interactions make `x + 0.0 → x` not quite sound, or at least not worth arguing about on one slide.
- **Non-numeric operand semantic preservation.** See "Soundness" below.
- **New opcodes** — only the four listed. `opt_mod` has no identity useful here (`x % 1 = 0`, not `x`).

## Soundness

The pass is **sound in practice, not sound in principle** for non-numeric left operands. We accept this knowingly, guard it tightly, and document it on the talk slide.

### What's sound

For Integer (and Float) left operands, Ruby's built-in `+/-/*/` with an Integer identity literal is a true no-op. CRuby's `opt_*` instructions specialize on `Integer × Integer` and `Float × Float`; when they hit the fast path, eliding the op is behavior-preserving. `splice_instructions!` keeps branch targets correct; no other pass-invariant is touched.

### What's not

If the left operand's runtime class does not implement the operator as an identity — e.g.:

- `"abc" + 0` currently raises `TypeError: no implicit conversion of Integer into String`.
- `[1, 2] * 1` currently returns a **copy** `[1, 2]`, not the same array identity.
- An object that redefines `Numeric#+` via monkey-patch.

…then eliding the op changes observable behavior: the `TypeError` is not raised, or the copy is not made, or the monkey-patched side effect does not fire.

### Why we accept this

- The corpus of programs we care about for the talk is numeric. None of them hit these cases.
- CRuby's `opt_*` fast paths already assume numeric operands; on non-numeric receivers they fall back to full method dispatch. IdentityElim is the same kind of bet, taken at optimization time instead of dispatch time — exactly what YJIT does when it specializes.
- The whitelist of safe producers rules out `send`, `invokesuper`, and any instruction that could have side effects. We are not eliding *side effects*; we are at worst eliding a `TypeError` raise for programs that were already going to fail.
- The talk gets a slide that says the quiet part out loud: "this is our first specialization. Here is the guard that keeps it from being worse."

### Guard summary

The pass fires only when **all** of:

1. The triple matches `IDENTITY_OPS[op]`.
2. The literal producer reads as `Integer` equal to the identity.
3. The literal is on a side permitted by `sides:` (`:either` or matching `:right`).
4. The non-literal producer is in `SAFE_PRODUCER_OPCODES`.

If any guard fails, the triple is left alone and logged with the appropriate skip reason.

## Algorithm

```
for each function:
  loop:
    eliminated_any = false
    i = 0
    while i <= insts.size - 3:
      a, b, op = insts[i], insts[i+1], insts[i+2]
      entry = IDENTITY_OPS[op.opcode]
      unless entry: i += 1; continue
      unless a.safe? && b.safe?: i += 1; continue   # both in SAFE_PRODUCER_OPCODES

      a_val = LiteralValue.read(a)
      b_val = LiteralValue.read(b)
      a_lit = LiteralValue.literal?(a)
      b_lit = LiteralValue.literal?(b)

      case
      when b_lit && b_val.is_a?(Integer) && b_val == entry[:identity]
        # RHS is identity: <a> <lit=id> <op> → <a>
        splice(i..i+2, [a])
        log(:identity_eliminated)
        eliminated_any = true
        i = i - 1 if i > 0   # step back for cascades like x * 1 * 1
      when a_lit && a_val.is_a?(Integer) && a_val == entry[:identity] && entry[:sides] == :either
        # LHS is identity on a commutative op: <lit=id> <b> <op> → <b>
        splice(i..i+2, [b])
        log(:identity_eliminated)
        eliminated_any = true
        i = i - 1 if i > 0
      else
        i += 1
      end
    break unless eliminated_any
```

Reuses `splice_instructions!` verbatim for branch-target patching (the const-fold pass already depends on this; the invariant holds identically here).

### Leader / basic-block concerns

Unlike `ArithReassocPass`, this pass operates on fixed 3-instruction windows. The removed instructions (the identity literal and the `opt_*` op) are never branch *targets* — leaders by definition mark branch targets, and `ArithReassocPass` already relies on this for its literal-producing pushes. `splice_instructions!` updates absolute branch indices; any branch target at or past the splice site shifts by `-2`. We do not need to check `compute_leaders` explicitly: identity-elim never crosses a block boundary because a 3-instruction window cannot span one (the op at `i+2` couldn't be a leader in the middle of a window we're rewriting, because that would mean `i+2` is a branch target, and we'd be folding a triple whose `op` is someone else's successor — impossible in a stack-machine ISA where `opt_*` consumes and pushes at the same level).

(If this argument feels subtle on the talk slide, we can replace it with an explicit `leaders.include?(i+2)` check at the cost of one set lookup per window. The spec prefers the argument because it's the same argument the const-fold pass relies on today — no new machinery.)

## Logging

Reuse `Log#skip`:

- `:identity_eliminated` — one entry per successful fire.

No "skipped" reasons. Unlike the arith passes, we don't want noise for every triple we look at and decline — the common case is "this `opt_*` doesn't have an identity literal," which is not interesting and would flood the log. Decline paths are silent.

Pass name: `:identity_elim`.

## Interface

```ruby
class Optimize::Passes::IdentityElimPass < Optimize::Pass
  def name = :identity_elim
  def apply(function, type_env:, log:, object_table: nil)
end
```

`type_env` accepted for interface compatibility, unused. If/when a stack-type inferencer lands, this pass is a natural place to tighten the soundness story — the algorithm stays the same, only the `safe?` predicate grows a "left operand provably Integer" clause.

## Files

```
optimizer/
  lib/optimize/
    passes/
      identity_elim_pass.rb            # NEW — the pass
    pipeline.rb                        # MODIFIED — append IdentityElimPass.new
  test/
    passes/
      identity_elim_pass_test.rb       # NEW — unit + end-to-end
    codec/corpus/
      identity_elim.rb                 # NEW — corpus fixture
optimizer/README.md                     # MODIFIED — mention IdentityElimPass
```

## Test strategy

Mirror the other passes:

1. **Unit tests** on the pass in isolation with hand-built and `InstructionSequence.compile`-derived IR.
2. **End-to-end:** after `apply`, round-trip through `Codec.encode` + `load_from_binary` + `.eval`; result equals the un-optimized output.
3. **Pipeline integration:** a dedicated test that runs `Pipeline.default` on `def f(x); 2 * 3 / 6 * x; end` and asserts the final shape is `getlocal; leave`-adjacent (no `opt_*` opcodes remaining for that method).
4. **Corpus regression:** `test/codec/corpus/identity_elim.rb` survives `Pipeline.default.run`.

Critical fixtures:

| Source                       | Expected                 | Reason                          |
|------------------------------|--------------------------|---------------------------------|
| `x * 1`                      | `x` (getlocal; leave)    | Basic right-identity            |
| `1 * x`                      | `x`                      | Commutative left-identity       |
| `x + 0`                      | `x`                      | opt_plus :either                |
| `0 + x`                      | `x`                      | opt_plus :either                |
| `x - 0`                      | `x`                      | opt_minus :right                |
| `0 - x`                      | unchanged                | opt_minus :right — `0 - x = -x` |
| `x / 1`                      | `x`                      | opt_div :right                  |
| `1 / x`                      | unchanged                | opt_div :right — `1 / x ≠ x`    |
| `x * 1 * 1 * 1`              | `x`                      | Fixpoint cascade                |
| `x * 1.0`                    | unchanged                | Integer-only                    |
| `x + 0.0`                    | unchanged                | Integer-only                    |
| `x * 0`                      | unchanged                | Out of scope (absorbing)        |
| `x.foo * 1`                  | unchanged                | Non-literal producer is `send`, not in whitelist |
| `f(y) + 0`                   | unchanged                | Same reason                     |
| `x - x`                      | unchanged                | Out of scope                    |
| `2 * 3 / 6 * x` in pipeline  | `x`                      | The talk's motivating fixture   |

End-to-end equivalence test for `x * 1` shape: input `def f(x); x * 1; end; f(5)` must produce `5` both with and without the pass applied.

## Interactions with other passes

- **Before IdentityElim:** ConstFoldPass has already collapsed any all-literal triples. IdentityElim never sees a literal-on-both-sides triple in realistic pipelines — but the algorithm handles that case correctly anyway (it'd fire on e.g. `putobject 5; putobject 1; opt_mult → putobject 5`, which is also what ConstFoldPass would have produced, and both passes logging the same fold is harmless).
- **Before IdentityElim:** ArithReassocPass has already collapsed literal chains. Only isolated identity triples remain (the shape the v4 boundary case produces after const-fold's mop-up).
- **After IdentityElim:** nothing downstream in the default pipeline. The final IR is emitted.
- **Fixpoint across passes:** not wired. IdentityElim cannot produce a new chain that ArithReassocPass or ConstFoldPass could fold — it only removes instructions; non-literal producers stay in place and literal sides vanish entirely. A pass-level fixpoint wrapper would spin once and exit, so we don't add one.

## Not changing

- `Pass#apply` signature.
- `Pipeline#run` — the new pass slots into the `@passes` list without any plumbing change.
- `LiteralValue` / `ObjectTable` — unchanged; we only call `read` and `literal?`.
- `IR::Function#splice_instructions!` — unchanged; branch-target patching already exists.

## Success criteria

1. All existing 161 tests remain green.
2. New unit tests green: each row of the fixture table above has a dedicated test.
3. Pipeline integration test green: `2 * 3 / 6 * x` collapses to `getlocal`-only (no `opt_*` opcodes in the method body beyond `leave`).
4. Corpus regression green for `identity_elim.rb` and all existing corpus files.
5. End-to-end: every positive fixture round-trips through `Codec.encode` → `load_from_binary` → `.eval`, producing a result equal to the un-optimized output.
6. Benchmark data point for the talk slide: `def f(x); x * 1 * 1; end` vs `def f(x); x; end`. ips ratio within noise (the point is *correctness under optimization*, not a speedup — the optimized form has strictly fewer ops).

## Non-goals for the talk

The pass is the "three passes, three tables" payoff — a short slide, not a feature explainer. The interesting content is the **soundness discussion**: identity elimination is the first place we trade rare error paths for the common case, and that trade is named explicitly in the spec. That's the slide's substance.
