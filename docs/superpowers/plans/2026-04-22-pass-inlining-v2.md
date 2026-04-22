# Inlining Pass v2 — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend `InliningPass` from v1's zero-arg constant-body slice to a **one-arg FCALL** inliner with caller-side `local_table` growth. Unblocks the wrapper-flattening demo (`def double(x) = x*2; def use_it(n) = double(n)`).

**Architecture:** Add a structured `Codec::LocalTable` round-trip (decode/encode the body's `local_table` blob into object-table indices). Add a `grow!` primitive that appends an entry and propagates `local_table_size` through `misc`. Widen InliningPass preconditions (callee: `lead_num==1, local_table_size==1`; call-site: push-arg + putself + send). On splice, allocate a caller slot via `LocalTable.grow!` (reusing the callee's arg Symbol index — no ObjectTable intern extension needed), emit `setlocal <new>, 0`, then splice the callee body with every `getlocal[_WC_0] 1, 0` rewritten to `getlocal[_WC_0] <new>, 0`.

**Tech Stack:** Ruby 4.0.2, minitest, the `ruby-bytecode` MCP for all Ruby execution and test runs. Never host shell.

**Spec:** `docs/superpowers/specs/2026-04-22-pass-inlining-v2-design.md`. Read it first — the preconditions and transformation rules are exhaustive there.

**Commit discipline:** Each task ends with `jj commit -m "<msg>"` — never `jj describe -m`. Parallel subagent commits: `jj split -m "<msg>" -- <files>`. Tests via `mcp__ruby-bytecode__run_optimizer_tests`. Ruby evaluation via `mcp__ruby-bytecode__run_ruby`. Never host shell.

---

## File structure

```
optimizer/
  lib/ruby_opt/
    codec/
      local_table.rb                        # NEW Task 1 — decode/encode local_table blob
      iseq_list.rb                          # MODIFIED Task 2 — route local_table through module; re-encode from IR
    ir/
      function.rb                           # MODIFIED Task 2 — add local_table attr + accessor helpers (if not already present)
    passes/
      inlining_pass.rb                      # MODIFIED Tasks 3, 4 — widen to one-arg; splice-with-rewrite
  test/
    codec/
      local_table_test.rb                   # NEW Task 1 — round-trip corpus
      corpus/
        inlining_one_arg.rb                 # NEW Task 5 — wrapper fixture
    passes/
      inlining_pass_test.rb                 # MODIFIED Tasks 3, 4 — new v2 cases
    pipeline_test.rb                        # MODIFIED Task 5 — v2 integration
docs/
  TODO.md                                   # MODIFIED Task 6
```

---

## Task 0: Commit the design note

The spec `docs/superpowers/specs/2026-04-22-pass-inlining-v2-design.md` already exists on disk from the planning step. Commit it alone so the rest of the plan can reference it from a stable revision.

- [ ] **Step 1:** Commit.

```bash
jj commit -m "Plan: Inlining Pass v2 (one-arg FCALL, local-table growth) — design note"
```

---

## Task 1: `Codec::LocalTable` — structured round-trip

**Context:** Today `local_table` is stored as opaque bytes in `misc[:local_table_raw]` and the count lives in `misc[:local_table_size]`. Per `research/cruby/ibf-format.md` §4.1, the format is `local_table_size` small-value object-table indices (one per entry). We need a symmetric decode/encode that round-trips byte-identically across the existing fixture corpus.

**Files:**
- Create: `optimizer/lib/ruby_opt/codec/local_table.rb`
- Create: `optimizer/test/codec/local_table_test.rb`

- [ ] **Step 1: Implement the module.**

Create `optimizer/lib/ruby_opt/codec/local_table.rb`:

```ruby
# frozen_string_literal: true
require "ruby_opt/codec/binary_reader"
require "ruby_opt/codec/binary_writer"

module RubyOpt
  module Codec
    # Parse and emit the local_table section of an iseq body.
    #
    # On-disk shape (research/cruby/ibf-format.md §4.1):
    #   local_table_size fixed-width 8-byte LE uint64 entries (ID[] —
    #   CRuby's ibf_dump_local_table emits uintptr_t per entry). NOT
    #   small-value-encoded; don't confuse with ci_entries' format.
    #   Each entry is an object-table index naming a local.
    #
    # The raw blob may include trailing alignment zeros that belong to
    # the section *after* this one in the enclosing iseq layout. Decode
    # reads exactly `size` entries; encode returns exactly the content
    # bytes (no padding). The iseq_list encoder re-adds trailing pad.
    module LocalTable
      module_function

      # @param bytes [String] ASCII-8BIT local_table blob (may be longer than the content)
      # @param size  [Integer] number of entries (from body header)
      # @return [Array<Integer>] object-table indices, one per local
      def decode(bytes, size)
        return [] if size.nil? || size.zero? || bytes.nil? || bytes.empty?
        reader = BinaryReader.new(bytes)
        Array.new(size) { reader.read_u64 }
      end

      # @param entries [Array<Integer>]
      # @return [String] ASCII-8BIT byte string (content only; no padding)
      def encode(entries)
        writer = BinaryWriter.new
        entries.each { |idx| writer.write_u64(idx) }
        writer.buffer
      end
    end
  end
end
```

- [ ] **Step 2: Write the round-trip test.**

Create `optimizer/test/codec/local_table_test.rb`:

```ruby
# frozen_string_literal: true
require "test_helper"
require "ruby_opt/codec"
require "ruby_opt/codec/local_table"

class LocalTableCodecTest < Minitest::Test
  def test_round_trip_identity_for_corpus
    Dir[File.expand_path("corpus/*.rb", __dir__)].each do |fixture|
      src = File.read(fixture)
      bin = RubyVM::InstructionSequence.compile(src).to_binary
      ir  = RubyOpt::Codec.decode(bin)
      assert_each_iseq_local_table_roundtrips(ir.root)
    end
  end

  def test_decode_produces_indices_for_method_with_one_local
    src = "def take(x); x; end; take(1)"
    bin = RubyVM::InstructionSequence.compile(src).to_binary
    ir  = RubyOpt::Codec.decode(bin)
    take = find_iseq(ir.root, "take")
    refute_nil take
    size = take.misc[:local_table_size]
    assert_equal 1, size
    entries = RubyOpt::Codec::LocalTable.decode(take.misc[:local_table_raw], size)
    assert_equal 1, entries.size
    # The entry is an object-table index whose resolution is the symbol :x.
    ot = ir.root.misc[:object_table] || ir.misc[:object_table]
    ot ||= RubyOpt::Codec.last_object_table_for(bin) # fall back if stashed elsewhere
    # Resolution smoke test: at minimum the index is non-negative.
    assert entries.first.is_a?(Integer) && entries.first >= 0
  end

  private

  def assert_each_iseq_local_table_roundtrips(fn)
    size = fn.misc[:local_table_size] || 0
    raw  = fn.misc[:local_table_raw] || "".b
    entries = RubyOpt::Codec::LocalTable.decode(raw, size)
    re_encoded = RubyOpt::Codec::LocalTable.encode(entries)
    # Content bytes must match the prefix of raw (raw may include trailing pad).
    assert_equal raw.byteslice(0, re_encoded.bytesize).bytes, re_encoded.bytes,
      "local_table content mismatch in #{fn.name} (size=#{size})"
    fn.children&.each { |c| assert_each_iseq_local_table_roundtrips(c) }
  end

  def find_iseq(fn, name)
    return fn if fn.name == name
    fn.children&.each do |c|
      found = find_iseq(c, name)
      return found if found
    end
    nil
  end
end
```

- [ ] **Step 3: Run the test.**

Invoke `mcp__ruby-bytecode__run_optimizer_tests` with test file `optimizer/test/codec/local_table_test.rb`. Expected: both tests pass. If `test_decode_produces_indices_for_method_with_one_local` can't access the object_table via the paths tried, read `optimizer/lib/ruby_opt/codec.rb` to find the actual accessor and patch the test. Don't skip the assertion; update the path.

- [ ] **Step 4: Commit.**

```bash
jj commit -m "Codec: structured decode/encode for local_table entries"
```

---

## Task 2: `LocalTable.grow!` and wiring through the Function

**Context:** The inlining pass needs one mutation primitive: append an entry (object-table index) to a function's local table and keep `misc[:local_table_size]` and `misc[:local_table_raw]` in sync. The encoder at `optimizer/lib/ruby_opt/codec/iseq_list.rb:385-389` already writes `misc[:local_table_raw]` verbatim, so as long as `grow!` updates the raw bytes, the encoder picks up the new table automatically. `iseq_envelope.rb:399` already propagates `misc[:local_table_size]` into the body record.

**Files:**
- Modify: `optimizer/lib/ruby_opt/codec/local_table.rb` (add `grow!`)
- Create test cases in: `optimizer/test/codec/local_table_test.rb`

- [ ] **Step 1: Add `LocalTable.grow!`.**

Append to `optimizer/lib/ruby_opt/codec/local_table.rb` inside the `LocalTable` module:

```ruby
    # Append one entry to a function's local_table. Returns the new
    # entry's table index (post-growth `local_table_size - 1`).
    #
    # Mutates:
    #   fn.misc[:local_table_size]  — incremented
    #   fn.misc[:local_table_raw]   — re-encoded content, trailing pad
    #                                 preserved (zero bytes at tail).
    #
    # Does NOT mutate any getlocal/setlocal LINDEX values in the
    # function's instructions; callers doing so must rewrite those
    # themselves. (The inlining pass does; other callers should too.)
    def grow!(fn, object_table_index)
      misc        = fn.misc
      old_size    = (misc[:local_table_size] || 0)
      old_raw     = (misc[:local_table_raw]  || "".b)
      entries     = decode(old_raw, old_size)
      entries << object_table_index
      new_content = encode(entries)

      # Preserve any trailing alignment pad that was embedded in the
      # original raw blob (the iseq_list encoder relies on raw.bytesize
      # for section positioning).
      old_content_size = encode(entries[0..-2]).bytesize # pre-append content size
      pad_bytes        = [old_raw.bytesize - old_content_size, 0].max
      misc[:local_table_raw]  = new_content + ("\x00".b * pad_bytes)
      misc[:local_table_size] = old_size + 1
      old_size # new entry's table index == old size (zero-based append)
    end
    module_function :grow!
```

- [ ] **Step 2: Write failing tests for `grow!`.**

Append to `optimizer/test/codec/local_table_test.rb`:

```ruby
  def test_grow_appends_entry_and_increments_size
    src = "def take(x); x; end; take(1)"
    bin = RubyVM::InstructionSequence.compile(src).to_binary
    ir  = RubyOpt::Codec.decode(bin)
    take = find_iseq(ir.root, "take")
    orig_size = take.misc[:local_table_size]
    orig_entries = RubyOpt::Codec::LocalTable.decode(
      take.misc[:local_table_raw], orig_size,
    )
    sentinel_idx = orig_entries.first # re-use an existing object-table index

    new_slot = RubyOpt::Codec::LocalTable.grow!(take, sentinel_idx)

    assert_equal orig_size, new_slot
    assert_equal orig_size + 1, take.misc[:local_table_size]
    new_entries = RubyOpt::Codec::LocalTable.decode(
      take.misc[:local_table_raw], take.misc[:local_table_size],
    )
    assert_equal orig_entries + [sentinel_idx], new_entries
  end

  def test_grow_preserves_encoder_round_trip
    # Grow then re-encode the full binary; load_from_binary must succeed.
    src = "def take(x); x; end; take(1)"
    bin = RubyVM::InstructionSequence.compile(src).to_binary
    ir  = RubyOpt::Codec.decode(bin)
    take = find_iseq(ir.root, "take")
    existing_idx = RubyOpt::Codec::LocalTable.decode(
      take.misc[:local_table_raw], take.misc[:local_table_size],
    ).first
    RubyOpt::Codec::LocalTable.grow!(take, existing_idx)
    re_encoded = RubyOpt::Codec.encode(ir)
    # Smoke test: the VM accepts our re-encoded binary. We don't eval it
    # (the grown slot is unused in the body and LINDEX rewrites are the
    # inlining pass's job — execution would be wrong here). Loading alone
    # proves the iseq layout is well-formed.
    assert RubyVM::InstructionSequence.load_from_binary(re_encoded)
  end
```

- [ ] **Step 3: Run the test.**

Invoke `mcp__ruby-bytecode__run_optimizer_tests` on `local_table_test.rb`. Expect both new tests pass; the two original Task-1 tests still green.

If `test_grow_preserves_encoder_round_trip` fails with a size-mismatch error in the iseq_envelope encoder (e.g. "body record size mismatch"), the likely cause is that the body record's `local_table_size` field shifts a downstream offset encoding width. Read the envelope encode path (`iseq_envelope.rb` around the `local_table_size` write) and verify `write_small_value` variable-width encoding handles the new value. The small_value codec should handle any unsigned int ≤ 62 bits; larger is pathological.

- [ ] **Step 4: Commit.**

```bash
jj commit -m "Codec::LocalTable: grow! primitive for appending a local slot"
```

---

## Task 3: Widen `InliningPass` preconditions (one-arg, one callee local)

**Context:** Extend v1's `disqualify_callee` and call-site checks to accept `lead_num==1, local_table_size==1`. Stop rejecting one-arg calldata; start rejecting multi-arg. The actual splice rewrite lives in Task 4 — here we just add tests that exercise the new skip reasons and expand the acceptance predicate. No inlining happens yet; v2-shape call sites fall through unchanged and log `:unsupported_call_shape` for now.

**Files:**
- Modify: `optimizer/lib/ruby_opt/passes/inlining_pass.rb`
- Modify: `optimizer/test/passes/inlining_pass_test.rb`

- [ ] **Step 1: Write failing tests for new skip reasons.**

Append these cases to `optimizer/test/passes/inlining_pass_test.rb`:

```ruby
  def test_v2_skips_callee_with_multi_local
    # `y = x + 1; y` has local_table_size = 2 (x and y).
    src = "def wrap(x); y = x + 1; y; end; def use_it(n); wrap(n); end; use_it(3)"
    ir  = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot  = ir.misc[:object_table]
    use_it = find_iseq(ir, "use_it")
    wrap   = find_iseq(ir, "wrap")
    log = RubyOpt::Log.new
    RubyOpt::Passes::InliningPass.new.apply(
      use_it, type_env: nil, log: log,
      object_table: ot, callee_map: { wrap: wrap },
    )
    # No inline: the callee has more than one local.
    assert use_it.instructions.any? { |i| i.opcode == :opt_send_without_block }
    assert log.entries.any? { |e| e.reason == :callee_multi_local }
  end

  def test_v2_skips_callee_that_writes_its_arg
    src = "def reassign(x); x = 5; x; end; def use_it(n); reassign(n); end; use_it(1)"
    ir  = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot  = ir.misc[:object_table]
    use_it   = find_iseq(ir, "use_it")
    reassign = find_iseq(ir, "reassign")
    log = RubyOpt::Log.new
    RubyOpt::Passes::InliningPass.new.apply(
      use_it, type_env: nil, log: log,
      object_table: ot, callee_map: { reassign: reassign },
    )
    assert use_it.instructions.any? { |i| i.opcode == :opt_send_without_block }
    assert log.entries.any? { |e| e.reason == :callee_writes_local }
  end

  def test_v2_skips_callee_with_two_args
    src = "def add(a, b); a + b; end; def use_it(n); add(n, 1); end; use_it(1)"
    ir  = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot  = ir.misc[:object_table]
    use_it = find_iseq(ir, "use_it")
    add    = find_iseq(ir, "add")
    log = RubyOpt::Log.new
    RubyOpt::Passes::InliningPass.new.apply(
      use_it, type_env: nil, log: log,
      object_table: ot, callee_map: { add: add },
    )
    assert use_it.instructions.any? { |i| i.opcode == :opt_send_without_block }
    # `lead_num == 2` must still reject (v2 handles only one arg).
    assert log.entries.any? { |e| e.reason == :callee_has_args }
  end
```

- [ ] **Step 2: Run the tests — expect failures.**

Invoke `mcp__ruby-bytecode__run_optimizer_tests` on `inlining_pass_test.rb`. The new tests fail because `:callee_multi_local` and `:callee_writes_local` reasons aren't emitted yet (existing code emits `:callee_has_args` or `:callee_has_locals` for these).

- [ ] **Step 3: Widen the pass predicate.**

Edit `optimizer/lib/ruby_opt/passes/inlining_pass.rb`. In `disqualify_callee`:

```ruby
      def disqualify_callee(callee)
        as = callee.arg_spec || {}
        # v2: lead_num may be 0 or 1. Anything else (2+) still rejects as args.
        return :callee_has_args if (as[:lead_num] || 0) > 1
        return :callee_has_args if (as[:opt_num]  || 0).positive?
        return :callee_has_args if (as[:post_num] || 0).positive?
        return :callee_has_args if as[:has_rest]
        return :callee_has_args if as[:has_block]
        return :callee_has_args if as[:has_kw]
        return :callee_has_args if as[:has_kwrest]

        lt_size = (callee.misc && callee.misc[:local_table_size]) || 0
        # v2: local_table_size may be 0 (v1 path) or 1 (the arg only).
        return :callee_multi_local if lt_size > 1
        # If lead_num is 1, local_table_size must be exactly 1.
        if (as[:lead_num] || 0) == 1 && lt_size != 1
          return :callee_multi_local
        end

        return :callee_has_catch if callee.catch_entries && !callee.catch_entries.empty?

        insts = callee.instructions || []
        return :callee_empty if insts.empty?
        return :callee_over_budget if insts.size > INLINE_BUDGET
        return :callee_no_trailing_leave unless insts.last.opcode == :leave

        body = insts[0..-2]
        body.each do |inst|
          return :callee_has_branches if CONTROL_FLOW_OPCODES.include?(inst.opcode)
          return :callee_makes_call   if SEND_OPCODES.include?(inst.opcode)
          return :callee_has_leave_midway if inst.opcode == :leave
          return :callee_has_throw if inst.opcode == :throw
          # v2: permit only reads from slot 1 (the arg) via getlocal/getlocal_WC_0.
          # Any setlocal* or any read from other slots rejects.
          case inst.opcode
          when :setlocal, :setlocal_WC_0, :setlocal_WC_1
            return :callee_writes_local
          when :getlocal_WC_1
            return :callee_reads_outer_scope
          when :getlocal, :getlocal_WC_0
            idx = inst.operands[0]
            # Slot 1 is the single arg. Anything else (shouldn't occur
            # with local_table_size==1) rejects.
            return :callee_reads_unknown_slot unless idx == 1
          end
        end
        nil
      end
```

- [ ] **Step 4: Run the tests — expect the new failures resolve.**

Invoke `mcp__ruby-bytecode__run_optimizer_tests` on `inlining_pass_test.rb`. All v1 tests plus the three new skip-reason tests pass. No `:inlined` log line appears yet for one-arg cases — Task 4 adds that.

- [ ] **Step 5: Commit.**

```bash
jj commit -m "InliningPass: widen callee predicate for v2 (one-arg + one local)"
```

---

## Task 4: `InliningPass` v2 — splice + LINDEX shift

**Context:** With the widened predicate and `LocalTable.grow!` both in place, v2's splice is: grow the caller's local_table, **shift all existing caller LINDEXes by +1**, emit a `setlocal` into the new slot, and splice the callee body as-is. Call-site pattern: `putself; <single-instr-arg-push>; opt_send_without_block cd` with `cd.argc == 1`.

**LINDEX math — the non-obvious part.** Empirical finding (verified pre-Task 3): the IR stores raw YARV EP offsets, where `LINDEX = VM_ENV_DATA_SIZE (3) + (local_table_size − 1 − table_index)`. Consequences:

- The last-appended slot (what `grow!` returns) always has LINDEX = **3**, regardless of table size. Both the emitted `setlocal` and the callee body's `getlocal_WC_0 3` arg-read are correctly pointed at this LINDEX — **no rewrite needed inside the spliced callee body**.
- Every pre-existing caller `getlocal*`/`setlocal*` at level 0 (i.e. `getlocal_WC_0`, `setlocal_WC_0`, and `getlocal`/`setlocal` with level-operand == 0) must have its LINDEX **incremented by 1** to remain pointed at its original local (table index unchanged, but `local_table_size` grew by 1, so EP offset shifts up).
- Level-1 ops (`getlocal_WC_1`, `setlocal_WC_1`, and `getlocal`/`setlocal` with level > 0) reference the outer EP and are unaffected by the caller's growth. Predicate already excludes callees that use these.

**Files:**
- Modify: `optimizer/lib/ruby_opt/passes/inlining_pass.rb`
- Modify: `optimizer/test/passes/inlining_pass_test.rb`

- [ ] **Step 1: Re-verify the call-site instruction order (small sanity check).**

Use `mcp__ruby-bytecode__disasm` (or a direct `RubyVM::InstructionSequence#disasm` call via `mcp__ruby-bytecode__run_ruby`) on:

```ruby
def double(x); x * 2; end
def use_it(n); double(n); end
use_it(7)
```

Confirm `use_it`'s instruction order is `putself → getlocal_WC_0 n → opt_send_without_block` (putself FIRST, arg push SECOND). This is the order assumed in Step 4's splice. If it's inverted, stop and flag — your splice region math changes.

Note: EP-offset/LINDEX math has already been verified separately. The arg of a 1-arg/1-local callee reads at LINDEX 3. Any getlocal at LINDEX 3 in the callee body is reading the arg.

- [ ] **Step 2: Write the v2 happy-path test.**

Append to `optimizer/test/passes/inlining_pass_test.rb`:

```ruby
  def test_v2_inlines_one_arg_literal_fcall
    src = "def double(x); x * 2; end; def use_it; double(3); end; use_it"
    ir  = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot  = ir.misc[:object_table]
    use_it = find_iseq(ir, "use_it")
    double = find_iseq(ir, "double")

    log = RubyOpt::Log.new
    RubyOpt::Passes::InliningPass.new.apply(
      use_it, type_env: nil, log: log,
      object_table: ot, callee_map: { double: double },
    )

    refute use_it.instructions.any? { |i| i.opcode == :opt_send_without_block },
      "expected the send to `double` to be inlined"
    assert log.entries.any? { |e| e.reason == :inlined }

    # `use_it` grew by one local (the inlined arg slot).
    assert_equal 1, use_it.misc[:local_table_size]

    # Round-trip still executes correctly.
    loaded = RubyVM::InstructionSequence.load_from_binary(RubyOpt::Codec.encode(ir))
    assert_equal 6, loaded.eval
  end

  def test_v2_inlines_one_arg_forwarded_fcall
    src = "def double(x); x * 2; end; def use_it(n); double(n); end; use_it(7)"
    ir  = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot  = ir.misc[:object_table]
    use_it = find_iseq(ir, "use_it")
    double = find_iseq(ir, "double")

    # `use_it` starts with local_table_size == 1 (the `n` param).
    assert_equal 1, use_it.misc[:local_table_size]

    log = RubyOpt::Log.new
    RubyOpt::Passes::InliningPass.new.apply(
      use_it, type_env: nil, log: log,
      object_table: ot, callee_map: { double: double },
    )

    refute use_it.instructions.any? { |i| i.opcode == :opt_send_without_block }
    assert log.entries.any? { |e| e.reason == :inlined }
    # `use_it` grew by one local for the inlined arg slot.
    assert_equal 2, use_it.misc[:local_table_size]

    loaded = RubyVM::InstructionSequence.load_from_binary(RubyOpt::Codec.encode(ir))
    assert_equal 14, loaded.eval
  end

  def test_v2_skips_arg_with_multi_instruction_push
    # `double(n + 1)` pushes with `getlocal; putobject; opt_plus` — three
    # instructions, not one. v2 rejects.
    src = "def double(x); x * 2; end; def use_it(n); double(n + 1); end; use_it(1)"
    ir  = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot  = ir.misc[:object_table]
    use_it = find_iseq(ir, "use_it")
    double = find_iseq(ir, "double")

    log = RubyOpt::Log.new
    RubyOpt::Passes::InliningPass.new.apply(
      use_it, type_env: nil, log: log,
      object_table: ot, callee_map: { double: double },
    )
    assert use_it.instructions.any? { |i| i.opcode == :opt_send_without_block }
    assert log.entries.any? { |e| e.reason == :unsupported_call_shape }
  end
```

- [ ] **Step 3: Run the new happy-path tests — expect failures.**

Invoke `mcp__ruby-bytecode__run_optimizer_tests`. The three new tests all fail: the pass still logs `:unsupported_call_shape` for one-arg sends.

- [ ] **Step 4: Implement the splice.**

Edit `optimizer/lib/ruby_opt/passes/inlining_pass.rb`. At the top of the file, add:

```ruby
require "ruby_opt/codec/local_table"
```

Widen the whitelist for arg-push shapes. Add as a constant:

```ruby
      # Single-instruction arg-push opcodes v2 accepts.
      ARG_PUSH_OPCODES = %i[
        putobject putnil putstring
        putobject_INT2FIX_0_ putobject_INT2FIX_1_
        getlocal_WC_0
      ].freeze
```

Rewrite the main `apply` loop to recognise both the v1 pattern
(`putself; send argc=0`) and the v2 pattern (`putself; <arg>; send argc=1`). Replace the existing `apply` method's inner loop body with:

```ruby
        loop do
          changed = false
          i = 0
          while i < insts.size
            if insts[i].opcode == :opt_send_without_block
              if try_inline(function, i, callee_map, object_table, log)
                changed = true
                insts = function.instructions
                next
              end
            end
            i += 1
          end
          break unless changed
        end
```

Replace `try_inline` with a dispatch on `cd.argc`:

```ruby
      def try_inline(function, send_idx, callee_map, object_table, log)
        insts = function.instructions
        send_inst = insts[send_idx]
        cd = send_inst.operands[0]
        line = send_inst.line || function.first_lineno
        return false unless cd.is_a?(IR::CallData)

        mid = cd.mid_symbol(object_table)
        callee = callee_map[mid]
        unless callee
          log.skip(pass: :inlining, reason: :callee_unresolved,
                   file: function.path, line: line)
          return false
        end
        reason = disqualify_callee(callee)
        if reason
          log.skip(pass: :inlining, reason: reason,
                   file: function.path, line: line)
          return false
        end

        case cd.argc
        when 0 then try_inline_zero_arg(function, send_idx, cd, callee, log, line)
        when 1 then try_inline_one_arg(function, send_idx, cd, callee, log, line)
        else
          log.skip(pass: :inlining, reason: :unsupported_call_shape,
                   file: function.path, line: line)
          false
        end
      end

      def try_inline_zero_arg(function, send_idx, cd, callee, log, line)
        insts = function.instructions
        unless cd.fcall? && cd.args_simple? && cd.kwlen.zero? &&
               !cd.blockarg? && !cd.has_splat? &&
               send_idx >= 1 && insts[send_idx - 1].opcode == :putself
          log.skip(pass: :inlining, reason: :unsupported_call_shape,
                   file: function.path, line: line)
          return false
        end
        put_self_idx = send_idx - 1
        body = callee.instructions[0..-2]
        function.splice_instructions!(put_self_idx..(put_self_idx + 1), body)
        log.skip(pass: :inlining, reason: :inlined,
                 file: function.path, line: line)
        true
      end

      NEW_SLOT_LINDEX = 3  # VM_ENV_DATA_SIZE: LINDEX of the last-appended local

      def try_inline_one_arg(function, send_idx, cd, callee, log, line)
        insts = function.instructions
        # Shape: insts[send_idx - 2] == putself
        #        insts[send_idx - 1] == single-instruction arg push
        #        insts[send_idx]     == opt_send_without_block
        unless cd.fcall? && cd.args_simple? && cd.kwlen.zero? &&
               !cd.blockarg? && !cd.has_splat? && send_idx >= 2 &&
               insts[send_idx - 2].opcode == :putself &&
               ARG_PUSH_OPCODES.include?(insts[send_idx - 1].opcode)
          log.skip(pass: :inlining, reason: :unsupported_call_shape,
                   file: function.path, line: line)
          return false
        end

        # 1. Read the callee's single local-table entry (the arg's Symbol
        #    object-table index). Reused as the new caller slot's name —
        #    see v2 design for why this avoids ObjectTable.intern extension.
        callee_local_idx = Codec::LocalTable.decode(
          callee.misc[:local_table_raw] || "".b,
          callee.misc[:local_table_size] || 0,
        ).first
        if callee_local_idx.nil?
          log.skip(pass: :inlining, reason: :callee_local_table_unreadable,
                   file: function.path, line: line)
          return false
        end

        # 2. Grow the caller's local_table by one entry. This bumps
        #    local_table_size; EP offsets for every existing caller local
        #    now sit one higher than before.
        Codec::LocalTable.grow!(function, callee_local_idx)

        # 3. Shift every existing caller LINDEX at level 0 by +1 so
        #    pre-existing locals keep pointing at the same table index.
        #    Level-1 ops reference the outer EP and are untouched.
        #    Applies across ALL instructions — including the captured
        #    arg-push region, which is about to be spliced out; shifting
        #    it too keeps the reasoning uniform (the doomed ops don't
        #    survive the splice anyway).
        function.instructions.each do |inst|
          case inst.opcode
          when :getlocal_WC_0, :setlocal_WC_0
            inst.operands[0] = inst.operands[0] + 1
          when :getlocal, :setlocal
            # [LINDEX, LEVEL] — only level 0 references this EP.
            if inst.operands[1] == 0
              inst.operands[0] = inst.operands[0] + 1
            end
          end
        end

        # 4. Build the spliced region. Re-read arg_push AFTER the shift
        #    so it reflects the new LINDEX if it was a getlocal_WC_0.
        insts    = function.instructions
        arg_push = insts[send_idx - 1]
        setlocal = IR::Instruction.new(
          opcode: :setlocal_WC_0, operands: [NEW_SLOT_LINDEX],
          line: arg_push.line || line,
        )
        # Callee body splices as-is. Its `getlocal_WC_0 3` arg-read
        # already points at the caller's new slot (which also has
        # LINDEX 3 by the "last-appended has LINDEX 3" invariant).
        body = callee.instructions[0..-2]

        # Splice [putself, arg_push, send] -> [arg_push, setlocal, ...body]
        replacement = [arg_push, setlocal, *body]
        function.splice_instructions!((send_idx - 2)..send_idx, replacement)

        log.skip(pass: :inlining, reason: :inlined,
                 file: function.path, line: line)
        true
      end
```

The `IR::Instruction.new` invocation assumes the existing IR node constructor. Before implementing, open `optimizer/lib/ruby_opt/ir/instruction.rb` to confirm the keyword-arg names (`opcode:`, `operands:`, `line:`). Patch the synthesised lines above if the real constructor uses different kwargs (e.g. positional args, or a different `line:`/`lineno:` key).

- [ ] **Step 5: Run the v2 tests.**

Invoke `mcp__ruby-bytecode__run_optimizer_tests` on `inlining_pass_test.rb`. Expected: all v1 tests green; all three new Task-4 tests green. The `assert_equal 14, loaded.eval` is the load-bearing assertion — it proves the splice + LINDEX rewrite produces semantically-equivalent bytecode.

Diagnostic notes if it fails:

- If `load_from_binary` raises or `loaded.eval` returns a wrong value in `test_v2_inlines_one_arg_forwarded_fcall`: inspect whether the LINDEX-shift pass correctly updated every pre-existing `getlocal_WC_0`/`setlocal_WC_0` in `use_it`. A common bug: mutating `inst.operands[0]` might be a no-op if operands is frozen or if the IR uses a different operand-storage mechanism (e.g. a dedicated struct). If so, you'll need to construct replacement instructions via `IR::Instruction.new` — check `optimizer/lib/ruby_opt/ir/instruction.rb` for the ctor, and match whatever pattern existing passes use to mutate operands.
- If only the `literal_fcall` test passes but the `forwarded_fcall` test fails, the shift logic is the suspect (literal arg push doesn't have a LINDEX to shift).
- If both fail with a `load_from_binary` error, suspect the setlocal opcode choice — `setlocal_WC_0` takes ONE operand (just LINDEX), while `setlocal` takes TWO (LINDEX + LEVEL). The plan uses `setlocal_WC_0` for the single-operand form.

- [ ] **Step 6: Commit.**

```bash
jj commit -m "InliningPass v2: one-arg FCALL inline with local-table growth"
```

---

## Task 5: Pipeline integration + corpus fixture

**Files:**
- Create: `optimizer/test/codec/corpus/inlining_one_arg.rb`
- Modify: `optimizer/test/pipeline_test.rb`

- [ ] **Step 1: Add the corpus fixture.**

Create `optimizer/test/codec/corpus/inlining_one_arg.rb`:

```ruby
def double(x)
  x * 2
end

def use_it(n)
  double(n)
end

use_it(7)
```

This exercises the codec's round-trip corpus on a v2-shaped program
before any optimizer runs. (The codec round-trip tests do not run the
optimizer; it's purely a codec fixture.)

- [ ] **Step 2: Add the pipeline integration test.**

Append to `optimizer/test/pipeline_test.rb`:

```ruby
  def test_inlining_v2_end_to_end
    src = File.read(File.expand_path("codec/corpus/inlining_one_arg.rb", __dir__))
    bin = RubyVM::InstructionSequence.compile(src).to_binary
    ir  = RubyOpt::Codec.decode(bin)

    log = RubyOpt::Pipeline.default.run(ir, type_env: nil)

    use_it = ir.children.find { |c| c.name == "use_it" }
    refute_nil use_it
    refute use_it.instructions.any? { |i| i.opcode == :opt_send_without_block },
      "expected `use_it` to have its call to `double` inlined"
    assert log.entries.any? { |e| e.pass == :inlining && e.reason == :inlined }

    loaded = RubyVM::InstructionSequence.load_from_binary(RubyOpt::Codec.encode(ir))
    assert_equal 14, loaded.eval
  end
```

- [ ] **Step 3: Run the full suite.**

Invoke `mcp__ruby-bytecode__run_optimizer_tests` (no file arg → runs all). Expected: baseline + all v2 tests from Tasks 1–4 + this integration test, all green. If a codec-corpus round-trip test for an unrelated fixture now fails, investigate — Task 2's `grow!` should only mutate when called, so unrelated fixtures should be untouched.

- [ ] **Step 4: Commit.**

```bash
jj commit -m "Pipeline: v2 inlining corpus fixture + integration test"
```

---

## Task 6: TODO.md refresh

**Files:**
- Modify: `docs/TODO.md`

- [ ] **Step 1: Update the three-pass status table.**

In `docs/TODO.md`, change the Inlining row from:

```
| Inlining | Full pass — call-graph, receiver resolution via RBS, wrapper-method flattening, CFG splicing | v1: zero-arg FCALL inline of constant-body callees (no locals, no branches, no catch, no nested sends) | args, receivers via RBS, wrapper flattening, CFG splicing |
```

to:

```
| Inlining | Full pass — call-graph, receiver resolution via RBS, wrapper-method flattening, CFG splicing | v1+v2: zero-arg and one-arg FCALL inline (constant-body, single-local callees) | multi-arg, kwargs, blocks, receivers via RBS, CFG splicing across BBs |
```

- [ ] **Step 2: Update ranked roadmap gap #1.**

Replace the v2 bullet with:

```
1. **RBS type environment.** Prerequisite for "sound in principle"
   across every pass and for the object-y demo. v2 inlining shipped,
   so the next narrative beat is the `Point#distance_to` demo — which
   needs receiver resolution.
```

Renumber subsequent items. Move the old #1 (v2 bullet) out of
"Refinements of shipped work" since it's now shipped. Add a new
refinement bullet:

```
- **InliningPass v3** — multi-arg FCALL inline (merge callee locals
  into caller table, rewrite all LINDEX refs). Prereq for
  `Point#distance_to`-style demos that take 2+ args.
```

- [ ] **Step 3: Bump the "last updated" date.**

Change to `2026-04-22 (after InliningPass v2)`.

- [ ] **Step 4: Commit.**

```bash
jj commit -m "docs: TODO.md — InliningPass v2 landed; RBS env is next"
```

---

## Self-review checklist

- **Spec coverage:** v2 design's §Preconditions (call-site + callee) is
  encoded in Tasks 3 and 4. §Transformation (slot alloc, setlocal
  emit, LINDEX rewrite) is Task 4. §Codec deliverable (LocalTable
  module) is Tasks 1 and 2. Failure-behavior skip reasons all appear
  in Task 3/4 tests. ✓
- **Placeholders:** every code block is concrete Ruby. Step 1 of Task 4
  is an empirical verification — that's a deliberate investigation
  step, not a placeholder. ✓
- **Type consistency:** `LocalTable.decode`/`.encode`/`.grow!`
  signatures match between Tasks 1, 2, and 4. `cd.argc`, `cd.fcall?`,
  `cd.mid_symbol` all already exist on `IR::CallData` from v1's Task
  1. ✓
- **Reversibility check:** the biggest blast-radius step is Task 4's
  splice implementation. If LINDEX direction turns out to be "shift
  existing locals," Task 4 Step 5's diagnostic note directs the
  implementer to a helper that centralises the math; that's a
  per-op fix, not a redesign. Task 2's `grow!` is a pure append and
  byte-pad preserving — easy to back out if needed.
- **Ordering:** Tasks 1 and 2 must ship before Task 4. Task 3 can
  overlap with Tasks 1–2 (it only widens the predicate). Consider
  running Tasks 1+3 as parallel subagents, then Task 2, then Task 4.
