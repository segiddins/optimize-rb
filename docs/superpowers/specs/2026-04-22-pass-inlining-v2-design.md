# Spec: Inlining Pass — v2 (one-arg FCALL, local-table growth)

**Part of:** [Ruby the Hard Way](2026-04-19-talk-structure-design.md)
**Supersedes (narrower scope):** [Inlining Pass (full vision)](2026-04-19-pass-inlining.md)
**Builds on:** [v1 design](2026-04-21-pass-inlining-v1-design.md)
**Plan:** `docs/superpowers/plans/2026-04-22-pass-inlining-v2.md`

## Purpose

Extend InliningPass from the zero-arg, zero-local v1 slice into the
narrowest slice that can demo **wrapper-method flattening** — the
talk's canonical inlining payoff (§4 of talk-structure-design). v2 adds
exactly one capability: a single positional argument that is
materialised as a new caller-side local.

Concretely, v2 unblocks a demo like:

```ruby
def double(x) = x * 2
def use_it(n) = double(n)
use_it(7)  # → after v2: use_it's body becomes `n * 2` inline
```

With ArithReassoc and const-fold sitting downstream, cascades like
`double(double(3))` → `12` become demonstrable end-to-end.

## Why this scope

The infrastructure gap between v1 and the full vision is large:
receiver resolution via RBS, polymorphic call sites, CFG splicing
across basic blocks, rescue/ensure handling, recursive inlining. v2
picks off the single highest-leverage piece — "the callee takes one
arg" — and defers everything else.

The real complexity v2 introduces is **codec work**:

- The caller's `local_table` grows by one entry (the slot holding the
  passed arg). Today `local_table_raw` is an opaque byte blob, and
  `local_table_size` is propagated through `misc`. We need a structured
  decode/encode.
- Every `getlocal*` / `setlocal*` instruction in the caller already in
  the body uses a LINDEX that is a function of `local_table_size`
  (CRuby computes the runtime EP offset as `local_table_size + ENV_SIZE
  − 1 − table_index`). Appending at the end of the table shifts
  existing locals' EP offsets — **but the on-wire LINDEX (table index)
  is unchanged**. Verify this empirically in Task 1 before assuming it.
- The single local read inside the callee body (`getlocal_WC_0 1, 0`
  for a one-arg method with no other locals) must be rewritten to
  reference the caller's newly-allocated slot. This is a per-call-site
  remap driven by the inlining pass, not the codec.

Given this, v2 pairs one codec task (`local_table` structured
round-trip + `grow!` primitive) with one pass extension (widen v1's
callee/call-site preconditions; synthesise `setlocal; <rewritten
callee body>`).

## Preconditions

### At the call site

A candidate site is exactly three instructions:

```
<push-arg>               # any single straight-line expression that leaves one value on the stack
opt_send_without_block   # cd.argc == 1
```

v2 simplifies by requiring that the `<push-arg>` occupy **exactly one
instruction slot**. Start with the minimal set:

- `putobject <lit>` (any literal the codec already handles)
- `putobject_INT2FIX_0_`, `putobject_INT2FIX_1_`
- `putnil`, `putstring`
- `getlocal_WC_0 <idx>` (the common shape for forwarding a param)

and one preceding `putself` (as v1 required). Anything else —
multi-instruction pushes, blocks of instructions, any branch target on
the push — skips with `:unsupported_call_shape`.

`CallData` preconditions are v1's with argc widened:

- `FCALL` flag set
- `ARGS_SIMPLE` flag set
- `argc == 1`
- `kwlen == 0`
- no splat (`ARGS_SPLAT`), no blockarg (`ARGS_BLOCKARG`)

### On the callee

- exactly one lead arg: `lead_num == 1`, `opt_num == 0`, `post_num ==
  0`, no rest, no block, no kwargs
- `local_table_size == 1` (just the single arg; no other locals)
- empty `catch_entries`
- v1's body constraints (no branches, no local-writes to other slots,
  no nested sends, ≤ `INLINE_BUDGET`, ends in `leave`)
- body local reads may touch **only** the arg slot — specifically
  `getlocal_WC_0 1, 0` or the equivalent `getlocal 1, 0`. Any
  `setlocal*` anywhere in the body disqualifies (`:callee_writes_local`).
- body may not read from outer scope (`getlocal_WC_1`, etc.) — already
  caught by v1's `LOCAL_OPCODES` list; keep rejecting these with
  `:callee_has_locals` renamed to `:callee_reads_outer_local` only
  for v2 clarity.

## Transformation

**LINDEX reality check (verified empirically):** the IR stores raw
YARV EP offsets, where `LINDEX = VM_ENV_DATA_SIZE (3) + (local_table_size
− 1 − table_index)`. Two consequences that drive the transformation:

- The **last-appended slot** (the one `grow!` returns) has LINDEX = 3,
  regardless of table size.
- Growing `local_table_size` by 1 shifts every pre-existing LINDEX at
  level 0 up by 1. Level-1 LINDEXes (outer EP) are unaffected.

Transformation:

1. Allocate a caller-side slot via `LocalTable.grow!`, reusing the
   callee's arg-Symbol object-table index (read from the callee's
   local_table; avoids extending `ObjectTable.intern` to new Symbols).
   Local names are cosmetic at runtime — YARV uses indices — so
   shadowing any caller local with the same name is harmless.
2. **Shift every pre-existing caller LINDEX at level 0 by +1.** This
   applies to `getlocal_WC_0`, `setlocal_WC_0`, and `getlocal`/`setlocal`
   with level operand == 0. Level-1 opcodes are left alone. Apply the
   shift across the whole instruction list *before* the splice — the
   ops about to be removed are shifted too, which keeps the logic
   uniform and doesn't affect the final state.
3. Replace the three-instruction call-site region `putself;
   <arg-push>; opt_send_without_block` with:
   - `<arg-push>` (leaves the value on the stack; if it's a
     `getlocal_WC_0`, it already reflects the shift from step 2)
   - `setlocal_WC_0 3` (the new slot's LINDEX is always 3)
   - the callee body minus the trailing `leave`, spliced as-is
4. **No LINDEX rewrites inside the spliced callee body.** The callee's
   `getlocal_WC_0 3` arg-read was sized for `lt_size == 1` and lands
   at LINDEX 3 post-splice, exactly matching the caller's new slot.
   This is the invariant that makes the splice clean: "last-appended
   slot has LINDEX 3 regardless of table size."
5. Drop the send's `CallData` record — handled automatically by
   re-harvesting ci_entries from the rewritten instruction stream.

Line numbers: same policy as v1 (spliced instructions keep their
callee-side line numbers).

## Callee-local-count assumption

This is the load-bearing invariant of v2: the callee has **exactly
one** local (the single arg), so all `getlocal 1,0` / `getlocal_WC_0
1,0` reads in the body map to that one slot. If a future callee has
more locals, the remap becomes a real table merge — reserved for v3.

## Failure behavior

v1's skip reasons carry through unchanged. v2 adds:

- `:callee_writes_local` — callee body contains `setlocal*`
- `:callee_multi_local` — `local_table_size > 1`
- `:unsupported_arg_shape` — the pre-send instruction is not in the
  whitelist (literal, `putnil`, `putstring`, `getlocal_WC_0 <idx>`)
- `:callee_local_table_unreadable` — pathological fixture where the
  callee's local_table fails to round-trip (should be impossible
  post-Task 1; guard anyway)

All other v1 reasons remain applicable; `:inlined` success log reason
is unchanged.

## Out of scope for v2

- More than one positional argument (v3)
- Optional/keyword/rest arguments, block param, block arg, splat
- Multiple callee locals beyond the arg
- Any `setlocal*` in the callee body (self-modifying params)
- Arg expressions spanning >1 instruction (e.g. `double(a+b)`) —
  require an intermediate IR primitive and are deferred to v3
- RBS-typed receiver resolution, method-receiver sends (`obj.foo`)
- Wrapper flattening **across** more than one call depth — v2 gives
  us one level; the talk's cascade demo (`double(double(x))`) relies
  on v2 running to fixpoint, which v1's outer `loop` already does
- Dead caller-local cleanup: if an inlined arg slot is never read
  (e.g. callee ignores its param), the slot sticks around wasted.
  Acceptable for v2.

## Codec deliverable: `LocalTable` module

Today `misc[:local_table_raw]` is opaque bytes and `misc[:local_table_size]`
is a field parsed into the body record. v2 needs three new codec
capabilities, grouped in a new `Codec::LocalTable` module:

- `LocalTable.decode(bytes, size)` → `Array<Integer>` of object-table
  indices (one per entry). Format per `research/cruby/ibf-format.md`
  §4.1: `ID[local_table_size]`, where `ID` is a `uintptr_t` —
  fixed-width 8-byte little-endian on 64-bit (not small_value-encoded;
  that's a trap the v1 `ci_entries` format falls into and is easy to
  mistakenly apply here).
- `LocalTable.encode(entries)` → bytes.
- `LocalTable.append!(function, object_table, name)` → `Integer`
  (the new slot's table index). Mutates:
  - the function's parsed local-table entry list
  - `misc[:local_table_size]`
  - `misc[:local_table_raw]` (re-encoded)
  - whatever ObjectTable API is needed to intern `name` as a Symbol

All three must be covered by a round-trip test: for every corpus
fixture, decode+encode yields byte-identical output; for a
synthetic case, append+re-encode produces a body whose
`load_from_binary` round-trip succeeds.

## `stack_max` recomputation

The codec already recomputes `stack_max` after instruction edits
(see `Codec::StackMax`). Adding `setlocal` at the start of the
splice bumps caller stack demand by zero (setlocal pops one,
callee body then pushes back up to its leave height). No manual
adjustment expected. **Verify** via the round-trip integration test
in Task 5, not by eyeballing.

## Not-yet-scoped follow-ups (for future sessions)

- Slot reuse / SSA-style arg sharing when an inlined param is
  provably single-use
- Re-scanning the spliced region for new inline candidates
  (v1's loop only catches call sites that survived splicing;
  a call exposed *inside* a spliced callee body isn't re-tried
  because v2 still rejects callees with nested calls)
- Actually wiring the `double(double(x))` cascade fixture into
  the demo program list — that's a talk-content task, not a
  pass task
