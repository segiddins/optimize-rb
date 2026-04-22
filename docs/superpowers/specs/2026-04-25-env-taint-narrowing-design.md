# ConstFoldEnvPass taint-classifier narrowing — design

**Date:** 2026-04-25
**Pass:** ConstFoldEnvPass (Tier 4 const-fold)
**Scope:** Refinement — narrow the whole-tree taint classifier so read-only sends on `ENV` no longer taint the tree.

## Motivation

After 2026-04-24 (`ObjectTable#intern` accepts frozen strings), `ConstFoldEnvPass` folds `ENV[LIT]` unconditionally when the tree is untainted. The remaining soundness wall is coarse: any non-`opt_aref` consumer of an `ENV` producer — including pure reads like `ENV.fetch("X")`, `ENV.to_h`, `ENV.key?("X")` — taints the whole tree and disables every fold site.

That is over-conservative. `fetch`, `to_h`, `key?`, etc. cannot mutate `ENV`, so their presence does not invalidate the "snapshot captured at optimize-time equals ENV at load-time" invariant that Tier 4 depends on. The write-observing methods (`store`, `delete`, `[]=`, `update`, `clear`, …) are the actual taint sources.

## Design

Classify each ENV consumer as one of three kinds:

1. **`opt_aref`** — bare `ENV[KEY]`. Safe (existing behavior).
2. **`opt_send_without_block` with a whitelisted read-only mid and matching argc** — safe. New behavior.
3. **Anything else** — tainted (unchanged).

### Safe read-only method whitelist

A frozen `Set` of mid symbols. Partitioned by how we identify the consumer position (see "Consumer position" below) — but the set itself is flat.

```ruby
SAFE_ENV_READ_METHODS = %i[
  fetch to_h to_hash key? has_key? include? member?
  values_at assoc size length empty? keys values
  inspect to_s hash ==
].to_set.freeze
```

Explicitly *not* in the set (write-observing or mutation-adjacent):

```
[]=, store, delete, update, merge!, replace, clear, rehash,
delete_if, keep_if, reject!, select!, filter!, compact!,
shift (Hash#shift mutates), freeze (observable identity change)
```

When in doubt, stay on the taint side. Compatibility with future ruby versions leans pessimistic: a new ENV mutator added in a future Ruby would fall through to the taint branch, which is the safe direction.

### Consumer position

Current code assumes the consumer sits at `insts[i+2]` (correct for `opt_aref`, which implicitly pops 2 slots — ENV receiver and the key at `i+1`). For `opt_send_without_block`, the receiver sits `argc+1` slots down the stack, so the consumer is at `insts[i + 1 + argc]` when the `argc` slots between ENV and the send are simple push instructions.

v1 scope: handle `argc=0` (`ENV.to_h`, `ENV.keys`) and `argc=1` (`ENV.fetch("X")`, `ENV.key?("X")`). That matches the Tier 4 talk narrative (read-only reflection) and is what existing tests exercise. `values_at("A","B")` (argc≥2) is deferred — the classifier stays conservative and taints.

### Classifier flow

For each ENV producer at index `i`:

1. If `insts[i+2]` is `opt_aref` → safe.
2. If `insts[i+1]` is `opt_send_without_block` with `CallData{argc=0, no kwargs/splat/block}` and `mid ∈ SAFE_ENV_READ_METHODS` → safe.
3. If `insts[i+2]` is `opt_send_without_block` with `CallData{argc=1, no kwargs/splat/block}` and `mid ∈ SAFE_ENV_READ_METHODS` → safe.
4. Otherwise → tainted.

Flags checked (`no kwargs/splat/block`): exclude `has_kwargs?`, `has_splat?`, `blockarg?`. FCALL/VCALL bits don't matter (they describe call-syntax intent, not mutation semantics). A send with kwargs or splat isn't in the safe surface — stay tainted.

### What does NOT change

- The fold loop. This task is purely about classification; no new fold sites. `ENV.fetch("X")` is *not* folded to a literal — the fold loop still only rewrites the `opt_getconstant_path; put*string; opt_aref` 3-tuple. The narrowing just means a sibling function with `ENV.fetch` no longer poisons the tree for other folds.
- The pre-scan architecture (`scan_tree_for_taint` from 2026-04-24). Still runs once per pipeline run, still scans the whole tree before any folds.
- Existing fold log entries (`:folded`, `:env_value_not_string`, `:env_write_observed`).

## Test plan

| Test | Assertion |
|---|---|
| `test_env_fetch_does_not_taint_tree` (replaces `test_env_fetch_taints_tree`) | `def r; ENV["A"]; end; def g; ENV.fetch("B"); end` — `r` folds; no `:env_write_observed` entry. |
| `test_env_to_h_does_not_taint_tree` | `ENV.to_h` sibling (argc=0). `r` still folds. |
| `test_env_key_question_does_not_taint_tree` | `ENV.key?("B")` sibling (argc=1). `r` still folds. |
| `test_env_store_still_taints_tree` | `ENV.store("B", "x")` sibling. `r` does NOT fold; `:env_write_observed` present. |
| `test_env_aset_still_taints_tree` | `def w; ENV["B"] = "x"; end` — `opt_aset`, still taints. |
| `test_env_values_at_two_args_still_taints_v1` | `ENV.values_at("A", "B")` (argc=2) taints in v1. Documented scope limit. |

Existing passing tests stay: `test_no_snapshot_is_noop`, `test_env_write_in_tree_taints_and_disables_folds` (uses `store` — still a taint), `test_env_with_dynamic_key_does_not_taint` (opt_aref with local key — still safe), `test_folds_env_aref_when_value_already_interned`, `test_folds_missing_key_to_putnil`, `test_folds_env_to_interned_string_value`, `test_logs_folded_for_each_successful_fold`.

## Risks / non-goals

- **Not a stack-effect analyzer.** We inspect at most two positions (`i+1`, `i+2`) and require the intermediate push instruction (for argc=1) to be any instruction — we don't verify it's a simple push. In practice YARV emits simple push + send for `ENV.m(LIT)`, so the classifier is correct on realistic inputs. Adversarial inputs can't exist in compiled Ruby without breaking stack balance.
- **No argc≥2 safe cases in v1.** `values_at("A","B")` remains tainted. Upgrading is a v2 slice — needs a small stack-walker or an argc-generic position lookup.
- **No block-taking safe sends.** `ENV.each { }` stays tainted. v1 only handles `opt_send_without_block`, which excludes block-passing by construction.
- **No `send` opcode handling.** Only `opt_send_without_block`. The `send` opcode (with `ISEQ_BLOCK`) stays tainted.

## Success criteria

- All new tests above green; all prior ConstFoldEnvPass tests still green.
- No changes to fold-loop behavior or log surface; `:env_write_observed` count strictly decreases on code that uses only safe ENV reflection sends.
- `docs/TODO.md` "Refinements" entry for the taint classifier is removed (or moved to a "shipped" note).
