# Codec signed OFFSET round-trip + `sum_of_squares` fixture — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix `InstructionStream.{decode,encode}` so backward branches (`while` loops) round-trip, then restore the `sum_of_squares` demo fixture as the motivating end-to-end test.

**Architecture:** Add two private sign-conversion helpers (`u64_to_i64` / `i64_to_u64`) on `Optimize::Codec::InstructionStream` and apply them only at the two `:OFFSET` call sites. `binary_reader.rb` / `binary_writer.rb` primitives stay unsigned — signedness is a property of the `:OFFSET` operand type, not the IBF wire format. A negative offset always encodes as the 9-byte small_value form, matching CRuby's `ibf_dump_small_value` byte-for-byte.

**Tech Stack:** Ruby 4.x, Minitest, `RubyVM::InstructionSequence.{compile,to_binary,load_from_binary}`, `rake`, `bin/demo`, `jj` for VCS.

**Spec:** `docs/superpowers/specs/2026-04-23-codec-signed-offset-and-while-fixture-design.md`

---

## File Structure

**Modified:**
- `optimizer/lib/optimize/codec/instruction_stream.rb` — add `U64_MASK` / `INT64_MIN` / `INT64_MAX` constants, `u64_to_i64` / `i64_to_u64` helpers; use in `:OFFSET` branches of `decode` (line 324) and `encode` (line 417).
- `optimizer/test/codec/round_trip_test.rb` — add synthetic negative-offset test and `while`-round-trip test.
- `docs/todo.md` — strike the two "Known bugs / blockers" entries for codec backward branches; mark the `sum_of_squares` follow-up under Roadmap gap #2 as shipped.

**Created:**
- `optimizer/examples/sum_of_squares.rb` — restored from the reverted commit.
- `optimizer/examples/sum_of_squares.walkthrough.yml` — new sidecar; was never created before the revert.
- `docs/demo_artifacts/sum_of_squares.md` — regenerated via `bin/demo sum_of_squares`.

**Not touched (intentional):**
- `optimizer/lib/optimize/codec/binary_reader.rb` / `binary_writer.rb` — primitives stay unsigned.
- `optimizer/Rakefile` — `demo:verify` globs `examples/*.walkthrough.yml`, so the new fixture is picked up without edits.

---

## Task 1: Add signed↔unsigned helpers on `InstructionStream`

**Files:**
- Modify: `optimizer/lib/optimize/codec/instruction_stream.rb` (add constants + helpers just below the `module InstructionStream` opener at line 10)
- Test: `optimizer/test/codec/round_trip_test.rb` (new helper-boundary test)

- [ ] **Step 1: Write the failing test**

Append at the end of `RoundTripTest` in `optimizer/test/codec/round_trip_test.rb`:

```ruby
  def test_u64_to_i64_boundaries
    # Positive values within i64 round-trip identity.
    assert_equal 0,                 Optimize::Codec::InstructionStream.u64_to_i64(0)
    assert_equal 1,                 Optimize::Codec::InstructionStream.u64_to_i64(1)
    assert_equal (1 << 63) - 1,     Optimize::Codec::InstructionStream.u64_to_i64((1 << 63) - 1)

    # The high bit flips to negative.
    assert_equal(-(1 << 63),        Optimize::Codec::InstructionStream.u64_to_i64(1 << 63))
    assert_equal(-1,                Optimize::Codec::InstructionStream.u64_to_i64((1 << 64) - 1))
    assert_equal(-2,                Optimize::Codec::InstructionStream.u64_to_i64((1 << 64) - 2))
  end

  def test_i64_to_u64_boundaries
    # Non-negative values pass through.
    assert_equal 0,             Optimize::Codec::InstructionStream.i64_to_u64(0)
    assert_equal (1 << 63) - 1, Optimize::Codec::InstructionStream.i64_to_u64((1 << 63) - 1)

    # Negative values become (2^64 + n).
    assert_equal (1 << 64) - 1, Optimize::Codec::InstructionStream.i64_to_u64(-1)
    assert_equal (1 << 64) - 2, Optimize::Codec::InstructionStream.i64_to_u64(-2)
    assert_equal 1 << 63,       Optimize::Codec::InstructionStream.i64_to_u64(-(1 << 63))

    # Out-of-range raises.
    assert_raises(ArgumentError) { Optimize::Codec::InstructionStream.i64_to_u64(1 << 63) }
    assert_raises(ArgumentError) { Optimize::Codec::InstructionStream.i64_to_u64(-(1 << 63) - 1) }
  end

  def test_round_trip_helpers_compose
    [-5, -1, 0, 1, 5, (1 << 62), -(1 << 62)].each do |i|
      u = Optimize::Codec::InstructionStream.i64_to_u64(i)
      assert_equal i, Optimize::Codec::InstructionStream.u64_to_i64(u),
        "round-trip failed for i=#{i} via u=#{u}"
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd optimizer && bundle exec rake test TESTOPTS="--name=/test_u64_to_i64_boundaries|test_i64_to_u64_boundaries|test_round_trip_helpers_compose/"
```

Expected: NoMethodError / `undefined method 'u64_to_i64' for module Optimize::Codec::InstructionStream`.

- [ ] **Step 3: Add constants and helpers**

In `optimizer/lib/optimize/codec/instruction_stream.rb`, directly after the `module InstructionStream` line (line 10), insert:

```ruby
      # Sign conversion for :OFFSET operands. IBF's small_value primitive is
      # unsigned; only branch OFFSETs are semantically signed (backward
      # branches produce a negative relative slot offset). CRuby's
      # ibf_dump_small_value takes a VALUE (ulong), so a negative C long is
      # implicitly reinterpreted as (2^64 + n); we do that explicitly.
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

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd optimizer && bundle exec rake test TESTOPTS="--name=/test_u64_to_i64_boundaries|test_i64_to_u64_boundaries|test_round_trip_helpers_compose/"
```

Expected: 3 runs, 3 passes.

- [ ] **Step 5: Commit**

```bash
jj commit -m "feat(codec): add u64_to_i64 / i64_to_u64 helpers for signed OFFSET operands"
```

---

## Task 2: Decode signed OFFSET

**Files:**
- Modify: `optimizer/lib/optimize/codec/instruction_stream.rb:322-324` (the `:OFFSET` decode branch)
- Test: `optimizer/test/codec/round_trip_test.rb` (synthetic backward-branch decode test)

- [ ] **Step 1: Write the failing test**

Append to `RoundTripTest`:

```ruby
  def test_decode_backward_branch_in_while_loop
    # A minimal method with a while loop. The while body loops back via
    # branchif or branchunless with a NEGATIVE relative slot offset.
    src = "def loop_me(n); i = 0; while i < n; i += 1; end; i; end"
    original = RubyVM::InstructionSequence.compile(src).to_binary

    # Before the fix: this decode raises with
    #   "OFFSET raw=<huge> in branch* targets slot <huge> with no corresponding instruction"
    ir = Optimize::Codec.decode(original)
    refute_nil ir

    # Sanity: at least one branch instruction must point backward (target index
    # strictly less than the branch's own index).
    loop_me = ir.children.find { |f| f.name == "loop_me" }
    refute_nil loop_me
    insns = loop_me.instructions
    has_backward_branch = insns.each_with_index.any? do |insn, idx|
      %i[branchif branchunless branchnil jump].include?(insn.opcode) &&
        insn.operands[0].is_a?(Integer) && insn.operands[0] < idx
    end
    assert has_backward_branch, "expected at least one backward branch in while loop"
  end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd optimizer && bundle exec rake test TESTOPTS="--name=/test_decode_backward_branch_in_while_loop/"
```

Expected: RuntimeError, message matches `/OFFSET raw=.* targets slot .* with no corresponding instruction/`.

- [ ] **Step 3: Apply sign extension at the decode call site**

In `optimizer/lib/optimize/codec/instruction_stream.rb`, replace the `:OFFSET` decode branch (currently lines 322-324):

```ruby
            when :OFFSET
              offset_operand_positions << [insn_idx, op_idx]
              reader.read_small_value  # raw relative offset; converted below
```

with:

```ruby
            when :OFFSET
              offset_operand_positions << [insn_idx, op_idx]
              u64_to_i64(reader.read_small_value)  # sign-extend: backward branches encode as (2^64 + n)
```

The subsequent fixup loop at line 354 (`target_slot = next_insn_slot + raw_offset`) works unchanged because a negative `raw_offset` now yields an earlier `target_slot`.

- [ ] **Step 4: Run test to verify it passes**

```bash
cd optimizer && bundle exec rake test TESTOPTS="--name=/test_decode_backward_branch_in_while_loop/"
```

Expected: 1 run, 1 pass.

- [ ] **Step 5: Run the full codec test file to confirm no regressions**

```bash
cd optimizer && bundle exec rake test TESTOPTS="--name=/^RoundTripTest/"
```

Expected: all green. The existing identity/round-trip/object-table cases use only forward control flow, so none of them should change behavior.

- [ ] **Step 6: Commit**

```bash
jj commit -m "fix(codec): sign-extend :OFFSET operands on decode so backward branches round-trip"
```

---

## Task 3: Encode signed OFFSET

**Files:**
- Modify: `optimizer/lib/optimize/codec/instruction_stream.rb:411-418` (the `:OFFSET` encode branch)
- Test: `optimizer/test/codec/round_trip_test.rb` (synthetic backward-branch encode + byte-identity test)

- [ ] **Step 1: Write the failing test**

Append to `RoundTripTest`:

```ruby
  def test_encode_backward_branch_byte_identity
    # decode(encode(original)) must equal decode(original) AND
    # encode must not raise on a negative OFFSET operand.
    src = "def loop_me(n); i = 0; while i < n; i += 1; end; i; end"
    original = RubyVM::InstructionSequence.compile(src).to_binary

    ir = Optimize::Codec.decode(original)
    re_encoded = Optimize::Codec.encode(ir)
    assert_equal original, re_encoded,
      "round-trip byte mismatch for while-loop iseq"

    # And the re-encoded binary must load back into the VM.
    loaded = RubyVM::InstructionSequence.load_from_binary(re_encoded)
    assert_kind_of RubyVM::InstructionSequence, loaded
  end

  def test_encode_rejects_out_of_range_offset
    # Confirm encode surfaces out-of-range errors at the helper, not deep in
    # write_small_value with a misleading "must be non-negative" message.
    insns = [
      Optimize::IR::Instruction.new(opcode: :jump, operands: [0], line: nil),
    ]
    # We don't actually invoke encode directly on a hand-built iseq here (too
    # much scaffolding); instead exercise i64_to_u64 via a computed offset
    # wider than INT64_MAX. This is the same guard encode relies on.
    assert_raises(ArgumentError) do
      Optimize::Codec::InstructionStream.i64_to_u64((1 << 63))
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd optimizer && bundle exec rake test TESTOPTS="--name=/test_encode_backward_branch_byte_identity/"
```

Expected: `ArgumentError: small_value must be non-negative, got -<N>` raised from `write_small_value` via `encode`.

- [ ] **Step 3: Apply sign conversion at the encode call site**

In `optimizer/lib/optimize/codec/instruction_stream.rb`, replace the `:OFFSET` encode branch (currently lines 411-418):

```ruby
            when :OFFSET
              # Convert instruction index to YARV relative slot offset.
              # OFFSET_raw = target_slot - next_insn_slot
              target_insn_idx = insn.operands[operand_idx]
              target_slot = insn_to_slot[target_insn_idx]
              raise "OFFSET operand #{target_insn_idx} has no corresponding slot (out of range?)" unless target_slot
              writer.write_small_value(target_slot - next_insn_slot)
              operand_idx += 1
```

with:

```ruby
            when :OFFSET
              # Convert instruction index to YARV relative slot offset.
              # OFFSET_raw = target_slot - next_insn_slot, taken as a signed
              # i64 and re-interpreted as u64 (CRuby's implicit long<->VALUE
              # pun). Negative values always land in the 9-byte small_value form.
              target_insn_idx = insn.operands[operand_idx]
              target_slot = insn_to_slot[target_insn_idx]
              raise "OFFSET operand #{target_insn_idx} has no corresponding slot (out of range?)" unless target_slot
              writer.write_small_value(i64_to_u64(target_slot - next_insn_slot))
              operand_idx += 1
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd optimizer && bundle exec rake test TESTOPTS="--name=/test_encode_backward_branch_byte_identity|test_encode_rejects_out_of_range_offset/"
```

Expected: 2 runs, 2 passes.

- [ ] **Step 5: Run the full codec suite**

```bash
cd optimizer && bundle exec rake test TESTOPTS="--name=/Codec|RoundTrip/"
```

Expected: all green. Every existing test uses forward-only control flow; results must be unchanged.

- [ ] **Step 6: Commit**

```bash
jj commit -m "fix(codec): encode :OFFSET as signed i64 so backward branches re-emit as CRuby does"
```

---

## Task 4: End-to-end `while`-loop VM-execution round-trip

**Files:**
- Test: `optimizer/test/codec/round_trip_test.rb` (executable round-trip test with asserted return value)

This is the integration guard: it proves decode+encode preserve runtime semantics for loops, not just bytecode bit-identity.

- [ ] **Step 1: Write the failing test (then verify it passes immediately)**

`while` is now supported after Tasks 2 and 3, so this test should go green on first run. It still belongs in the suite as a permanent regression guard — if anyone ever breaks signed OFFSET handling, the VM-level eval assertion catches it even if byte-identity happens to coincide.

Append to `RoundTripTest`:

```ruby
  def test_while_loop_executes_after_round_trip
    src = <<~RUBY
      def sum_to(n)
        s = 0
        i = 1
        while i <= n
          s += i
          i += 1
        end
        s
      end
      sum_to(10)
    RUBY
    original = RubyVM::InstructionSequence.compile(src).to_binary

    ir = Optimize::Codec.decode(original)
    re_encoded = Optimize::Codec.encode(ir)

    loaded = RubyVM::InstructionSequence.load_from_binary(re_encoded)
    assert_equal 55, loaded.eval, "round-tripped while loop must still compute 1+2+...+10"
  end
```

- [ ] **Step 2: Run test to verify it passes**

```bash
cd optimizer && bundle exec rake test TESTOPTS="--name=/test_while_loop_executes_after_round_trip/"
```

Expected: 1 run, 1 pass. If it fails, stop and debug — Task 2 or 3 has a latent bug.

- [ ] **Step 3: Run the full optimizer test suite**

```bash
cd optimizer && bundle exec rake test
```

Expected: all green.

- [ ] **Step 4: Commit**

```bash
jj commit -m "test(codec): VM-execution round-trip for while loops (regression guard)"
```

---

## Task 5: Restore `sum_of_squares.rb` fixture

**Files:**
- Create: `optimizer/examples/sum_of_squares.rb`

- [ ] **Step 1: Recover the file from the pre-revert commit**

Check out the file from the original feature commit (`ed3bc5dd`):

```bash
jj file show -r ed3bc5dd optimizer/examples/sum_of_squares.rb > optimizer/examples/sum_of_squares.rb
```

Verify contents:

```bash
cat optimizer/examples/sum_of_squares.rb
```

Expected output:

```ruby
# frozen_string_literal: true

# @rbs (Integer) -> Integer
def sum_of_squares(n)
  s = 0
  i = 1
  while i <= n
    s += i * i
    i += 1
  end
  s
end
```

- [ ] **Step 2: Sanity-check it parses and runs under our MCP sandbox**

Use the `mcp__ruby-bytecode__run_ruby` tool with:

```ruby
load "optimizer/examples/sum_of_squares.rb"
p sum_of_squares(5)  # => 55
p sum_of_squares(10) # => 385
```

Expected: `55\n385`.

- [ ] **Step 3: Confirm the iseq decodes cleanly**

Use `mcp__ruby-bytecode__iseq_to_binary` on the file, then verify `Optimize::Codec.decode` does not raise. Can be done with a throwaway script or interactively — no commit needed for this step.

- [ ] **Step 4: Commit**

```bash
jj commit -m "feat(examples): restore sum_of_squares fixture (unblocked by codec signed OFFSET fix)"
```

---

## Task 6: Add `sum_of_squares` walkthrough sidecar

**Files:**
- Create: `optimizer/examples/sum_of_squares.walkthrough.yml`

- [ ] **Step 1: Write the sidecar**

Create `optimizer/examples/sum_of_squares.walkthrough.yml`:

```yaml
fixture: sum_of_squares.rb
entry_setup: ""
entry_call: sum_of_squares(100)
walkthrough:
  - inlining
  - const_fold_tier2
  - const_fold
  - identity_elim
  - arith_reassoc
  - dead_branch_fold
# NOTE: most passes will show "(no change)" on this fixture today. No
# shipped pass reasons about loops — DeadBranchFoldPass's window is
# <literal>;branch*, not <comparison>;branchunless <backward>. The
# fixture's role here is (a) prove codec correctness on a real `while`,
# (b) surface the loop shape in the demo pipeline so future loop-aware
# passes have a canonical place to land.
```

The `walkthrough:` list is the same set of passes the `polynomial` sidecar runs plus `arith_reassoc` — no pass is loop-aware, so order does not affect the payoff; we just want full coverage of the shipped slate.

- [ ] **Step 2: Dry-run the runner to confirm the YAML parses and the fixture compiles**

```bash
cd optimizer && bundle exec bin/demo sum_of_squares
```

Expected: writes `docs/demo_artifacts/sum_of_squares.md` without raising. The output markdown is staged for Task 7.

- [ ] **Step 3: Commit the sidecar (not the generated artifact yet)**

```bash
jj commit -m "feat(examples): sum_of_squares walkthrough sidecar"
```

(The generated `docs/demo_artifacts/sum_of_squares.md` is committed separately in Task 7 so the demo-artifact change stays in a self-contained commit.)

---

## Task 7: Generate and commit `sum_of_squares` demo artifact

**Files:**
- Create: `docs/demo_artifacts/sum_of_squares.md`

- [ ] **Step 1: Regenerate the artifact**

```bash
cd optimizer && bundle exec bin/demo sum_of_squares
```

Expected: `wrote <repo-root>/docs/demo_artifacts/sum_of_squares.md`.

- [ ] **Step 2: Inspect the output**

```bash
head -80 docs/demo_artifacts/sum_of_squares.md
```

Expected: header with fixture name, at least one disasm section, a benchmark section. Most pass diffs should be `(no change)` — that is the expected honest output.

- [ ] **Step 3: Verify `rake demo:verify` accepts the current state**

```bash
cd optimizer && bundle exec rake demo:verify
```

Expected: `demo:verify OK (3 fixtures)` (point_distance, polynomial, sum_of_squares).

- [ ] **Step 4: Commit**

```bash
jj commit -m "docs(demo): regenerate artifacts — sum_of_squares now decodes (while-loop codec fix)"
```

---

## Task 8: Update `docs/todo.md`

**Files:**
- Modify: `docs/todo.md` — two "Known bugs / blockers" entries + Roadmap gap #2 bullet

- [ ] **Step 1: Strike the decode entry under "Known bugs / blockers"**

In `docs/todo.md`, find the entry starting `**Codec fails to decode backward branches (`while` loops).**` (around line 185). Replace the entire bullet with:

```markdown
- ~~**Codec fails to decode backward branches (`while` loops).**
  `codec/instruction_stream.rb:360` interprets a negative branch
  offset as a huge unsigned integer and aborts.~~
  **Shipped 2026-04-23** via `u64_to_i64` sign-extension at the
  `:OFFSET` decode site. Plan:
  `docs/superpowers/plans/2026-04-23-codec-signed-offset-and-while-fixture.md`.
```

- [ ] **Step 2: Strike the encode entry**

Find the entry starting `**Codec encode side of backward branches is unverified.**` (around line 192). Replace with:

```markdown
- ~~**Codec encode side of backward branches is unverified.**~~
  **Shipped 2026-04-23** via `i64_to_u64` at the `:OFFSET` encode
  site + byte-identity + VM-execution round-trip tests in
  `optimizer/test/codec/round_trip_test.rb`. See same plan as above.
```

- [ ] **Step 3: Mark the `sum_of_squares` follow-up as shipped**

In "Roadmap gap #2" (around line 57), find the sub-bullet starting `**`sum_of_squares` fixture blocked.**` and replace with:

```markdown
- ~~**`sum_of_squares` fixture blocked** on codec backward-branch
  decode.~~ **Shipped 2026-04-23.** Fixture restored at
  `optimizer/examples/sum_of_squares.{rb,walkthrough.yml}`;
  `docs/demo_artifacts/sum_of_squares.md` regenerated; `rake
  demo:verify` covers it. Most passes are `(no change)` — no shipped
  pass is loop-aware, see the "Loop-aware passes" entry under
  "Exploratory, not yet on any roadmap" for what it would take to
  change that.
```

- [ ] **Step 4: Update the top-of-file `Last updated:` stamp**

Change line 7 from `Last updated: 2026-04-22 …` to:

```markdown
Last updated: 2026-04-23 (codec signed OFFSET + sum_of_squares fixture).
```

- [ ] **Step 5: Commit**

```bash
jj commit -m "docs(todo): strike codec backward-branch blockers + sum_of_squares follow-up"
```

---

## Final verification

- [ ] **Step 1: Run the full test suite one more time**

```bash
cd optimizer && bundle exec rake test
```

Expected: all green.

- [ ] **Step 2: Run `rake demo:verify`**

```bash
cd optimizer && bundle exec rake demo:verify
```

Expected: `demo:verify OK (3 fixtures)`.

- [ ] **Step 3: Confirm the log is linear and descriptive**

```bash
jj log -r '::@ & ~::trunk()' --no-pager
```

Expected: eight commits in order — helpers, decode, encode, VM-execution test, fixture restore, sidecar, artifact, todo update.
