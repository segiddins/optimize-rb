# Plan — Const-fold Tier 2

Spec: `docs/superpowers/specs/2026-04-26-const-fold-tier2-design.md`
Approved: 2026-04-26 (pre-approved in session prompt)

## Commits (TDD rhythm)

1. **red** — test fixture: top-level `FOO = 42; def f; FOO; end` and
   assert post-pass `f` has no `opt_getconstant_path`. Also a red test
   for string constants and for the cascade (`FOO + 1 → 43`).
2. **green** — `ConstFoldTier2Pass` with tree-scan + fold loop. Tests
   1–3 pass.
3. **taint tests (red → green)** — reassignment, non-literal RHS,
   nested path. Add classifier branches as tests force them.
4. **wire-up** — insert pass at head of `Pipeline.default` (before
   `ConstFoldEnvPass`). Update `TODO.md` three-pass table.

## Files

New:
- `optimizer/lib/optimize/passes/const_fold_tier2_pass.rb`
- `optimizer/test/passes/const_fold_tier2_pass_test.rb`

Edit:
- `optimizer/lib/optimize/pipeline.rb` (insert pass)
- `docs/TODO.md` (status table + ranked list)

## Execution

Direct TDD in-session, not subagent-dispatched. All Ruby via
`ruby-bytecode` MCP (`run_optimizer_tests` with
`test_filter=test/passes/const_fold_tier2_pass_test.rb`).

Commit with `jj commit -m` (never `describe`).

## Out of scope (spec §Risks)

Symbols, Arrays, Hashes; nested/module-body assignments; cross-file
constants. Each is a named follow-up.
