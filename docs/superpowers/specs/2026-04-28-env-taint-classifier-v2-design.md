# ConstFoldEnvPass taint-classifier v2 (argc-generic safe sends) — design

**Date:** 2026-04-28
**Pass:** ConstFoldEnvPass (Tier 4 const-fold)
**Scope:** Refinement — extend the v1 whitelist so read-only sends on `ENV` with *any* argc no longer taint the tree. v1 capped at argc≤1; v2 removes the cap.

## Motivation

v1 (2026-04-25) narrowed the classifier so `ENV.fetch("X")`, `ENV.to_h`, `ENV.key?("X")` etc. no longer taint a tree that also contains foldable `ENV[LIT]` sites. It hardcoded two consumer positions: `insts[i+1]` for argc=0 and `insts[i+2]` for argc=1. That leaves `ENV.values_at("A", "B")` (argc=2) tainting the tree — documented as the v1 scope limit via `test_env_values_at_two_args_still_taints_v1`.

Removing the cap is a small, self-contained extension: nothing in the v1 soundness argument actually depends on argc≤1. Stack-balance ties the send's `cd.argc` to the receiver position. If `insts[i+1+N]` is `opt_send_without_block` with `cd.argc == N` and a whitelisted mid, the receiver of that send *is* the ENV producer at `i`, by the same stack-balance argument v1 already accepts for argc=1.

## Design

Replace the v1 two-branch consumer lookup with a forward scan.

### Classifier flow (v2)

For each ENV producer at index `i`:

1. If `insts[i+2]` is `opt_aref` → safe. (Unchanged; `opt_aref` is argc-free, always at i+2.)
2. Scan forward: for `j = 0, 1, 2, …` while `insts[i + 1 + j]` exists:
   - Let `cand = insts[i + 1 + j]`.
   - If `cand.opcode == :opt_send_without_block`:
     - If `cd.argc == j` and mid ∈ `SAFE_ENV_READ_METHODS` and no kwargs/splat/block → **safe**.
     - Otherwise → **tainted** (first send found is the consumer candidate; if it doesn't match, no further scan).
3. If we walk off the end without finding a send → **tainted**.

The "stop at first send" rule is the soundness hook. Without a stack-effect analyzer we can't prove that `insts[i+1..i+j]` are all simple 1-for-1 pushes — but if a send appears before our hypothetical consumer, it means the stream isn't the literal-arg-send shape we're whitelisting, so we bail.

### No argc cap

v1 capped at argc≤1. There's no soundness argument for a finite cap once we forward-scan and check `cd.argc == j`: the argc match is what binds the receiver position. v2 has no `MAX_SAFE_ARGC`. The test `…two_args_still_taints_v1` flips to `…does_not_taint_tree`, with an argc=3 companion for coverage of the loop logic past v1's boundary.

### What does NOT change

- `SAFE_ENV_READ_METHODS` whitelist. Same mids.
- Fold loop. Still only the `ENV; put*string KEY; opt_aref` and `ENV; put*string KEY; opt_send :fetch argc=1` 3-tuples. v2 is purely classification, not fold sites. `ENV.values_at("A","B")` is classified safe but *not folded* — the tree just stops tainting on it.
- `scan_tree_for_taint` architecture (whole-tree pre-scan, memoized on root `misc`).
- `safe_send?` helper — already takes `expected_argc:`. v2 calls it with the scanned `j`.
- Log surface — `:folded`, `:env_value_not_string`, `:fetch_key_absent`, `:env_write_observed` unchanged.

### Non-goals (follow-ups)

- **`ENV.fetch(key, default)` argc=2 fold.** Different task — needs purity analysis on the default-value expression to decide when it's safe to drop. Filed as TODO #7.5.
- **Block-passing sends (`ENV.each { }`).** Still tainted. v2 only looks at `opt_send_without_block`; `:send` and `:opt_send` with block stay out.
- **`blockarg?` narrowing.** `safe_send?` still rejects any send with `blockarg?`, `has_kwargs?`, `has_splat?`. Unchanged.
- **Receiver-adjacent stack analysis.** The forward-scan is pattern-matching, not stack simulation. Anything non-linear (nested ENV calls, conditional pushes) bails via the "first send we find must match" rule.

## Test plan

| Test | Assertion |
|---|---|
| `test_env_values_at_two_args_does_not_taint_tree` (replaces `…still_taints_v1`) | `def r; ENV["A"]; end; def g; ENV.values_at("A", "B"); end` — `r` folds; no `:env_write_observed`. |
| `test_env_values_at_three_args_does_not_taint_tree` (new) | `def r; ENV["A"]; end; def g; ENV.values_at("A", "B", "C"); end` — `r` folds; no `:env_write_observed`. Argc=3 exercises loop past v1's boundary. |
| `test_env_store_two_args_still_taints_tree` (new) | `def r; ENV["A"]; end; def w; ENV.store("B", "x"); end` — `r` does NOT fold; `:env_write_observed` present. Confirms argc-generic scan doesn't accidentally whitelist writes. |

Existing tests kept verbatim (all must stay green): `test_no_snapshot_is_noop`, `test_env_write_in_tree_taints_and_disables_folds`, `test_env_with_dynamic_key_does_not_taint`, `test_folds_env_aref_when_value_already_interned`, `test_folds_missing_key_to_putnil`, `test_folds_env_to_interned_string_value`, `test_logs_folded_for_each_successful_fold`, `test_env_fetch_does_not_taint_tree`, `test_env_to_h_does_not_taint_tree`, `test_env_key_question_does_not_taint_tree`, `test_env_aset_still_taints_tree`, and the literal-key fetch fold tests from 2026-04-27.

## Risks

- **Coincidental argc-match on unrelated sends.** If between ENV at `i` and a later send at `i+1+j` there are non-push instructions that happen to leave the stack in the right shape for `cd.argc == j`, we'd misclassify. Mitigation: "first send we encounter must match" — any send before the hypothetical consumer position taints. In realistic YARV output for `ENV.m(literal, literal, …)`, the instructions between are exactly argument-producing pushes and no other send appears.
- **Future Ruby adds a mutating ENV method.** Falls through to the taint branch (conservative default). Same risk as v1.

## Success criteria

- New tests green; all prior ConstFoldEnvPass tests still green.
- Full optimizer suite green.
- `docs/TODO.md`: item #6 struck; Tier 4 status-table cell updated to reflect argc-generic classifier.
