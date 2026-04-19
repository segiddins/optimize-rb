# Spec: Constant Folding Pass

**Part of:** [Ruby the Hard Way](2026-04-19-talk-structure-design.md)
**Depends on:** [Optimizer core](2026-04-19-optimizer.md)

## Purpose

Fold expressions to literals wherever safe. Runs last so it sees
everything the inlining and arith passes exposed — that layering is
the reason it's worth having as its own pass.

## Three tiers

### Tier 1 — Literal expressions

Pure literal-operand expressions evaluate at optimize time:

- `2 + 3` → `5`
- `"foo" + "bar"` → `"foobar"` (result frozen)
- `[1, 2].length` → `2`
- `Integer(42)` → `42`

Preconditions: all operands are literals; the operation is on a core
type whose behavior is locked by the contract.

### Tier 2 — Frozen constants

Constants assigned at the top level and never reassigned (verified by
scanning the loaded program) are treated as literals:

```ruby
MULTIPLIER = 10
def scale(x) = x * MULTIPLIER
```

After inlining a caller `scale(5)`, the body becomes `5 * 10` → `50`.

Preconditions:
- Constant is assigned exactly once, from a literal or a tier-1-foldable
  expression
- No `const_set` or dynamic reassignment anywhere in the loaded
  program (contract clause TBD; logged if violated)

### Tier 3 — Type-guided identities

Identities that hold under RBS-proven types:

- `x + 0` → `x`, `0 + x` → `x` when `x: Integer`
- `x * 1` → `x`, `1 * x` → `x` when `x: Integer`
- `x * 0` → `0` when `x: Integer`
- `"" + x` → `x`, `x + ""` → `x` when `x: String`
- `x && true` → `x` when `x: bool`

Preconditions: type env proves the operand type; the identity
preserves both value and evaluation side effects (we're careful about
short-circuit operators).

### Tier 4 — `ENV` folding

Under the contract's "ENV read-only after load" clause:

- `ENV["FOO"]` → the literal frozen string read at optimize time (or
  `nil` literal if absent)
- `ENV.fetch("FOO", default)` → the value or the default, resolved
  statically

This is the tier most likely to bite someone who breaks the contract
— `ENV["FOO"] = ...` at runtime no longer has the expected effect.
Worth calling out on the contract slide as *the* example of a rule
that looks innocuous until it isn't.

## Failure behavior

For each potential fold, unmet preconditions log and skip. Nothing
raises.

## Interaction with the other passes

Runs last, by design. Examples of fold opportunities only visible
after earlier passes:

- Arith pass reassociated `x + 1 + 2` → `x + 3`; tier 1 does nothing
  new here, but a caller-supplied literal for `x` would be folded all
  the way
- Inlining inlined a method returning `CONFIG["timeout"]`; tier 2 /
  tier 4 folds the result
- Inlining inlined a wrapper returning its only argument unchanged;
  tier 3's identity on the arithmetic that follows now applies

## Demo opportunities

- A config-heavy method body that, after inlining + const-fold,
  reduces to a single return of a literal
- `ENV["FEATURE_X_ENABLED"] ? fast_path : slow_path` → the compiler
  sees only one of the two branches after folding; dead-branch
  elimination follows naturally (even if we don't write that pass,
  the resulting iseq is noticeably smaller)

## Not in scope

- Dead-branch elimination as its own pass. We emit the folded branch
  conditions; if the VM's own optimizer collapses the dead arm, we
  benefit; if not, we live with it.
- Any folding that changes observable side effects
- Folds that would require interpreting user-defined methods at
  optimize time (beyond what inlining already did)
