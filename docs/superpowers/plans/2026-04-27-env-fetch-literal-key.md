# Plan — Tier 4 `ENV.fetch("LIT")` fold

Spec: `docs/superpowers/specs/2026-04-27-env-fetch-literal-key-design.md`
Approved: 2026-04-27 (pre-approved in session prompt)

## Commits (TDD rhythm)

1. **red** — add tests 1 and 2 from spec (fold with present key, skip
   with absent key) to `const_fold_env_pass_test.rb`. Assert new log
   reason `:fetch_key_absent`. Run via ruby-bytecode MCP and confirm
   they fail against current pass.
2. **green + wire-up + docs** — extend
   `ConstFoldEnvPass#apply` fold loop with the fetch arm and
   `fetch_send?` helper. Add remaining tests (3–6). Update
   `docs/TODO.md`: move item #7 from "Roadmap gap" to shipped note in
   the Three-pass plan Tier 4 row; bump "Last updated" to 2026-04-27.
   Full pass-suite green via ruby-bytecode MCP.

## Files

Edit:
- `optimizer/lib/ruby_opt/passes/const_fold_env_pass.rb` — new
  `fetch_send?(inst, ot)` helper; extend the `while` loop with the
  fetch arm; new log reason `:fetch_key_absent`.
- `optimizer/test/passes/const_fold_env_pass_test.rb` — new tests.
- `docs/TODO.md` — status-table row for Tier 4 + remove item #7 from
  ranked list (or mark shipped).

No new files.

## Operational rules

- **jj**: finalize commits with `jj commit -m "..."`, never
  `jj describe`. Stage-and-commit flow only.
- **Ruby execution**: all Ruby / tests via the `ruby-bytecode` MCP
  tools (`mcp__ruby-bytecode__run_optimizer_tests` with
  `test_filter=test/passes/const_fold_env_pass_test.rb` for fast
  inner loop; run with no filter before declaring green).
- **No scope creep**: argc=2 fetch (with default), block-passing
  fetch, splat/kwargs — all out of v1. Spec §Out lists them.

## Out of scope (follow-ups)

- `ENV.fetch(key, default)` — waits on #6 (argc-generic classifier).
- Block-passing `ENV.fetch(key) { default }` — same.
- Generic `send` opcode (non-`opt_send_without_block`) — noted in
  TODO under Tier 4 follow-ups.

## Hand-off

Subagent (`general-purpose`) executes steps 1–2. Returns under 200
words with: commit shas (2), test counts (added/total green), any
scope cuts. Parent verifies with `jj log` + `jj diff` + full-suite
rerun via MCP.
