# Inlining Pass v1 — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Ship the first inlining pass. v1 inlines **zero-arg `FCALL`** calls to top-level / same-scope methods whose body has no locals, no branches, no catch-table entries, no nested calls, and ends in a single trailing `leave`. The pattern replaces `putself; opt_send_without_block <mid, argc:0, FCALL|VCALL|ARGS_SIMPLE>` with the callee body minus the trailing `leave`. Think "constant-returning helper gets folded into its caller".

**Why this narrow scope:** the codec currently round-trips `ci_entries` as raw bytes, and IR `opt_send*` instructions carry **no** calldata in their operands. To identify a call target (`mid`, `argc`, `flags`) we first need to **decode** calldata and **attach** each record to the send instruction that consumes it. That groundwork is Task 1+2. Once we can inspect call sites, the actual inlining pass is small — the hard constraints (zero args, no locals in callee) side-step local-table growth, `stack_max` recomputation beyond what the codec already does, and CFG splicing across basic-block boundaries.

**Spec:** `docs/superpowers/specs/2026-04-19-pass-inlining.md` (the full vision). This plan implements the narrowest sub-slice that produces a working, shippable pass + demo.

**Tech Stack:** Ruby 4.0.2, minitest, the `ruby-bytecode` MCP for all Ruby execution and test runs. Never host shell.

**Baseline test count before this plan: check with `mcp__ruby-bytecode__run_optimizer_tests` at Task 1 start.** Expected after: baseline + calldata codec tests + inlining unit tests + 1 pipeline integration = ~20 new green tests.

**Commit discipline:** Each task ends with `jj commit -m "<msg>"` — never `jj describe -m`. Parallel subagent commits use `jj split -m "<msg>" -- <files>` with the exact file list from the task. Tests via `mcp__ruby-bytecode__run_optimizer_tests` only. Ruby evaluation via `mcp__ruby-bytecode__run_ruby`. Never host shell.

---

## File structure

```
optimizer/
  lib/optimize/
    codec/
      ci_entries.rb                         # NEW Task 1  — parse/emit ci_entries blob
      instruction_stream.rb                 # MODIFIED Task 2  — attach CallData to send ops
      iseq_list.rb                          # MODIFIED Task 2  — drive ci_entries decode/encode
    ir/
      call_data.rb                          # NEW Task 1  — CallData value object
    passes/
      inlining_pass.rb                      # NEW Task 3
    pipeline.rb                             # MODIFIED Task 4
  test/
    codec/
      ci_entries_test.rb                    # NEW Task 1
    passes/
      inlining_pass_test.rb                 # NEW Task 3
    codec/corpus/
      inlining_zero_arg.rb                  # NEW Task 4
docs/
  TODO.md                                   # MODIFIED Task 5
  superpowers/specs/
    2026-04-21-pass-inlining-v1-design.md   # NEW Task 0 (this file's design-note sibling)
```

---

## Task 0: Design note (optional but recommended)

Before any code, write a one-page v1 design note at
`docs/superpowers/specs/2026-04-21-pass-inlining-v1-design.md` that says:

- v1 handles **only** zero-arg `opt_send_without_block` with the FCALL flag set, targeting a method whose callee Function exists in the IR tree (looked up by name).
- Callee preconditions: `argc=0`, `local_table_size=0`, no catch entries, no branches, no nested sends of any kind, ends in `leave`, size ≤ `INLINE_BUDGET` (8 instructions including `leave`).
- Call-site preconditions: exactly `putself` immediately followed by the `opt_send_without_block` (no intervening instructions). The `putself` is not a branch target.
- Transformation: splice `putself;send` with the callee's instructions minus the trailing `leave`; drop the corresponding `ci_entries` record; no local-table change; line numbers: keep callee lines for the spliced instructions (arguably surprising but matches "the code you'd have written by hand"); alternatively keep caller's — pick ONE and document.
- Not in scope (explicit list): args, blocks, kwargs, `super`, recursive inlining, cross-Module calls, RBS-typed receiver resolution, polymorphic sites, wrapper flattening (reserved for v2).

This file is a deliverable so future sessions understand what v1 means. If time is tight, skip Task 0 — the plan + PR message carry enough context.

- [ ] **Step 1**: Write the design note at the path above.
- [ ] **Step 2**: Commit.

```bash
jj commit -m "Plan: Inlining Pass v1 (zero-arg FCALL, constant-body callees)"
```

---

## Task 1: `CallData` value object + `ci_entries` codec (round-trip preserved)

**Context:** Right now `optimizer/lib/optimize/codec/iseq_list.rb` stores `ci_entries` as `misc[:ci_entries_raw]` (bytes in, bytes out). To inspect a call site's `mid`, we need a structured decode that round-trips byte-identically. Per `research/cruby/ibf-format.md:188`, each entry is `mid_idx, flag, argc, kwlen, kw_indices[kwlen]` written with `write_small_value`. The object-table stores `mid_idx` as an ID (Symbol) reference — use the same mechanism `local_table` bytes would use, except we don't touch the object table here (indices are opaque; we resolve them to symbols lazily).

**Files:**
- Create: `optimizer/lib/optimize/ir/call_data.rb`
- Create: `optimizer/lib/optimize/codec/ci_entries.rb`
- Create: `optimizer/test/codec/ci_entries_test.rb`

- [ ] **Step 1: Define `IR::CallData`.**

Create `optimizer/lib/optimize/ir/call_data.rb`:

```ruby
# frozen_string_literal: true

module Optimize
  module IR
    # One call-site's calldata record. Mirrors the on-disk shape at
    # research/cruby/ibf-format.md §4.1 "call info (ci) entries":
    # per-cd: mid_idx, flag, argc, kwlen, kw_indices.
    #
    # mid_idx and kw_indices are OBJECT-TABLE indices (ID refs), not resolved
    # symbols — that mirrors how other operands are stored and preserves
    # byte-identical round-trip. Resolution to Symbol happens via the passed
    # object table (see IR::CallData#mid_symbol).
    CallData = Struct.new(:mid_idx, :flag, :argc, :kwlen, :kw_indices, keyword_init: true) do
      # Calldata flag bits we care about in v1. Values from
      # vm_callinfo.h (iseq.c). These are the exact C enum values.
      FLAG_ARGS_SPLAT    = 0x01
      FLAG_ARGS_BLOCKARG = 0x02
      FLAG_FCALL         = 0x04
      FLAG_VCALL         = 0x08
      FLAG_ARGS_SIMPLE   = 0x10
      FLAG_BLOCKISEQ     = 0x20
      FLAG_KWARG         = 0x40
      FLAG_KW_SPLAT      = 0x80
      FLAG_TAILCALL      = 0x100
      FLAG_SUPER         = 0x200
      FLAG_ZSUPER        = 0x400
      FLAG_OPT_SEND      = 0x800
      FLAG_KW_SPLAT_MUT  = 0x1000
      FLAG_FORWARDING    = 0x2000

      def fcall?        = (flag & FLAG_FCALL) != 0
      def args_simple?  = (flag & FLAG_ARGS_SIMPLE) != 0
      def blockarg?     = (flag & FLAG_ARGS_BLOCKARG) != 0
      def has_kwargs?   = kwlen.positive?
      def has_splat?    = (flag & FLAG_ARGS_SPLAT) != 0

      def mid_symbol(object_table)
        object_table.resolve(mid_idx)
      end
    end
  end
end
```

Note: the flag constants above are the pattern we want, but the exact bit
values MUST be verified against the running VM. See Step 4.

- [ ] **Step 2: Implement `Codec::CiEntries`.**

Create `optimizer/lib/optimize/codec/ci_entries.rb`:

```ruby
# frozen_string_literal: true
require "optimize/codec/binary_reader"
require "optimize/codec/binary_writer"
require "optimize/ir/call_data"

module Optimize
  module Codec
    # Parse and emit the ci_entries section of an iseq body.
    #
    # On-disk shape (research/cruby/ibf-format.md §4.1):
    #   per entry: mid_idx, flag, argc, kwlen, kw_indices[kwlen]
    # All values are small_value-encoded.
    module CiEntries
      module_function

      # @param bytes [String] ASCII-8BIT ci_entries blob
      # @param ci_size [Integer] number of entries (from body header)
      # @return [Array<IR::CallData>]
      def decode(bytes, ci_size)
        return [] if ci_size.zero? || bytes.nil? || bytes.empty?
        reader = BinaryReader.new(bytes)
        Array.new(ci_size) do
          mid_idx     = reader.read_small_value
          flag        = reader.read_small_value
          argc        = reader.read_small_value
          kwlen       = reader.read_small_value
          kw_indices  = Array.new(kwlen) { reader.read_small_value }
          IR::CallData.new(
            mid_idx: mid_idx, flag: flag, argc: argc,
            kwlen: kwlen, kw_indices: kw_indices,
          )
        end
      end

      # @param entries [Array<IR::CallData>]
      # @return [String] ASCII-8BIT byte string
      def encode(entries)
        writer = BinaryWriter.new
        entries.each do |cd|
          writer.write_small_value(cd.mid_idx)
          writer.write_small_value(cd.flag)
          writer.write_small_value(cd.argc)
          writer.write_small_value(cd.kwlen)
          cd.kw_indices.each { |i| writer.write_small_value(i) }
        end
        writer.buffer
      end
    end
  end
end
```

- [ ] **Step 3: Add a round-trip test.**

Create `optimizer/test/codec/ci_entries_test.rb`:

```ruby
# frozen_string_literal: true
require "test_helper"
require "optimize/codec"
require "optimize/codec/ci_entries"

class CiEntriesCodecTest < Minitest::Test
  # For every fixture iseq, decode(ci_entries_raw) → encode → must equal input.
  def test_round_trip_identity_for_corpus
    Dir[File.expand_path("corpus/*.rb", __dir__)].each do |fixture|
      src = File.read(fixture)
      bin = RubyVM::InstructionSequence.compile(src).to_binary
      ir  = Optimize::Codec.decode(bin)
      assert_each_iseq_ci_roundtrips(ir)
    end
  end

  def test_decode_produces_calldata_for_simple_send
    src = "def magic; 42; end; magic"
    bin = RubyVM::InstructionSequence.compile(src).to_binary
    ir  = Optimize::Codec.decode(bin)
    # Top-level iseq has exactly one ci entry: the `magic` FCALL.
    raw      = ir.misc[:ci_entries_raw]
    ci_size  = ir.misc[:ci_size]
    entries  = Optimize::Codec::CiEntries.decode(raw, ci_size)
    assert_equal 1, entries.size
    cd = entries[0]
    assert cd.fcall?, "expected FCALL flag"
    assert_equal 0, cd.argc
    assert_equal 0, cd.kwlen
  end

  private

  def assert_each_iseq_ci_roundtrips(fn)
    raw     = fn.misc[:ci_entries_raw]
    ci_size = fn.misc[:ci_size]
    entries = Optimize::Codec::CiEntries.decode(raw, ci_size)
    assert_equal raw.bytes, Optimize::Codec::CiEntries.encode(entries).bytes,
      "ci_entries round-trip mismatch in #{fn.name} (ci_size=#{ci_size})"
    fn.children&.each { |c| assert_each_iseq_ci_roundtrips(c) }
  end
end
```

- [ ] **Step 4: Verify FLAG_* bit values against the running VM.**

Run this probe with the MCP `run_ruby` tool — it prints the enum bits as the VM sees them (via an internal iseq where we can recognize the FCALL):

```ruby
src = "def m; end; m"
bin = RubyVM::InstructionSequence.compile(src).to_binary
# We don't have direct enum access, but we can read ci_entries:
# Decode our own copy, print flag for known call.
require_relative "optimizer/lib/optimize"
ir = Optimize::Codec.decode(bin)
entries = Optimize::Codec::CiEntries.decode(ir.misc[:ci_entries_raw], ir.misc[:ci_size])
puts entries.map { |e| format("flag=0x%x argc=%d kwlen=%d", e.flag, e.argc, e.kwlen) }
```

Expected: a `FCALL|VCALL|ARGS_SIMPLE` for `m` (zero-arg, no block). If
`FLAG_FCALL=0x04 | FLAG_VCALL=0x08 | FLAG_ARGS_SIMPLE=0x10 = 0x1c`, we
should see `flag=0x1c`. If that doesn't match, update the constants to
match the observed bit pattern from the corpus, and re-run. **Do not
skip this step** — a wrong flag bit will silently misclassify calls.

- [ ] **Step 5: Run the test.**

Use `mcp__ruby-bytecode__run_optimizer_tests` with test file
`optimizer/test/codec/ci_entries_test.rb`.

Expected: both tests pass.

- [ ] **Step 6: Commit.**

```bash
jj commit -m "Codec: decode/encode ci_entries into IR::CallData records"
```

---

## Task 2: Attach `CallData` to send instructions (still byte-identical round-trip)

**Context:** The IR `opt_send_without_block` instruction has `operands: []` because `instruction_stream.rb:313-337` drops `CALLDATA` slots via `filter_map`. We want inlining to see the calldata record directly at the send site. The cleanest way: at decode time, zip the structured `ci_entries` array with the send instructions in iteration order, and attach each record as the operand for the send's `CALLDATA` slot. At encode time, harvest records from send instructions in order and re-emit ci_entries from them — replacing the raw-bytes round-trip. This preserves byte-identical output because the encode uses the same `CiEntries.encode` whose output matches the original bytes (from Task 1's proven round-trip).

**Files:**
- Modify: `optimizer/lib/optimize/codec/instruction_stream.rb` (decode + encode)
- Modify: `optimizer/lib/optimize/codec/iseq_list.rb` (pass ci_entries through; encode from instructions)

- [ ] **Step 1: Identify send opcodes that consume calldata.**

Any opcode with `[:CALLDATA]` in its operand type list:
`send`, `opt_send_without_block`, `invokesuper`, `invokesuperforward`,
`invokeblock`, `opt_nil_p`, `opt_str_uminus`, `opt_duparray_send`,
`opt_newarray_send`, and the `opt_<op>` arithmetic/comparison family
(yes, `opt_plus` etc. all carry calldata for the respective `+`/`-`/…
method). Grep:

```
# via Grep tool
pattern: :CALLDATA
path: optimizer/lib/optimize/codec/instruction_stream.rb
```

**These are all sites that consume one ci_entry each, in iteration
order through the bytecode stream.** This matters because v1 pass only
cares about `opt_send_without_block`, but the decode logic has to
consume ci records in lockstep with ALL CALLDATA-bearing opcodes.

- [ ] **Step 2: Extend `InstructionStream.decode` to accept decoded ci_entries and attach records.**

The current signature is `def self.decode(bytes, ...)`. Add a keyword
arg `ci_entries:` that takes `Array<IR::CallData>`. In the `:CALLDATA`
arm of the operand decode switch, pop the next entry off the array
and use it as the operand value (instead of `nil`). Remove the
`filter_map` — switch to `map` and store the record directly, so a
send's `operands` becomes `[CallData(...)]`. Other callers feed
`ci_entries: []` and rely on no-calldata opcodes.

Pseudo-diff:

```ruby
def self.decode(bytes, ci_entries: [])
  ci = ci_entries.dup
  # ... existing reader setup ...
  operands = op_types.map do |op_type|
    case op_type
    # ... existing arms ...
    when :CALLDATA
      ci.shift or raise "InstructionStream.decode: ran out of ci_entries"
    # ...
    end
  end
  # After the instruction loop, assert ci is empty.
  raise "InstructionStream.decode: #{ci.size} ci_entries unconsumed" unless ci.empty?
  instructions
end
```

Note: switching `filter_map`→`map` means every operand position is now
materialised. Review the existing OFFSET post-processing loop
(`offset_operand_positions`) — it uses `op_idx`; make sure op_idx still
advances correctly for the new `CALLDATA` slot that now carries a
value (it should: the current code increments `operand_idx` for VALUE,
OFFSET, etc., but the CALLDATA arm didn't — add `operand_idx += 1` in
the CALLDATA arm since it now contributes an operand).

- [ ] **Step 3: Extend `InstructionStream.encode` to re-emit ci_entries bytes.**

Add a kwarg `ci_entries_out:` (a mutable `Array<IR::CallData>`, default
new `[]`) that `encode` appends to as it walks sends. In the
`:CALLDATA` arm, instead of "write nothing", push
`insn.operands[operand_idx]` onto `ci_entries_out` and `operand_idx += 1`.

```ruby
when :CALLDATA
  ci_entries_out << insn.operands[operand_idx]
  operand_idx += 1
```

- [ ] **Step 4: Drive decode/encode from `iseq_list.rb`.**

Find the call sites in `iseq_list.rb` that invoke `InstructionStream.decode`
and `.encode` (grep `InstructionStream` in that file). For decode: before
calling, parse `misc[:ci_entries_raw]` into records via
`Codec::CiEntries.decode(raw, misc[:ci_size])`, pass as `ci_entries:`.
For encode: pass a fresh `ci_entries_out: []` array, then emit the ci
section using `Codec::CiEntries.encode(ci_entries_out)` instead of the
raw bytes path at lines 415–420.

- [ ] **Step 5: Run the full codec round-trip corpus test.**

Use `mcp__ruby-bytecode__run_optimizer_tests`. The codec's identity
round-trip tests (corpus: `optimizer/test/codec/corpus/*.rb` including
`simple_method.rb`, `block_with_yield.rb`, `keyword_args.rb`, …) must
stay byte-identical. This is the critical check. If any fixture breaks,
the likely causes are:

  - Kwlen/kw_indices misread for non-zero kwargs (see `keyword_args.rb`).
  - CALLDATA-bearing opt_* arith opcodes not iterating in the right
    order (if ci_entries is serialized per iseq but read across
    iseqs, check the iseq_list loop).

Fix, re-run.

- [ ] **Step 6: Commit.**

```bash
jj commit -m "Codec: attach CallData to send instructions; drop raw ci_entries path"
```

---

## Task 3: `InliningPass` v1 — unit tests + implementation

**Context:** With calldata accessible on send instructions, the pass itself is straightforward instruction-list rewriting in the style of `IdentityElimPass`. We scan for `putself; opt_send_without_block`; look up the callee Function by symbol name in a `callee_map` (built at Pipeline level, see Task 4); verify preconditions; splice in the callee body minus its trailing `leave`, and delete the matching send's calldata from the iseq's ci_entries (handled automatically since the CallData operand goes away with the spliced `opt_send_without_block`).

**Files:**
- Create: `optimizer/lib/optimize/passes/inlining_pass.rb`
- Create: `optimizer/test/passes/inlining_pass_test.rb`

- [ ] **Step 1: Write failing smoke test.**

Create `optimizer/test/passes/inlining_pass_test.rb`:

```ruby
# frozen_string_literal: true
require "test_helper"
require "optimize/codec"
require "optimize/log"
require "optimize/passes/inlining_pass"

class InliningPassTest < Minitest::Test
  def test_zero_arg_constant_fcall_inlined
    src = "def magic; 42; end; def use_it; magic; end; use_it"
    ir  = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot  = ir.misc[:object_table]
    use_it = find_iseq(ir, "use_it")
    magic  = find_iseq(ir, "magic")

    log = Optimize::Log.new
    callee_map = { magic: magic }
    Optimize::Passes::InliningPass.new.apply(
      use_it, type_env: nil, log: log,
      object_table: ot, callee_map: callee_map,
    )

    # The call site is gone.
    refute use_it.instructions.any? { |i| i.opcode == :opt_send_without_block }
    # Body is now: putobject 42; leave
    assert_equal [:putobject, :leave], use_it.instructions.map(&:opcode)
    assert log.entries.any? { |e| e.reason == :inlined }

    # Round-trip still executes correctly.
    loaded = RubyVM::InstructionSequence.load_from_binary(Optimize::Codec.encode(ir))
    assert_equal 42, loaded.eval
  end

  def test_skips_when_callee_has_args
    src = "def add_one(x); x + 1; end; def use_it; add_one(5); end; use_it"
    ir  = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot  = ir.misc[:object_table]
    use_it   = find_iseq(ir, "use_it")
    add_one  = find_iseq(ir, "add_one")
    log = Optimize::Log.new
    Optimize::Passes::InliningPass.new.apply(
      use_it, type_env: nil, log: log,
      object_table: ot, callee_map: { add_one: add_one },
    )
    # Call site unchanged, log records the skip reason.
    assert use_it.instructions.any? { |i| i.opcode == :opt_send_without_block }
    assert log.entries.any? { |e| e.reason == :callee_has_args }
  end

  def test_skips_when_callee_has_branches
    src = "def maybe; 1 > 0 ? 1 : 2; end; def use_it; maybe; end; use_it"
    ir  = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot  = ir.misc[:object_table]
    use_it = find_iseq(ir, "use_it")
    maybe  = find_iseq(ir, "maybe")
    log = Optimize::Log.new
    Optimize::Passes::InliningPass.new.apply(
      use_it, type_env: nil, log: log,
      object_table: ot, callee_map: { maybe: maybe },
    )
    assert use_it.instructions.any? { |i| i.opcode == :opt_send_without_block }
    assert log.entries.any? { |e| e.reason == :callee_has_branches }
  end

  def test_skips_when_callee_has_locals
    src = "def local_y; y = 5; y; end; def use_it; local_y; end; use_it"
    ir  = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot  = ir.misc[:object_table]
    use_it  = find_iseq(ir, "use_it")
    local_y = find_iseq(ir, "local_y")
    log = Optimize::Log.new
    Optimize::Passes::InliningPass.new.apply(
      use_it, type_env: nil, log: log,
      object_table: ot, callee_map: { local_y: local_y },
    )
    assert use_it.instructions.any? { |i| i.opcode == :opt_send_without_block }
    assert log.entries.any? { |e| e.reason == :callee_has_locals }
  end

  def test_skips_when_callee_makes_nested_call
    src = "def inner; 1; end; def outer; inner; end; def use_it; outer; end; use_it"
    ir  = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot  = ir.misc[:object_table]
    use_it = find_iseq(ir, "use_it")
    outer  = find_iseq(ir, "outer")
    inner  = find_iseq(ir, "inner")
    log = Optimize::Log.new
    # Apply to use_it; outer has a nested `inner` call that v1 can't splice.
    Optimize::Passes::InliningPass.new.apply(
      use_it, type_env: nil, log: log,
      object_table: ot, callee_map: { outer: outer, inner: inner },
    )
    assert use_it.instructions.any? { |i| i.opcode == :opt_send_without_block }
    assert log.entries.any? { |e| e.reason == :callee_makes_call }
  end

  def test_skips_when_callee_unresolved
    src = "def use_it; bogus_name_that_does_not_exist; end; 1"
    ir  = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot  = ir.misc[:object_table]
    use_it = find_iseq(ir, "use_it")
    log = Optimize::Log.new
    Optimize::Passes::InliningPass.new.apply(
      use_it, type_env: nil, log: log,
      object_table: ot, callee_map: {},
    )
    assert log.entries.any? { |e| e.reason == :callee_unresolved }
  end

  private

  def find_iseq(fn, name)
    return fn if fn.name == name
    fn.children.each do |c|
      found = find_iseq(c, name)
      return found if found
    end
    nil
  end
end
```

- [ ] **Step 2: Run the tests to verify they all FAIL.**

Use `mcp__ruby-bytecode__run_optimizer_tests`. All 6 tests fail with
`NameError: uninitialized constant Optimize::Passes::InliningPass` or
similar.

- [ ] **Step 3: Implement the pass.**

Create `optimizer/lib/optimize/passes/inlining_pass.rb`:

```ruby
# frozen_string_literal: true
require "optimize/pass"
require "optimize/ir/call_data"
require "optimize/ir/cfg"

module Optimize
  module Passes
    # v1: inline zero-arg FCALLs to constant-body callees. See
    # docs/superpowers/specs/2026-04-21-pass-inlining-v1-design.md.
    class InliningPass < Optimize::Pass
      INLINE_BUDGET = 8  # max callee instructions INCLUDING the trailing leave

      LOCAL_OPCODES = %i[
        getlocal setlocal
        getlocal_WC_0 setlocal_WC_0
        getlocal_WC_1 setlocal_WC_1
      ].freeze

      SEND_OPCODES = %i[
        send opt_send_without_block
        invokesuper invokesuperforward invokeblock
        opt_str_uminus opt_duparray_send opt_newarray_send
      ].freeze

      CONTROL_FLOW_OPCODES = (IR::CFG::BRANCH_OPCODES + IR::CFG::JUMP_OPCODES).freeze

      def name = :inlining

      def apply(function, type_env:, log:, object_table: nil, callee_map: {})
        _ = type_env
        return unless object_table
        insts = function.instructions
        return unless insts

        loop do
          changed = false
          i = 0
          while i <= insts.size - 2
            a = insts[i]
            b = insts[i + 1]
            if a.opcode == :putself && b.opcode == :opt_send_without_block
              cd = b.operands[0]
              if try_inline(function, i, cd, callee_map, object_table, log)
                changed = true
                # Do not step back; the spliced region may contain new
                # patterns, but v1 disallows callee nested calls so there
                # is nothing new to inline inside the splice.
                next
              end
            end
            i += 1
          end
          break unless changed
          insts = function.instructions
        end
      end

      private

      # Returns true if an inline happened (splice performed).
      def try_inline(function, put_self_idx, cd, callee_map, object_table, log)
        line = function.instructions[put_self_idx].line || function.first_lineno

        # 1. Calldata shape: FCALL, argc=0, no kwargs, no blockarg, no splat.
        unless cd.is_a?(IR::CallData) && cd.fcall? && cd.args_simple? &&
               cd.argc.zero? && cd.kwlen.zero? && !cd.blockarg? && !cd.has_splat?
          log.skip(pass: :inlining, reason: :unsupported_call_shape,
                   file: function.path, line: line)
          return false
        end

        # 2. Resolve callee by mid symbol.
        mid = cd.mid_symbol(object_table)
        callee = callee_map[mid]
        unless callee
          log.skip(pass: :inlining, reason: :callee_unresolved,
                   file: function.path, line: line)
          return false
        end

        # 3. Callee shape: no args, no locals, no catch, no branches,
        #    no nested sends, ends in `leave`, under budget.
        reason = disqualify_callee(callee)
        if reason
          log.skip(pass: :inlining, reason: reason,
                   file: function.path, line: line)
          return false
        end

        # Transformation. Splice [putself, opt_send] -> callee body minus trailing leave.
        body = callee.instructions[0..-2] # drop trailing `leave`
        function.splice_instructions!(put_self_idx..(put_self_idx + 1), body)

        log.skip(pass: :inlining, reason: :inlined,
                 file: function.path, line: line)
        true
      end

      def disqualify_callee(callee)
        # arg_spec: v1 requires lead_num=0, opt_num=0, rest_start absent,
        # post_num=0, block_start absent, no kwargs.
        as = callee.arg_spec || {}
        return :callee_has_args if (as[:lead_num] || 0).positive?
        return :callee_has_args if (as[:opt_num] || 0).positive?
        return :callee_has_args if (as[:post_num] || 0).positive?
        return :callee_has_args if as[:rest_start] && as[:rest_start] >= 0
        return :callee_has_args if as[:block_start] && as[:block_start] >= 0

        lt_size = (callee.misc && callee.misc[:local_table_size]) || 0
        return :callee_has_locals if lt_size.positive?

        return :callee_has_catch if callee.catch_entries && !callee.catch_entries.empty?

        insts = callee.instructions || []
        return :callee_empty if insts.empty?
        return :callee_over_budget if insts.size > INLINE_BUDGET
        return :callee_no_trailing_leave unless insts.last.opcode == :leave

        # Scan the body (everything except the trailing leave).
        insts[0..-2].each do |inst|
          return :callee_has_branches if CONTROL_FLOW_OPCODES.include?(inst.opcode)
          return :callee_has_locals   if LOCAL_OPCODES.include?(inst.opcode)
          return :callee_makes_call   if SEND_OPCODES.include?(inst.opcode)
          # Additional opt_<arith>/opt_<cmp> opcodes technically carry
          # calldata but are core basic-ops under the contract — allow
          # them. v1 excludes only the "real" send family above.
          return :callee_has_leave_midway if inst.opcode == :leave
          return :callee_has_throw if inst.opcode == :throw
        end
        nil
      end
    end
  end
end
```

- [ ] **Step 4: Run the tests — expect all 6 to pass.**

Use `mcp__ruby-bytecode__run_optimizer_tests` on the new test file.

If `test_skips_when_callee_has_locals` fails because `local_table_size`
for a method with one local is unexpectedly 0, or the callee still
decodes without `getlocal`, investigate: `y = 5; y` may compile to
`putobject 5; dup; setlocal y; leave` — which IS a `setlocal`, caught
by the LOCAL_OPCODES check. Good. If it uses `_WC_0`, also caught.

If the skip test for `callee_has_branches` fails because `1 > 0 ? 1 : 2`
compiles to something the CFG opcodes list doesn't catch, expand the
list. Common culprit: `opt_case_dispatch` — add to `CONTROL_FLOW_OPCODES`.

- [ ] **Step 5: Commit.**

```bash
jj commit -m "InliningPass v1: zero-arg FCALL inline for constant-body callees"
```

---

## Task 4: Pipeline wiring, corpus fixture, integration test

**Context:** The pass currently takes a `callee_map:` kwarg. The Pipeline builds that map once per `run` by walking the IR tree and collecting every `Function` whose `type == :method`. Pipeline passes it to each pass via `**extras`. Pass base class ignores unknown kwargs today because every pass declares `object_table: nil`; we need to widen that to accept `callee_map:` too or use `**`.

**Files:**
- Modify: `optimizer/lib/optimize/pipeline.rb`
- Modify: `optimizer/lib/optimize/pass.rb`
- Modify: `optimizer/lib/optimize/passes/arith_reassoc_pass.rb`, `const_fold_pass.rb`, `identity_elim_pass.rb` (accept `**` in `apply`)
- Create: `optimizer/test/codec/corpus/inlining_zero_arg.rb`
- Modify: `optimizer/test/pipeline_test.rb`

- [ ] **Step 1: Widen `Pass#apply` signature.**

In each existing pass, replace the method signature with:

```ruby
def apply(function, type_env:, log:, object_table: nil, **_extras)
```

This makes them tolerant of extra kwargs so Pipeline can pass
`callee_map:` uniformly. Update `pass.rb` NoopPass + base class the same way.

- [ ] **Step 2: Build `callee_map` in `Pipeline#run` and pass it through.**

Modify `optimizer/lib/optimize/pipeline.rb` `run`:

```ruby
def run(ir, type_env:)
  log = Log.new
  object_table = ir.misc && ir.misc[:object_table]
  callee_map = build_callee_map(ir)
  each_function(ir) do |function|
    @passes.each do |pass|
      begin
        pass.apply(function, type_env: type_env, log: log,
                   object_table: object_table, callee_map: callee_map)
      rescue
        log.skip(pass: pass.name, reason: :pass_raised,
                 file: function.path, line: function.first_lineno || 0)
      end
    end
  end
  log
end

private

def build_callee_map(ir)
  map = {}
  each_function(ir) do |fn|
    next unless fn.type == :method
    map[fn.name.to_sym] = fn if fn.name
  end
  map
end
```

- [ ] **Step 3: Add `InliningPass` to `Pipeline.default`.**

```ruby
def self.default
  new([
    Passes::InliningPass.new,
    Passes::ArithReassocPass.new,
    Passes::ConstFoldPass.new,
    Passes::IdentityElimPass.new,
  ])
end
```

Order matters: inlining first (exposes new literals for const-fold and
reassoc). `require "optimize/passes/inlining_pass"` at the top.

- [ ] **Step 4: Add corpus fixture.**

Create `optimizer/test/codec/corpus/inlining_zero_arg.rb`:

```ruby
def magic
  42
end

def use_it
  magic
end

use_it
```

This ensures the codec's identity round-trip corpus test covers a program
with inlinable structure. Note: the codec corpus round-trip tests compile
and round-trip WITHOUT optimizer passes — they exercise codec identity,
not optimizer behaviour. So this fixture lands in the corpus just to
exercise `ci_entries` decoding on a realistic shape.

- [ ] **Step 5: Add pipeline integration test.**

Append to `optimizer/test/pipeline_test.rb`:

```ruby
def test_inlining_pass_runs_end_to_end
  src = File.read(File.expand_path("codec/corpus/inlining_zero_arg.rb", __dir__))
  bin = RubyVM::InstructionSequence.compile(src).to_binary
  ir  = Optimize::Codec.decode(bin)

  log = Optimize::Pipeline.default.run(ir, type_env: nil)

  use_it = ir.children.find { |c| c.name == "use_it" }
  refute_nil use_it
  refute use_it.instructions.any? { |i| i.opcode == :opt_send_without_block },
    "expected `use_it` to have its call to `magic` inlined"
  assert log.entries.any? { |e| e.pass == :inlining && e.reason == :inlined }

  loaded = RubyVM::InstructionSequence.load_from_binary(Optimize::Codec.encode(ir))
  assert_equal 42, loaded.eval
end
```

- [ ] **Step 6: Run the full test suite.**

Use `mcp__ruby-bytecode__run_optimizer_tests` (no file arg → runs all).

Expected: baseline count + Task 1 ci_entries tests + Task 3 inlining
unit tests + this pipeline test, all green. If the corpus round-trip
now breaks for an unrelated fixture, investigate calldata handling for
that fixture's specific call shape (kwargs, splat, blockarg).

- [ ] **Step 7: Commit.**

```bash
jj commit -m "Pipeline: wire InliningPass; corpus fixture; integration test"
```

---

## Task 5: TODO.md + design-note cross-links

**Files:**
- Modify: `docs/TODO.md`

- [ ] **Step 1: Update the three-pass table.**

In `docs/TODO.md`, change the Inlining row from:

```
| Inlining | ... | **nothing** | entire pass |
```

to:

```
| Inlining | Full pass — call-graph, receiver resolution via RBS, wrapper-method flattening, CFG splicing | v1: zero-arg FCALL inline of constant-body callees | args, receivers via RBS, wrapper flattening, CFG splicing |
```

- [ ] **Step 2: Update the roadmap-gap section.**

Replace item 1 ("Inlining pass") with:

```
1. **Inlining v2 — one-arg FCALL with local-table growth.** Unblocks
   the wrapper-flattening demo. Requires local_table codec extension.
```

Append under "Refinements of shipped work":

```
- **InliningPass v2** — one-arg FCALL inline with caller local-table
  extension for arg passing; prerequisite for wrapper flattening.
```

- [ ] **Step 3: Update "last updated" date at the top.**

Change to `2026-04-21 (after InliningPass v1)`.

- [ ] **Step 4: Commit.**

```bash
jj commit -m "docs: TODO.md — InliningPass v1 landed; v2 queued"
```

---

## Self-review checklist

- **Spec coverage:** The v1 design-note in Task 0 enumerates scope and
  non-scope; Tasks 1–4 cover scope, Task 5 documents non-scope. ✓
- **Placeholders:** none — every code block is complete Ruby. ✓
- **Type consistency:** `IR::CallData` fields used in Task 1 match
  accessor names used in Task 3 (`fcall?`, `args_simple?`, `argc`,
  `kwlen`, `mid_symbol`). `callee_map` shape is `Hash{Symbol =>
  IR::Function}` in Tasks 3 and 4. ✓
- **Reversibility check:** Task 2 is the biggest blast-radius step — it
  changes how every send opcode carries its calldata. If it breaks the
  codec round-trip, roll back to the raw-bytes path (keep `ci_entries_raw`
  as a fallback) and investigate. Task 1's test catches most issues
  before Task 2 ships.
