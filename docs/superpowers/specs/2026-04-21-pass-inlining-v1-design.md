# Spec: Inlining Pass — v1 (zero-arg, constant-body)

**Part of:** [Ruby the Hard Way](2026-04-19-talk-structure-design.md)
**Supersedes (narrower scope):** [Inlining Pass (full vision)](2026-04-19-pass-inlining.md)
**Plan:** `docs/superpowers/plans/2026-04-21-pass-inlining-v1.md`

## Purpose

Ship the first inlining pass as a narrow, clearly scoped subset of the
full vision. v1 demonstrates method-call elimination end-to-end with no
type environment, no local-table growth, and no CFG splicing across
basic blocks. Later versions (v2+) layer the harder machinery on top.

## Why this scope

The shipped IR and codec don't currently expose per-call metadata:
`opt_send_without_block` in IR has empty operands because `ci_entries`
is round-tripped as opaque bytes. Any inlining requires first decoding
`ci_entries` and attaching each record to the send that consumes it.

Given that groundwork, v1 chooses the smallest transformation that
still demos useful: inline a zero-argument `FCALL` whose callee body
has no locals, no branches, no catch entries, and no nested sends.
This constraint set:

- lets us splice the callee instruction-for-instruction without
  touching the local table, `stack_max` (beyond existing codec
  handling), or catch-table offsets
- keeps precondition checks a pure opcode-list scan
- still produces a visible end-to-end effect: the `opt_send` and its
  `putself` disappear, and the round-tripped iseq executes correctly

## Preconditions

### At the call site

A call site is a candidate iff it is exactly the instruction pair
`putself; opt_send_without_block` (no intervening instructions), the
`putself` is not a branch target, and the send's `CallData` satisfies:

- `FCALL` flag set
- `ARGS_SIMPLE` flag set
- `argc == 0`
- `kwlen == 0`
- no splat (`ARGS_SPLAT`), no blockarg (`ARGS_BLOCKARG`)

### On the callee

v1 requires the callee `IR::Function` to satisfy all of:

- no arguments: `lead_num == 0`, `opt_num == 0`, `post_num == 0`,
  no rest arg, no block arg, no kwargs
- `local_table_size == 0`
- empty `catch_entries`
- body (instructions minus the trailing `leave`) contains **no**:
  - branch/jump opcodes (`branchif`, `branchunless`, `branchnil`,
    `jump`, `opt_case_dispatch`)
  - local-access opcodes (`getlocal`, `setlocal`, `getlocal_WC_0`,
    `setlocal_WC_0`, `getlocal_WC_1`, `setlocal_WC_1`)
  - "real" send opcodes (`send`, `opt_send_without_block`,
    `invokesuper`, `invokesuperforward`, `invokeblock`,
    `opt_str_uminus`, `opt_duparray_send`, `opt_newarray_send`)
  - extra `leave` or `throw` instructions
- total instruction count ≤ `INLINE_BUDGET = 8` (including the
  trailing `leave`)
- ends with exactly one `leave` as the last instruction

Note: `opt_plus`/`opt_minus`/`opt_mult`/`opt_div`/`opt_*` arithmetic
and comparison opcodes technically carry calldata, but under the "no
core BOP redef" contract these are not considered method calls for
inlining purposes — they are allowed in the callee body.

## Transformation

Splice `[putself, opt_send_without_block]` with the callee's
instructions **minus the trailing `leave`**. Because the `opt_send`
carried its `CallData` as an operand (post-Task 2), removing it from
the instruction list automatically drops the callee's ci entry when
the iseq is re-encoded (the encoder harvests ci entries from the
instructions it walks).

Line numbers: spliced instructions keep their callee-side line numbers.
That's the lesser surprise: the disassembly of `use_it` after
inlining looks like the callee's body (readable), and the backtrace
effect (the callee frame disappears) is the point of the
transformation.

## Failure behavior

On any precondition miss, log a structured reason and leave the call
site unchanged. Reasons used:

- `:unsupported_call_shape` — calldata didn't match (e.g. not FCALL,
  argc != 0, has block)
- `:callee_unresolved` — mid doesn't map to a known iseq in the
  callee map
- `:callee_has_args`
- `:callee_has_locals`
- `:callee_has_catch`
- `:callee_has_branches`
- `:callee_makes_call`
- `:callee_has_leave_midway`
- `:callee_has_throw`
- `:callee_empty`
- `:callee_over_budget`
- `:callee_no_trailing_leave`

On successful splice: `:inlined`.

The pass never raises on a failed inline.

## Out of scope for v1

Listed here explicitly so future sessions don't burn cycles
rediscovering the line:

- Any positional or keyword argument (one-arg inline is the v2 target)
- Blocks, block passing, `invokeblock`
- Nested sends in the callee body (one level of splicing only)
- `super` / `invokesuper`
- CFG splicing across basic-block boundaries (only straight-line callees)
- Callees with any local (`local_table_size > 0`)
- Callees with any catch entry (rescue/ensure/next/redo)
- RBS-typed receiver resolution (v1 resolves only by `mid` symbol
  lookup in the callee map)
- Method-receiver sends (`obj.foo` with non-self receiver)
- Polymorphic call sites
- Wrapper-method flattening (the v2 payoff demo)
- Recursive inlining (re-scanning the spliced region for new
  inline candidates)

## Callee map construction

Built once by `Pipeline#run`, not by the pass itself. The map is
`Hash{Symbol => IR::Function}`, keyed by method name, containing every
`Function` in the IR tree whose `type == :method`. Collisions (two
methods of the same name, e.g. `def foo` redefined inside a nested
class) take the last-seen wins; v1 logs and accepts the ambiguity.
v2 will upgrade to a qualified key once class-scoped resolution matters.

## Not a demo yet

v1 is correct but not compelling on its own — "constant-returning
helper gets folded" is a footnote. The talk's inlining slide wants
wrapper-flattening (v2 at minimum). v1 exists to:

1. prove the ci_entries decoding works
2. prove the splice mechanics work
3. provide a narrow green baseline so v2 can extend without fighting
   codec fires
