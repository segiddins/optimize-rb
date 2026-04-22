# Tier 4 fold — `ENV.fetch("LIT")` with literal key

Status: approved (2026-04-27, pre-approved in session prompt)
Owner: Samuel Giddins

## Motivation

Tier 4 v1 (`ConstFoldEnvPass`) folds `ENV["LIT"]` — the `opt_aref`
3-tuple. Classifier v1.1 extended the read-only set to `fetch`, `to_h`,
`key?`, etc. so sibling `ENV.fetch` calls no longer taint the tree. But
the fold loop still only handles `opt_aref`: `ENV.fetch("LIT")` is
read-only-safe AND trivially foldable, yet ships unfolded today.

Payoff: `ENV.fetch("HOME")` compiled against a snapshot becomes a single
`putobject <interned HOME>`. Talk-worthy — it's a new fold *shape*
(opt_send_without_block, not opt_aref) with a crisp semantic wrinkle.

## Scope v1

**In.** The 3-tuple
```
opt_getconstant_path <ENV>                       # i
putstring | putchilledstring <LIT>               # i+1
opt_send_without_block CallData{mid: :fetch, argc: 1, no_kw/splat/block}   # i+2
```
Fold iff `env_snapshot.key?(key)` — emit `putobject <intern(value)>`.

**Out.**
- `ENV.fetch(key, default)` — argc=2. Covered by #6 (classifier argc-generic).
- `ENV.fetch(key) { ... }` — blockarg present. Same reason.
- Any `fetch` with splat / kwargs.
- Non-literal key (`ENV.fetch(some_var)`).
- `ENV["ABSENT"]`-style non-fetch paths — already folded by v1.

## Semantics — the load-bearing difference from opt_aref

| Operator | Key present | Key absent |
|---|---|---|
| `ENV["K"]` (opt_aref) | returns value | returns `nil` |
| `ENV.fetch("K")` | returns value | **raises `KeyError`** |

Consequence: when `env_snapshot[key]` is `nil`, we CANNOT assume absence
(the snapshot may just not carry it). Even if we *did* know it was
absent, the runtime behavior is a raise, not `nil` — so folding to
anything, including `putnil`, would be unsound.

Decision: fold only when `env_snapshot.key?(key)`. Otherwise skip the
site (preserve the 3-tuple so the runtime raise/lookup behavior is
unchanged). Emit a `:fetch_key_absent` log entry for narrative value.

## Algorithm

Extend the existing fold loop in `ConstFoldEnvPass#apply`. Same outer
`while i <= insts.size - 3` walk. When the head-tuple matches ENV +
literal-string but the tail is *not* `opt_aref`, check for the
`fetch`-send shape and handle it. Pseudocode:

```ruby
if env_producer?(a, ot) && literal_string?(b, ot)
  if op.opcode == :opt_aref
    # existing fold path
  elsif op.opcode == :opt_send_without_block && fetch_send?(op, ot)
    key = LiteralValue.read(b, object_table: ot)
    if env_snapshot.key?(key)
      value = env_snapshot[key]
      if value.is_a?(String)
        idx = ot.intern(value)
        splice to [putobject(idx)]
        log :folded
      else
        log :env_value_not_string  # defensive; ENV is String|nil
      end
    else
      log :fetch_key_absent  # preserve bytecode to keep KeyError at runtime
    end
  end
end
```

`fetch_send?(inst, ot)` mirrors `safe_send?` but pinned to mid `:fetch`,
argc 1, no kw/splat/block. Rejects `fetch` with any non-v1 shape.

No change to `scan_tree_for_taint` / `classify` / `consumer_safe?` —
fetch with argc=1 is already safe there (SAFE_ENV_READ_METHODS).

## Logging

- `:folded` — successful rewrite (same reason name as opt_aref fold;
  disambiguation via file/line).
- `:fetch_key_absent` — new. Snapshot lacks the key; bytecode preserved.
- `:env_value_not_string` — existing; reused defensively.

## Pipeline placement

No change. Still `ConstFoldEnvPass` between Tier 2 and Tier 1.

## Risks / non-goals

- **No cascade opportunity.** Output is a `putobject <String>`; nothing
  downstream arithmetic-folds a String. Unlike Tier 2 → Tier 1, this
  fold is terminal. That's fine — the win is removing the send.
- **Key absence != snapshot absence in general.** Our `env_snapshot` is
  the captured-at-compile-time view of ENV. Folding `ENV.fetch("X")` to
  the snapshotted value is only sound under the same assumption already
  made for `ENV["X"]`: no one mutates ENV between snapshot and run
  (enforced tree-wide by the taint pre-scan).
- **`fetch` with default.** A future session can fold
  `ENV.fetch("K", "default")` by checking argc=2 and using the default
  on `!env_snapshot.key?(key)`. Out of v1 because it requires the argc-2
  classifier from #6.

## Tests (TDD)

Target file: `optimizer/test/passes/const_fold_env_pass_test.rb` (extend
the existing file; same pass).

1. **Red — fold fetch with present key.**
   `def r; ENV.fetch("A"); end` with snapshot `{"A" => "1"}`.
   Assert post-pass `r.instructions.map(&:opcode)` does **not** include
   `:opt_send_without_block` or `:opt_getconstant_path`; does include
   `:putobject`. Assert one `:folded` log entry.
2. **Absent key — no fold, no raise at compile time.**
   `def r; ENV.fetch("MISSING"); end` with snapshot `{}`.
   Assert opcodes unchanged. Assert `:fetch_key_absent` log entry.
3. **Mixed with opt_aref in same function — both fold.**
   `def r; [ENV["A"], ENV.fetch("B")]; end` with both keys present.
   Assert neither `:opt_aref` nor fetch-send remain.
4. **Taint still disables fetch fold.**
   `def w; ENV.store("Z", "x"); end; def r; ENV.fetch("A"); end`.
   Assert `r`'s bytecode unchanged; `:env_write_observed` present.
5. **`fetch` with argc=2 is not folded (still out of scope).**
   `def r; ENV.fetch("A", "def"); end` — assert no fold, no taint,
   no spurious log. (Verifies v1 boundary.)
6. **`fetch` with block is not folded.**
   `def r; ENV.fetch("A") { "x" }; end` — assert no fold. This also
   verifies taint doesn't spuriously fire (block-passing `fetch` on a
   sibling read shouldn't poison). If the existing classifier *does*
   taint on blockarg (current behavior: `safe_send?` returns false →
   taint), adapt the assertion: confirm no crash and document in the
   commit message.

Run filter: `test_filter=test/passes/const_fold_env_pass_test.rb`.
