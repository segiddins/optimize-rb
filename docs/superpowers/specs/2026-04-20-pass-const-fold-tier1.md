# Spec: Constant Folding Pass — Tier 1 (first implementation)

**Part of:** [Ruby the Hard Way](2026-04-19-talk-structure-design.md)
**Depends on:** [Optimizer core](2026-04-19-optimizer.md), codec with length-changing edits (plan `2026-04-19-codec-length-changes.md`, complete at commit `uzmzzzxp`)
**Narrows:** [Constant folding pass (full)](2026-04-19-pass-const-fold.md)

## Why this plan

The full const-fold spec covers four tiers. This plan implements **tier 1, restricted to Integer arithmetic and Integer comparisons**. It is the optimizer's first real pass — ends the NoopPass era, exercises length-changing encode on a live mutation, and shapes the conventions (literal detection, skip logging, fold logging, line-annotation inheritance) that the arith and inlining passes will reuse.

Tiers 2–4 (frozen constants, type-guided identities, `ENV` folding) are deferred to follow-up plans. Tier 1 shapes beyond Integer arithmetic (String concat, `Array#length`, `Integer()`) are also deferred — each has its own complications (frozen-string semantics, N-element window, Kernel receiver resolution) that do not belong in the first pass.

## Purpose

Fold Integer literal arithmetic and comparison expressions to their result at optimize time. A chain like `1 + 2 + 3` collapses to a single `putobject 6`; `5 < 10` collapses to `putobject true`.

## Pattern recognized

Within a single basic block, a **foldable triple** is:

```
putobject <Integer literal A>
putobject <Integer literal B>
opt_{plus,minus,mult,div,mod,lt,le,gt,ge,eq,neq}
```

The pass replaces the triple with one `putobject <result>`, where `<result>` is the Ruby value computed by running the operation on `A` and `B` at optimize time.

Literal detection also accepts the specialized `putobject_INT2FIX_0_` / `putobject_INT2FIX_1_` forms if the decoder emits them — the pass reads whichever form the IR carries and emits whichever is appropriate for the result (implementation will stick to `putobject` for simplicity unless the corpus forces us to preserve the specialized form).

No cross-block folding. Triples split by a basic-block boundary are left alone.

## Algorithm

Iterate within the pass until no fold fires; one pipeline pass, internal fixpoint:

```
loop:
  folded_any = false
  for each basic block in function:
    scan forward for a foldable triple
    if found:
      replace it; folded_any = true; restart the block scan
  exit when a full walk over every block produced no fold
```

Iterating inside the pass (rather than the whole pipeline) keeps chain folds (`1+2+3 → 6`) working without requiring fixpoint iteration at the pipeline level.

Complexity is O(n²) in the worst case on a single block of `n` instructions. That is fine at iseq scale — methods are small.

## Skip conditions

Each skip is logged via the existing `RubyOpt::Log` interface with the usual `{pass: :const_fold, reason:, file:, line:}` shape. Skip conditions:

- `:would_raise` — the operation would raise at runtime (`1/0`, `1%0`). Folding would suppress an observable `ZeroDivisionError`, so the pass leaves the triple alone. Detection: wrap the fold's call in `rescue StandardError => e` and, on any rescue, skip and log.
- `:non_integer_literal` — one or both of the two top-of-window instructions is a literal but not an Integer literal (e.g. `putobject nil`, strings, symbols). Deferred to later tiers.
- No log line is emitted for "no triple here" — only for shapes that *look* foldable but aren't.

## Fold logging

Every successful fold logs `{pass: :const_fold, reason: :folded, file:, line:, detail:}` where `detail` is a short description (`"1 + 2 → 3"`). The talk uses this log to show the audience what the optimizer did, not just what it skipped.

## Line annotation

The new `putobject` inherits `line` from the first instruction of the removed triple. Line entries pointing at the two removed instructions become dangling and are filtered by `LineInfo.encode` (Task 5d of the codec plan). Line entries pointing at the first instruction survive with the new `putobject` in that slot.

## Pipeline placement

The pass is **last** in the pipeline, matching the final spec layout (inlining → arith → const-fold). For this plan it is the *only* real pass; the default pipeline construction replaces `NoopPass` with `ConstFoldPass.new`. `NoopPass` remains available for tests and for pipeline-contract validation.

## Interface

```ruby
module RubyOpt
  module Passes
    class ConstFoldPass < RubyOpt::Pass
      def apply(function, type_env:, log:)
        # ...
      end

      def name = :const_fold
    end
  end
end
```

The `type_env` parameter is accepted (required by `Pass`) but unused in tier 1 — documented with a comment.

## Codec interaction

The pass is the first length-changing producer. It relies on codec behavior established in the length-changes plan:

- `function.instructions` mutation is the only mutation — the pass does not touch `catch_entries`, `arg_positions`, or `line_entries` directly
- `LineInfo.encode` filters line entries whose `inst` reference is no longer in `function.instructions`
- `CatchTable.encode` filters catch entries whose `start_inst`/`end_inst`/`cont_inst` references are gone (tier-1 folds don't cross catch boundaries in practice, but the filtering is defense in depth)
- `StackMax.compute` recomputes the high-water stack depth; folding three instructions into one can only decrease the stack max, never increase it, so the computed value stays within bounds

## Testing

All test runs use `mcp__ruby-bytecode__run_optimizer_tests` (Docker-sandboxed, no host permission prompts). No host `bundle exec rake test`.

1. **Unit tests** on a hand-constructed `IR::Function`:
   - Single-triple fold: verify the three instructions become one, operand is correct, line preserved.
   - Chain fold: `1 + 2 + 3` (five instructions) → one `putobject 6`; iterated folding works.
   - Division by zero: `1 / 0` is left unchanged; log contains one `:would_raise` entry.
   - Non-integer literal: `"a" + "b"` is left unchanged; log contains one `:non_integer_literal` entry.
   - Mixed literal/local: `x + 2 + 3` — the `2 + 3` sub-chain folds but the `x +` is left alone.
   - Comparison folds: `5 < 10 → true`, `5 == 5 → true`, `5 != 5 → false`.

2. **End-to-end tests** (compile → decode → pass → encode → `load_from_binary` → run):
   - `def f; 1 + 2 + 3; end; f` returns `6`, the loaded iseq's instructions include a `putobject 6`.
   - `def f(x); x + 2 + 3; end; f(10)` returns `15`.
   - `def f; 5 < 10; end; f` returns `true`.

3. **Corpus regression:** the existing codec round-trip corpus tests must still pass. The pipeline with `ConstFoldPass` must not break any fixture that currently round-trips under `NoopPass`.

4. **Benchmark case** via `mcp__ruby-bytecode__benchmark_ips`: a method with a literal arithmetic expression, before vs. after the pass. Documents the win for the talk. Small, one case — not a suite.

## Scope boundaries

In scope:
- Integer `opt_plus`, `opt_minus`, `opt_mult`, `opt_div`, `opt_mod`
- Integer `opt_lt`, `opt_le`, `opt_gt`, `opt_ge`, `opt_eq`, `opt_neq`
- Within-block chain folding via internal fixpoint
- `:would_raise` and `:non_integer_literal` skip logging
- Fold logging
- Line annotation inheritance from the first removed instruction

Not in scope (explicit deferrals):
- String concat, Array literal methods, Kernel conversion methods (tier-1 follow-up plans)
- Tiers 2–4 (separate plans each)
- Cross-block constant propagation
- Pipeline-level fixpoint iteration
- Type-env integration (arith pass's problem)

## Files (expected)

```
optimizer/
  lib/ruby_opt/
    passes/
      const_fold_pass.rb          # NEW
    pipeline.rb                   # MODIFIED (default pipeline uses ConstFoldPass)
  test/
    passes/
      const_fold_pass_test.rb     # NEW — unit + end-to-end
    fixtures/
      passes/const_fold/          # NEW — small source fixtures for e2e tests
```

The exact task breakdown and commit discipline live in the implementation plan, not here.

## Self-review

- **Placeholders:** none. Operand set, skip conditions, log shapes, pipeline placement, and testing strategy are all concrete.
- **Internal consistency:** fold logging reason `:folded` and skip reasons `:would_raise`, `:non_integer_literal` are used consistently. Pipeline placement (last) matches the core spec.
- **Scope check:** single implementation plan, ~4–5 tasks. Far smaller than the codec length-changes plan.
- **Ambiguity:** the one ambiguity is whether to preserve specialized `putobject_INT2FIX_*` forms on emit. Resolved: the pass emits generic `putobject` with an Integer operand; if the corpus requires specialized forms, the implementer documents the case in the plan and handles it then.
