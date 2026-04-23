# Codec: signed OFFSET round-trip + `sum_of_squares` fixture restore

Date: 2026-04-23
Status: Design

## Problem

The codec cannot round-trip `while` loops. Any backward branch trips a decode
error:

```
OFFSET raw=<2^64 - n> in branchif targets slot <2^64 - m> with no corresponding instruction
```

Reproduces on any trivial loop, e.g.
`def f(n); i=0; while i<n; i+=1; end; end`.

YARV stores branch targets as a **signed** relative slot offset
(`target_slot - next_insn_slot`). For a backward branch the offset is
negative. CRuby's `ibf_dump_small_value` takes a `VALUE` (`unsigned long`);
a C `long` containing a negative number is implicitly reinterpreted as a
huge unsigned integer, which always overflows the compact forms and lands
in the 9-byte branch of the encoding. CRuby reads it back into a signed
`long` via the same implicit conversion, getting the original negative
number. That pun does not happen in Ruby — our `Integer` is unbounded,
so a `(1 << 64) - n` literally stays `(1 << 64) - n`.

Two symmetric bugs fall out:

- **Decode** (`optimizer/lib/optimize/codec/instruction_stream.rb:324`):
  `read_small_value` returns the raw unsigned integer; the subsequent
  `next_insn_slot + raw_offset` arithmetic produces an impossible slot
  and the lookup at line 360 raises.
- **Encode** (`optimizer/lib/optimize/codec/instruction_stream.rb:417`):
  `write_small_value` explicitly rejects negative inputs
  (`binary_writer.rb:39`). Even if decode were fixed, any pass preserving
  a backward branch would blow up on re-encode. This path is currently
  untested — every encode test uses forward-only control flow.

This blocks the `sum_of_squares` demo fixture, which was reverted in
`revert(examples): drop sum_of_squares …`, and any future loop-bearing
demo or pass. It is filed as the top two bullets under "Known bugs /
blockers" in `docs/todo.md`.

## Goals

1. Decode + encode a `while`-bearing iseq without error.
2. Re-encoded bytecode is bit-identical to what CRuby would produce for
   the same iseq (so `InstructionSequence.load_from_binary` accepts it).
3. Restore the `sum_of_squares` demo fixture end-to-end as the motivating
   integration test.

## Non-goals

- Loop-aware optimization passes (loop-invariant hoisting, zero-trip
  elimination, infinite-loop detection). These are listed under
  "Exploratory, not yet on any roadmap" in `docs/todo.md` and stay there.
- Full CFG-level DCE. `DeadBranchFoldPass`'s peephole window does not
  match the `<comparison>; branchunless <backward>` shape of a `while`,
  and that remains out of scope.
- Changes to the small_value primitive or IBF wire format. The format is
  unsigned; only OFFSET operands carry signed semantics.

## Design

### Sign handling lives at the `:OFFSET` operand boundary

The IBF small_value primitive is agnostic to sign — every other consumer
(VALUE, CDHASH, ID, ISEQ, LINDEX, NUM, ISE, IVC, ICVARC, IC, and the
`:BUILTIN` idx/len fields) is an unsigned table index or count. Only
`:OFFSET` is semantically signed, because branch targets can be earlier
or later than the branching instruction. Pushing signedness into
`read_small_value` / `write_small_value` would risk silent misinterpretation
of an unsigned table index that happens to exceed `2^63`. Sign conversion
belongs at the two OFFSET call sites.

### Helpers

Add two module-level helpers on `Optimize::Codec::InstructionStream`:

```ruby
U64_MASK  = (1 << 64) - 1
INT64_MIN = -(1 << 63)
INT64_MAX =  (1 << 63) - 1

def self.u64_to_i64(u)
  u >= (1 << 63) ? u - (1 << 64) : u
end

def self.i64_to_u64(i)
  raise ArgumentError, "offset out of i64 range: #{i}" if i < INT64_MIN || i > INT64_MAX
  i & U64_MASK
end
```

Placement: private constants and private `self.` methods at the top of
`InstructionStream`, near the existing `slots_for` helper.

### Decode change

In the `:OFFSET` branch of the operand loop (`instruction_stream.rb:322`):

```ruby
when :OFFSET
  offset_operand_positions << [insn_idx, op_idx]
  u64_to_i64(reader.read_small_value)  # raw relative offset, sign-extended
```

The subsequent fixup loop at line 354 works unchanged — it already does
`next_insn_slot + raw_offset`, which for a negative `raw_offset` yields
an earlier `target_slot`. The `slot_to_insn_idx` lookup at line 359 finds
the instruction at the top of the loop and the raise at line 360 stays
as the guard for genuinely corrupt offsets.

### Encode change

In the `:OFFSET` branch of the operand loop (`instruction_stream.rb:411`):

```ruby
when :OFFSET
  target_insn_idx = insn.operands[operand_idx]
  target_slot = insn_to_slot[target_insn_idx]
  raise "OFFSET operand #{target_insn_idx} has no corresponding slot (out of range?)" unless target_slot
  writer.write_small_value(i64_to_u64(target_slot - next_insn_slot))
  operand_idx += 1
```

A negative offset after `i64_to_u64` always exceeds `0x0FFFFFFF`, so it
lands in the 9-byte form of `write_small_value`. That matches
`ibf_dump_small_value` exactly for a negative C long.

### No other files touched

`binary_reader.rb` and `binary_writer.rb` stay as-is. Their contracts
remain: small_value is unsigned, and `write_small_value` continues to
reject negative inputs (the conversion happens before the call).

## Test ladder

### 1. Codec round-trip unit tests

In `optimizer/test/codec/round_trip_test.rb`:

- **Synthetic negative-offset test.** Hand-build a tiny instruction list
  with a `branchif` whose target index is earlier than the branch.
  Encode, decode, assert the decoded operand is the same instruction
  index. This catches sign handling with no loop machinery involved.
- **End-to-end `while` round-trip.** Use the `ruby-bytecode` MCP
  `iseq_to_binary` tool to compile
  `def f(n); i=0; while i<n; i+=1; end; i; end` to a binary iseq.
  Decode → assert the instruction list contains a `branchif`/`branchunless`
  with a target earlier than itself → re-encode → assert the re-encoded
  binary reloads via `load_iseq_binary` and produces the same instruction
  stream on a second decode. This is the integration guard.
- **Boundary**: one test for `u64_to_i64((1 << 63) - 1)` (`INT64_MAX`,
  positive) and one for `u64_to_i64(1 << 63)` (`INT64_MIN`,
  most-negative).

### 2. Fixture restore

Recover `examples/sum_of_squares.rb` and
`examples/sum_of_squares.walkthrough.yml` from the revert commit:

```
jj log -r 'description(glob:"revert(examples): drop sum_of_squares*")' \
  --no-pager
```

(or the equivalent `jj diff -r <revert>` to resurrect the files).
Regenerate `docs/demo_artifacts/sum_of_squares.md` via `bin/demo`
and update `rake demo:verify` to cover it.

### 3. Honesty about payoff

Most passes will show `(no change)` on the `sum_of_squares` walkthrough
today — none of the shipped passes reason about loops. That is acceptable
and expected. The fixture's job here is (a) prove codec correctness on a
real-world loop, (b) surface `while` in the demo pipeline so future
loop-aware passes have a canonical place to land. The walkthrough should
call this out in its YAML header so the artifact is not mis-read as
"optimizations don't work on loops".

## Rollout

Single plan, single PR-shaped branch:

1. Helpers + decode + encode changes in `instruction_stream.rb`.
2. Round-trip unit tests (synthetic + `while`).
3. Fixture restore (`examples/sum_of_squares.*` + `docs/demo_artifacts/…`).
4. `rake demo:verify` coverage.
5. Update `docs/todo.md`: strike the two "Known bugs / blockers" entries
   on codec backward-branch decode/encode, mark the `sum_of_squares`
   follow-up under "Roadmap gap #2" as shipped.

## Risks

- **Non-branch OFFSET opcodes.** All current users of `:OFFSET` that I
  can see are the branch family (`branchif`, `branchunless`, `branchnil`,
  `jump`, short-circuit variants). The fix is uniform across them since
  OFFSET always means "relative slot offset from the next instruction".
  No opcode-specific casing needed.
- **Offset overflow in a generated pass.** If a future pass emits a
  branch whose target is more than `INT64_MAX` slots away, `i64_to_u64`
  raises. A real iseq cannot plausibly be that large; the raise is a
  correctness guard, not a user-facing constraint.
- **Re-encode byte-identity.** Compact forms for small positive offsets
  still round-trip the same way they did before — the change affects only
  values that would already have been rejected or misread.
