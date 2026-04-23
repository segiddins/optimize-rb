# ConstFoldEnvPass — Tier 4 const-fold for `ENV[...]`

Date: 2026-04-23
Status: spec

Implements Tier 4 of the const-fold roadmap
(`docs/superpowers/specs/2026-04-19-pass-const-fold.md`, §Tier 4).
Tier 1 shipped as `ConstFoldPass` (Integer-on-Integer triples). This
spec adds ENV folding under the contract's "ENV read-only after load"
clause, plus a small extension to `ConstFoldPass` so string equality
chains (`ENV["FLAG"] == "true"`) collapse to a single boolean in the
same pipeline run.

## Goal

Turn `ENV["FLAG"]` into a literal at optimize time, given an ENV
snapshot captured by the harness. Combined with the extended
`ConstFoldPass`, `ENV["FLAG"] == "true"` becomes `true`/`false`, and
the VM's branch specializer collapses the dead arm without a separate
DCE pass.

## Contract

The talk's "contract slide" posits: **`ENV` is read-only after the
compile-time snapshot is taken**. This pass is the first one that
materially depends on that contract and is the example of a rule that
looks innocuous until it isn't — a runtime `ENV["X"] = ...` after
folding no longer has its intended effect.

The pass enforces the contract by refusing to fold anything if it sees
any ENV write anywhere in the IR tree. See §Soundness gate.

## Scope

### In scope (v1)

- Fold `ENV["LIT"]` where the key is a string literal. Result is the
  snapshot value (a frozen string) or `nil` if the key is absent.
- Two opcode shapes:
  - 3-tuple: `opt_getconstant_path ENV; putstring "KEY"; opt_aref` →
    single `putstring/putnil`.
  - 2-tuple: `opt_getconstant_path ENV; opt_aref_with "KEY"` →
    single `putstring/putnil`.
  - Also accept `getconstant :ENV` as the ENV producer for older
    compile shapes, treated the same as `opt_getconstant_path ENV`.
- Extend `ConstFoldPass` to fold String-on-String `==`/`!=` triples
  (`putstring "a"; putstring "b"; opt_eq` → `putobject false`). This
  is additive; Integer-on-Integer folding is unchanged.
- Whole-IR-tree taint gate (§Soundness gate).
- Snapshot plumbing via a new `env_snapshot:` kwarg through
  `Pipeline#run` to `pass.apply`.

### Out of scope (v1, explicit)

- `ENV.fetch("KEY"[, default])`. Shape is more varied (block form,
  default form, raising form) and warrants its own narrative beat.
- Non-literal keys (`ENV[name]`).
- Any write-form detection subtler than "ENV appears as receiver of
  anything other than `[]`" — see §Soundness gate.
- Folding `ENV` itself (e.g. `ENV.to_h`, `ENV.keys`).
- Dead-branch elimination as its own pass. Still relies on the VM's
  branch specializer to drop the dead arm.

## Architecture

### New file: `optimizer/lib/optimize/passes/const_fold_env_pass.rb`

A new `Optimize::Passes::ConstFoldEnvPass` alongside `ConstFoldPass`
rather than an expansion of it. Rationale: `ConstFoldPass` is cleanly
"Integer-on-Integer triple"; this pass has a different shape (2- and
3-tuples, string-typed result, whole-tree precondition). Keeping them
separate gives the talk two distinct slides with clean before/after
diffs.

Pipeline ordering in `Pipeline.default`:

```
InliningPass
ArithReassocPass
ConstFoldEnvPass     # NEW — folds ENV["KEY"] first
ConstFoldPass        # now also folds String==String/String!=String
IdentityElimPass
```

`ConstFoldEnvPass` must run **before** `ConstFoldPass` so that
`ENV["FLAG"] == "true"` becomes `"<val>" == "true"` in time for the
string-eq folder to collapse it in the same pipeline pass.

### Extension to `ConstFoldPass`

Add `opt_eq` / `opt_neq` folding when both operands are strings
(`LiteralValue.read` returns a `String`). Integer-on-Integer path is
unchanged. Keep the existing Integer-only guard for the other ops
(`opt_plus`, `opt_lt`, etc.) — strings have their own `+`/`<` semantics
that we're not folding in v1. Only `==`/`!=` get the string-operand
path.

Trigger condition: both `av` and `bv` are `String` (after
`LiteralValue.read`), and `op.opcode` is `opt_eq` or `opt_neq`. Use
`av == bv` / `av != bv`, emit `putobject true`/`putobject false`.

### Snapshot plumbing

New `env_snapshot:` kwarg on `Pipeline#run`. Pipeline passes it to
every `pass.apply` call alongside `type_env:`, `log:`, `object_table:`,
`callee_map:`. Passes that don't care ignore it (their `**_extras`
absorbs it).

```ruby
# optimizer/lib/optimize/pipeline.rb
def run(ir, type_env:, env_snapshot: nil)
  # ...
  pass.apply(
    function,
    type_env: type_env, log: log,
    object_table: object_table, callee_map: callee_map,
    env_snapshot: env_snapshot,
  )
end
```

The harness captures once at pipeline construction time:

```ruby
env_snapshot = ENV.to_h.freeze
pipeline.run(ir, type_env: ..., env_snapshot: env_snapshot)
```

If `env_snapshot` is nil/missing, `ConstFoldEnvPass` is a no-op. This
keeps the existing ~20 test call sites (`type_env: nil, log: ...,
object_table: ot`) working unchanged.

## Soundness gate (whole-tree taint)

Before folding, walk every function in the IR tree and classify every
ENV reference. A reference is the instruction producing ENV
(`opt_getconstant_path ENV` or `getconstant :ENV`) considered together
with the instruction that consumes its result.

**Safe uses:**
- Consumer is `opt_aref` *with* the immediately preceding instruction
  being a string-literal producer (the 3-tuple shape).
- Consumer is `opt_aref_with` (the 2-tuple shape).

**Tainted uses (anything else):**
- `opt_aset` / `opt_aset_with` on ENV → write
- `opt_send_without_block` / `send` / `invokesuper` on ENV receiver →
  could be `delete`, `replace`, `store`, `clear`, `[]=`, `fetch`,
  `to_h`, etc. All rejected in v1 (even the read-only ones like
  `fetch` and `to_h`). This is conservative — some of these are safe
  reads we just aren't folding. v2 can narrow.
- `pop` immediately after (ENV produced and discarded) → rejected.
  Unlikely in practice; reject for simplicity.
- `dup`/stack shuffles before consumer → rejected for v1. Keep the
  1-step-ahead reasoning.

If **any** tainted use is found in **any** function of the IR tree,
the pass does zero folding and emits one log entry:

```
log.skip(pass: :const_fold_env, reason: :env_write_observed,
         file: <function.path>, line: <instruction.line>)
```

The first tainted instruction's location is used for the log. This is
the contract-violation detector — on the talk's contract slide we
show a before/after where adding a single `ENV["X"] = "y"` anywhere
in the program disables *all* ENV folding across the whole IR tree.

### Why whole-tree, not per-function

Per-function would be more permissive (only skip in functions that
write) but semantically wrong: `ENV` is process-global, so a write in
`f` changes what `g` sees. Per-function would fold `g` using the
snapshot while `f`'s mutation invalidates it. Whole-tree matches the
"ENV read-only across the program" contract one-to-one.

### Termination

Single forward scan per function; no fixpoint. Classification is O(n)
over total instruction count. Folding phase is also O(n) — no
step-back needed because each ENV triple/tuple is independent and
produces a single `putstring`/`putnil` (no opportunity for further ENV
folds at the same site).

## Data flow

```
 Harness                       Pipeline                     Pass
   │  ENV.to_h.freeze             │                            │
   │─────────env_snapshot────────>│                            │
   │                              │──env_snapshot──via apply──>│
   │                              │                            │
   │                              │       walk IR tree         │
   │                              │       classify ENV uses    │
   │                              │       tainted?             │
   │                              │          └── yes ─> log + return
   │                              │          └── no  ─> fold each safe use
```

## Testing

### Unit tests (`optimizer/test/passes/const_fold_env_pass_test.rb`)

1. `test_folds_env_aref_with_literal_key` — `ENV["F"]` with
   snapshot `{ "F" => "1" }` → `putstring "1"`, iseq runs and returns
   `"1"`.
2. `test_folds_env_aref_3tuple_shape` — explicit
   `opt_getconstant_path; putstring; opt_aref` shape (compile with a
   variable key path that the compiler emits as the 3-tuple; use a
   constructed fixture if the normal compile always picks 2-tuple).
3. `test_folds_missing_key_to_nil` — snapshot lacks `"F"` →
   `putnil`, iseq returns `nil`.
4. `test_no_snapshot_is_noop` — `env_snapshot: nil` → instructions
   unchanged.
5. `test_env_write_disables_all_folds` — program with one
   `ENV["F"]` read *and* one `ENV["G"] = "x"` write → neither the
   read nor anything else is folded; log contains one
   `env_write_observed` entry.
6. `test_env_fetch_is_not_folded_and_taints` — `ENV.fetch("F")` is
   conservatively treated as a non-safe use, so it taints the tree.
   (Document this in the test — v2 may narrow.)
7. `test_env_aref_with_non_literal_key_is_not_folded_but_not_tainting` —
   `ENV[name]` leaves the producer safely consumed by `opt_aref`, but
   the key is not a literal so no fold happens. Must NOT taint. This
   preserves the "safe read with dynamic key" case.

### Integration test extension to `ConstFoldPass`

8. `test_folds_string_equality_triple` — `"a" == "a"` → `true`;
   `"a" == "b"` → `false`; `"a" != "b"` → `true`. Integer paths
   still work.

### End-to-end (pipeline test)

9. `test_env_feature_flag_collapses_to_boolean` — input
   `ENV["FLAG"] == "true"` with snapshot `{ "FLAG" => "true" }`. After
   `Pipeline.default.run(ir, type_env: nil, env_snapshot: snap)` the
   function's instructions reduce to a single `putobject true`.

### Corpus-level (optional for v1)

A small program that gates a fast/slow path on `ENV["FLAG"]`, run
through the pipeline, and assert the resulting iseq has no reference
to ENV. Defer if time is short.

## Logging

Two new skip reasons on `:const_fold_env`:

- `:folded` — emitted per fold, same shape as existing
  `ConstFoldPass` logs.
- `:env_write_observed` — emitted once, at the first tainted
  instruction's location, when the gate trips.

## Talk narrative fit

- **Contract slide**: before/after diff showing `ENV["FLAG"] ==
  "true"` → `true`, with a single arrow labelled "snapshot taken at
  load".
- **Contract-violation slide**: same program with a stray
  `ENV["X"] = "1"` added somewhere. All ENV folding disabled; one log
  line shown ("env_write_observed at foo.rb:12"). Sells the "rule
  that looks innocuous until it isn't" framing from the existing
  Tier 4 spec.

## Risks

- **`ConstFoldPass` string-eq extension may touch the "Integer-only"
  log path**. Mitigate: only emit `non_integer_literal` for ops that
  are still Integer-only (`opt_plus`, `opt_lt`, etc.); for `opt_eq` /
  `opt_neq` treat String-on-String as a successful fold.
- **Taint classifier over-rejects.** `ENV.fetch` is a safe read we're
  giving up on in v1. Document this; v2 can add a whitelist of
  read-only method names.
- **`opt_getconstant_path` may not be how ENV appears on the target
  Ruby version.** Verify during implementation by disassembling
  `def f; ENV["FOO"]; end` under the target Ruby and branching if
  needed. Keep the `getconstant :ENV` fallback.

## Addendum: emit-path constraint (discovered during plan)

`ObjectTable#intern` only supports special-const values
(Integer/true/false/nil). It cannot append arbitrary frozen strings
without a codec extension. Rather than couple this pass to a codec
change, v1 restricts the fold:

- snapshot value is `nil` → emit `putnil` (always possible).
- snapshot value is a String and `object_table.index_for(value)`
  returns a non-nil index → emit `putobject <idx>`.
- snapshot value is a String not present in the object table → skip
  this fold site, log `skip(pass: :const_fold_env,
  reason: :env_value_not_interned, ...)`. Other fold sites in the
  same tree (with interned values) still fold.

For the talk's canonical pattern `ENV["FLAG"] == "true"`, the RHS
`"true"` is in the object table (as `putchilledstring "true"` from
the comparison), so `index_for("true")` succeeds and the fold works.
Cases that fail to fold are an explicit narrative beat: "even the
optimizer has its limits — extending the string table stays on the
v2 list."

Queued v2 work: extend `ObjectTable#intern` + encoder
`write_special_const` branching to emit T_STRING payloads for frozen
strings. Unblocks unconditional ENV folding.

## Out-of-scope but queued for v2

- `ENV.fetch` in all its forms.
- Whitelisted read-only methods (`to_h` when nothing mutates ENV).
- Per-function taint scoping when call-graph guarantees no
  inter-function ENV aliasing. Unlikely to be worth it; listed for
  completeness.
