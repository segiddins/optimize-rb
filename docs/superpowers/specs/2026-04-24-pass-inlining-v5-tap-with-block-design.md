# InliningPass v5 — `send` with block iseq, with invokeblock substitution

## Goal

Reduce `5.tap { nil }` (and the general pattern of a 0-arg `send` with a non-escaping, non-capturing block attached) to the same bytecode the method body would compile to when the block is substituted into every `invokeblock` site and the callee's `self` is rebound to the caller's receiver.

Concretely, given a compilation unit containing both

```ruby
def tap
  yield self
  self
end

5.tap { nil }
```

after the pipeline runs, the top-level caller iseq must be

```
putobject 5
leave
```

## Scope

v5 handles a narrow but complete slice:

- Caller send: `send` opcode (not `opt_send_without_block`), `argc == 0`, block operand is a block iseq.
- Callee: satisfies every v4 inlining precondition (resolvable via `callee_map`, ≤ `INLINE_BUDGET`, single trailing `leave`, no forbidden control-flow opcodes, empty catch table).
- Block iseq: empty catch table, no level-1 local access ("no captures"), no opcode in the `BLOCK_FORBIDDEN` set ("no escapes"), all `leave`s at block scope top.
- `invokeblock` sites inside the callee: `ARGS_SIMPLE`, known `argc`, no splat, no kwargs.

Out of scope for v5: `argc > 0` on the outer send, block-pass (`&blk`), symbol-to-proc, BMETHOD callees, nested block/proc creation, catch tables on either iseq, level-1 captures inside the block body. Each of these is a skip path with a `log.skip` reason.

## Pipeline placement

`Pipeline.default` is unchanged. v5 extends `InliningPass` (still one-shot, still at the head of the pipeline). All cleanup is delegated to the existing fixed-point iterative set (`DeadStashElimPass`, `ArithReassocPass`, `ConstFoldTier2Pass`, `ConstFoldEnvPass`, `ConstFoldPass`, `IdentityElimPass`, `DeadBranchFoldPass`). No new pass slot, no reordering.

## Recognition

A new rewrite branch inside `InliningPass#apply`, alongside the existing FCALL and OPT_SEND branches:

```
when opcode == :send
  cd = operands[0]
  blk = operands[1]
  next unless cd.argc == 0 && blk.is_a?(IR::Function) && blk.type == :block
  next unless callee_map resolves cd.mid to a v4-inlineable callee
  next unless block_inlineable?(blk)
  next unless callee_invokeblock_sites_compatible?(callee, blk)
  splice(...)
```

Receiver discovery reuses v4's `ARG_PUSH_OPCODES` single-instruction producer check against `insts[send_idx - 1]`.

## Splice recipe

Given caller region `R; send mid argc:0, blk` where `R` is the single-instruction receiver producer:

1. **Receiver stash.** Allocate a fresh level-0 local `R_slot`. Replace `R` with `R; setlocal_WC_0 R_slot`. Inside the spliced callee body, every `putself` is rewritten to `getlocal_WC_0 R_slot`. This is v4's existing receiver-binding step, unchanged.

2. **Invokeblock substitution (for each `invokeblock` site in the callee body):**

   a. Read `argc` from the site's calldata. The pushed arguments are already on the stack in call order.

   b. Allocate `argc` fresh level-0 locals `A_0 .. A_{argc-1}`. Emit `setlocal_WC_0` for each in reverse stack order so the topmost stack value lands in `A_{argc-1}`.

   c. Build a per-splice remap for every level-0 local index in the block's local table. Parameter slots map to the matching `A_i`. Non-parameter slots (block-internal temps) map to freshly allocated slots in the enclosing scope via the same allocator v4 uses for callee temps. Splice the block body inline applying this remap to every `getlocal`/`setlocal` level-0 operand.

   d. The block is required to have exactly one `leave` at block scope top (guarded). Drop that trailing `leave` and splice `block.instructions[0..-2]`. Because the block has no branches (guarded via `BLOCK_FORBIDDEN`), no label or jump is needed — the block's return value naturally ends up on top of the stack at the splice point.

3. **Callee trailing `leave`.** Handled identically to v4: converted to `jump L_call_end` (or dropped if already last) so the caller's original trailing `leave` executes next.

## Canonical output shape

The splice is shaped so the fixed-point cleanup cascade closes the gap without any new pass. For `5.tap { nil }`:

```
putobject 5
setlocal_WC_0 R_slot          # (1) receiver stash
setlocal_WC_0 A0              # (2b) stash invokeblock arg (self=5)
putnil                        # (2c) block body (leave dropped by 2d)
pop                           # callee's `pop` after invokeblock
getlocal_WC_0 R_slot          # (1) callee's second putself
                              # (3) callee leave → fallthrough to L_call_end
leave                         # caller's original trailing leave
```

Cleanup cascade:

- `A0` is written, never read → `DeadStashElimPass` drops `setlocal A0` and its producer.
- `putnil; pop` is pure-producer + discard → `IdentityElimPass`/`ConstFoldPass` eliminates it.
- `R_slot` has exactly one reader (`getlocal_WC_0 R_slot`) and one literal writer (`putobject 5; setlocal_WC_0 R_slot`) → `DeadStashElimPass` forwards the literal and drops the stash.

Final: `putobject 5; leave`.

## Guards

| Guard | Skip reason | Rationale |
|---|---|---|
| outer send is `:send` with `argc == 0` and block iseq | `:send_shape_unsupported` | v5 scope |
| callee resolvable in `callee_map` and v4-inlineable | `:callee_not_inlineable` | reuse v4 preconditions |
| block has empty catch table | `:block_has_catch_table` | no escape handling |
| block has no level-1 local access | `:block_captures_level1` | no captures scope |
| block uses no opcode in `BLOCK_FORBIDDEN` (any `CONTROL_FLOW_OPCODES` entry, `throw`, `break`, `next`, `redo`, `invokesuper*`, `send` with block iseq, block/proc creation) | `:block_escapes` | no escapes / straight-line splice |
| block has a single trailing `leave` and no other `leave` | `:block_nested_leave` | drop-and-splice with no label/jump |
| every `invokeblock` site inside callee has `ARGS_SIMPLE`, known `argc`, no splat/kw | `:invokeblock_complex_call` | mirrors v4 calldata restrictions |

Every skip path calls `log.skip(pass: :inlining, reason:, file:, line:)` so the §5 demo walkthrough renders the exact bailout reason.

## Data flow

`InliningPass` already receives `callee_map`, `object_table`, `slot_type_map`, `signature_map`, `env_snapshot` via `apply`. v5 needs no additional kwargs: the block iseq is available as a direct operand on the `send` instruction, and v4's existing receiver/argument-stash bookkeeping carries over to the invokeblock path.

`LocalTable.shift_level0_lindex!` (extracted in `aa0b146`) is reused for renumbering block-internal `getlocal`/`setlocal` level-0 references after the splice. This is the same call v4 already makes on callee bodies; the only new caller is the block-body splice loop.

## Testing

### Unit tests

New file `optimizer/test/passes/tap_inline_pass_test.rb`:

- **Positive**: `5.tap { nil } → putobject 5; leave`. Method body is a user-supplied `def tap; yield self; self; end` in the same compilation unit.
- **Positive, identity block**: `x = some_int; x.tap { |y| y }` with `x` as a local. Assert the inlined result reduces to a single `getlocal` + `leave`.
- **Positive, multi-instruction block**: `5.tap { 1 + 2 }` reduces to `putobject 5; leave` (block result is folded to `3`, then dropped by the `pop` following invokeblock).
- **Bailout per guard**: one test per row of the guards table above. Each asserts no splice and a `log.skip` with the expected reason.

Reuse `build_guard_caller` from the existing yield test at `inlining_pass_test.rb:707`.

### Corpus / round-trip

Add under `optimizer/test/codec/corpus/`:

- `tap_constant_block.rb` — `5.tap { nil }` with a local `tap` stub.
- `tap_identity_block.rb` — `x.tap { |y| y }` with a local `tap` stub.

Round-trip harness verifies encode → decode → optimize → execute returns the same value as an unoptimized run.

### Pipeline test

Add a case to `optimizer/test/pipeline_test.rb` that runs the full default pipeline against `tap_constant_block.rb` and asserts the top-level caller iseq disasms to exactly `putobject 5; leave` (not just returns 5).

### Demo walkthrough

New §5 walkthrough entry `optimizer/examples/5_tap_nil.rb` (or an equivalent under the demo runner's source list). The walkthrough renderer already produces per-pass iseq diffs; this entry drives the talk's "§7 punchline".

## Risks

1. **Shared block iseqs.** The disassembly at the top of this brainstorm showed the block iseq listed twice in the `disasm` output, which hints the block iseq may be referenced from more than one place. The splice must not mutate the shared iseq; it must deep-copy before applying local-slot renumbering. Same invariant v4 already maintains for callee bodies.

2. **Slot-index exhaustion.** Each splice allocates `1 + argc + block_local_count` new level-0 slots. With `MAX_ITERATIONS = 8` and one-shot inlining, worst-case growth is bounded per function but still larger than v4. `LocalTable` has no documented cap; add a test that exercises a deeply-nested case if one arises in the corpus.

3. **`invokeblock` with `argc == 0`** (e.g. `def each_none; yield; end`). `yield` with no arguments still binds `self` implicitly in YARV? Verify via `mcp__ruby-bytecode__disasm` before implementation — if the compiler inserts a `putself` regardless, the `argc == 0` path needs no special handling; if not, it's still trivially handled (empty stash step).

## Out of scope (future)

- Block-pass (`&blk`), symbol-to-proc, `Proc.new`, `lambda`, `->`.
- Blocks that capture level-1 locals. This needs a rewrite that lifts captured locals into stash slots in the enclosing scope — mechanically similar to what v5 already does for block parameters but with more bookkeeping to preserve write-through semantics.
- Catch-table-aware splicing (rescue/ensure inside the block or callee).
- Outer send with `argc > 0`. The mechanism extends cleanly; it was excluded from v5 only to keep the first cut small.
