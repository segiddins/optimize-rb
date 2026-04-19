# Spec: Arithmetic Specialization Pass

**Part of:** [Ruby the Hard Way](2026-04-19-talk-structure-design.md)
**Depends on:** [Optimizer core](2026-04-19-optimizer.md)

## Purpose

When arithmetic operates on known-`Integer` operands and the contract
guarantees no `BOP_PLUS` / `BOP_MULT` / etc. redefinition, a chain of
arithmetic ops can be reassociated and partially evaluated, often
collapsing into a single remaining op plus a literal.

## Preconditions

For a given arithmetic instruction (`opt_plus`, `opt_minus`,
`opt_mult`, `opt_div`, `opt_mod`):

1. **Both operands are `Integer`-typed** — derived from RBS signatures,
   literal constants, or earlier results of this same pass
2. **The operation is associative/commutative where reassociation
   requires it** — `+` and `*` yes, `-` and `/` no
3. **The contract's "no BOP redef" clause applies** — always true in
   this optimizer, but the pass asserts it explicitly

Otherwise: log reason, leave the chain alone.

## Transformations

### Literal reassociation

Given a chain of same-operation `+` or `*` ops with mixed
variables and literals:

```
x + 1 + 2 + y + 3
```

Reassociate to gather literals:

```
x + y + (1 + 2 + 3)  →  x + y + 6
```

Concretely, walk the chain in a basic block, identify the literal
operands, sum/multiply them at optimize time, and emit a rewritten
chain with a single literal tail.

### Sub-chain folding

Within a chain, any subsequence of literals reduces immediately:

```
a + 2 + 3 + b  →  a + 5 + b
```

### Interaction with inlining

After inlining, a call site like `add(x, 1) + 2` where `add` was
`def add(a, b); a + b; end` becomes `x + 1 + 2`, which this pass
collapses to `x + 3`. The order in the pipeline (inlining before
arith) is what enables this.

## Failure behavior

Any operand whose type we can't prove `Integer` causes the chain to
be split at that point; the typed prefix (if long enough to be
worthwhile) is still folded, and the rest is left alone. Log entries
record each untyped operand.

## Demo opportunities

- Numeric kernel: `sum_of_squares(0..n)` after inlining collapses most
  of the inner body into a single `+` with a literal tail per iteration
- Showing the `#disasm` before and after this pass is the slide: it
  goes from ~5 ops to ~2

## Not in scope

- Non-Integer numeric types (`Float`, `Rational`). Adding them is
  mechanical but bloats the talk.
- Strength reduction (`x * 2` → `x + x`, `x * 8` → `x << 3`). Tempting
  but off-thesis; we're showing assumption-driven folding, not
  classical peephole tricks.
- Any op that isn't one of the basic `opt_*` arithmetic instructions
