# Const-Fold Pass — Tier 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land the optimizer's first real pass — fold Integer literal arithmetic and comparison triples inside a single basic block, with chain folding via an internal fixpoint, `:would_raise` and `:non_integer_literal` skip logging, successful-fold logging, and line-annotation inheritance.

**Architecture:** A forward scan over `function.instructions` finds a foldable triple (`literal; literal; opt_{plus,minus,mult,div,mod,lt,le,gt,ge,eq,neq}`), computes the result by running the Ruby op at optimize time (rescuing to skip), and splices one `putobject`-family instruction in place of the three. The pass iterates its own scan until no fold fires. The codec (Task 5d of `2026-04-19-codec-length-changes.md`) handles dangling line/catch refs, `stack_max` recomputation, and `iseq_size` automatically.

**Tech Stack:** Ruby 4.0.2, minitest, the `ruby-bytecode` MCP for all test runs and ad-hoc Ruby evaluation.

**Spec:** `docs/superpowers/specs/2026-04-20-pass-const-fold-tier1.md`.

**Commit discipline:** Each task ends in `jj commit -m "<msg>"`. Executors MUST translate that to `jj split -m "<msg>" -- <files>` using the exact file list from the task's Files section. Use `jj commit -m "<msg>"` (not `jj describe -m`) to finalize. Never commit via host bash wrappers. Tests via `mcp__ruby-bytecode__run_optimizer_tests` only, never host `rake test`.

---

## File structure

```
optimizer/
  lib/optimize/
    codec/
      object_table.rb           # MODIFIED Task 1a — index_for, intern, encode-with-append
    codec.rb                    # MODIFIED Task 1a — patch global_object_list_size header field
    passes/
      const_fold_pass.rb        # NEW — the pass
      literal_value.rb          # NEW — shared literal-read/emit helper
    pipeline.rb                 # MODIFIED (default pipeline uses ConstFoldPass)
  test/
    codec/
      object_table_intern_test.rb     # NEW Task 1a
    passes/
      literal_value_test.rb     # NEW — operand encoding + read/emit
      const_fold_pass_test.rb   # NEW — unit + end-to-end
      const_fold_pass_corpus_test.rb  # NEW — corpus regression under default pipeline
```

---

### Task 1a: `ObjectTable#intern` — append new special-const objects

**Context — the canary:** While drafting Task 1, the implementer discovered that plain `putobject`'s `operands[0]` is an **object-table index** (not a raw VALUE). To emit a freshly-folded literal like `putobject 6` the pass needs to either find an existing index for the value `6` or add it to the table. This task extends the codec with that capability; Task 1's `LiteralValue.emit` will call into it.

**Scope bounds:** only **special-const** values — Integer fixnums (small enough to fit in a VALUE, i.e. the `Integer === v && (v >> 62).zero?` range in Ruby 4.0.2 on 64-bit — but in practice every Integer we'll fold is well inside this), plus `true`, `false`, `nil`. That covers tier-1 const-fold results; strings/arrays/etc. stay out of scope. The `special_const` encoding is a 1-byte header + 1 small_value VALUE — self-contained, no cross-object references, safe to append.

**On-disk layout recap** (from `research/cruby/ibf-format.md` §3 and the existing decoder):
- The object data region precedes the object offset array. Each object is a 1-byte header (bits: `[4:0]=type`, `[5]=special_const`, `[6]=frozen`, `[7]=internal`) followed by its body. For special-const objects, `type=0`, `special_const=1`, body is a single small_value holding the raw VALUE.
- The offset array is `global_object_list_size` × `uint32` absolute byte offsets into the binary.
- `global_object_list_size` is a header field at byte offset 24 (4 bytes, little-endian uint32).

**Files:**
- Modify: `optimizer/lib/optimize/codec/object_table.rb`
- Modify: `optimizer/lib/optimize/codec.rb`
- Create: `optimizer/test/codec/object_table_intern_test.rb`

- [ ] **Step 1: Write the failing tests** — `optimizer/test/codec/object_table_intern_test.rb`

```ruby
# frozen_string_literal: true
require "test_helper"
require "optimize/codec"

class ObjectTableInternTest < Minitest::Test
  def test_index_for_finds_existing_literal_from_source
    ir = Optimize::Codec.decode(
      RubyVM::InstructionSequence.compile("def f; 2 + 3; end; f").to_binary
    )
    ot = ir.misc[:object_table]
    # 2 and 3 are both literal operands in the source, so both are in the table.
    refute_nil ot.index_for(2), "expected existing index for 2"
    refute_nil ot.index_for(3), "expected existing index for 3"
    # Something not in the source is nil.
    assert_nil ot.index_for(9999)
  end

  def test_intern_returns_existing_index_without_growing_the_table
    ir = Optimize::Codec.decode(
      RubyVM::InstructionSequence.compile("def f; 2 + 3; end; f").to_binary
    )
    ot = ir.misc[:object_table]
    before_size = ot.objects.size
    idx = ot.intern(2)
    assert_equal ot.index_for(2), idx
    assert_equal before_size, ot.objects.size, "intern of existing value must not grow table"
  end

  def test_intern_appends_new_integer_and_binary_round_trips
    src = "def f; 2 + 3; end; f"
    original = RubyVM::InstructionSequence.compile(src).to_binary
    ir = Optimize::Codec.decode(original)
    ot = ir.misc[:object_table]
    before_size = ot.objects.size
    new_idx = ot.intern(6)
    assert_equal before_size, new_idx, "new index should be the previous end-of-table"
    assert_equal before_size + 1, ot.objects.size
    assert_equal 6, ot.objects[new_idx]

    # Re-encoding after an intern must produce a binary that load_from_binary accepts.
    modified = Optimize::Codec.encode(ir)
    loaded = RubyVM::InstructionSequence.load_from_binary(modified)
    assert_kind_of RubyVM::InstructionSequence, loaded

    # The loaded iseq still evaluates as before (we didn't touch any instructions).
    assert_equal 5, loaded.eval
  end

  def test_intern_appends_true_and_false_when_absent
    # Compile a source that doesn't naturally carry true/false literals.
    src = "def f; 1 + 2; end; f"
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]

    t_idx = ot.intern(true)
    f_idx = ot.intern(false)
    assert_equal true,  ot.objects[t_idx]
    assert_equal false, ot.objects[f_idx]

    modified = Optimize::Codec.encode(ir)
    loaded = RubyVM::InstructionSequence.load_from_binary(modified)
    assert_kind_of RubyVM::InstructionSequence, loaded
  end

  def test_unmodified_round_trip_still_byte_identical
    # Sanity: this task must not break the identity round-trip when no intern happens.
    src = "def f; 2 + 3; end; f"
    original = RubyVM::InstructionSequence.compile(src).to_binary
    ir = Optimize::Codec.decode(original)
    assert_equal original, Optimize::Codec.encode(ir)
  end
end
```

- [ ] **Step 2: Run, expect NoMethodError.** Use `mcp__ruby-bytecode__run_optimizer_tests` with `test_filter: "test/codec/object_table_intern_test.rb"`.

- [ ] **Step 3: Extend `ObjectTable`** — `optimizer/lib/optimize/codec/object_table.rb`

Add the following public API. You will need an `@appended` list (`Array<Object>` of values added since decode, in order) and a small serializer for their payloads:

```ruby
# Find the index of an already-decoded Ruby value in the table.
# @return [Integer, nil]
def index_for(value)
  @objects.index { |o| o == value && o.class == value.class }
end

# Return the index of +value+, appending a new special-const entry
# if it is not already present. Only special-const values (Integer
# fixnums, true, false, nil) are supported; anything else raises.
# @return [Integer]
def intern(value)
  existing = index_for(value)
  return existing if existing

  # Append in-memory.
  new_idx = @objects.size
  @objects << value
  @appended ||= []
  @appended << value
  new_idx
end
```

Modify `#encode` to serialize appended objects when `@appended` is non-empty. Fast path stays for the no-append, no-delta case. The general path:

1. Write the ORIGINAL data bytes (before the offset array): `@raw_object_region.byteslice(0, @obj_list_offset_in_region)`.
2. For each appended object, record its absolute position (`writer.pos`) and write its 2-byte payload:
   - 1 byte header: `0 | (1 << 5) | (1 << 6) = 0x60` (type=0, special_const=1, frozen=1) — or match what CRuby emits; the safe choice is to use the same header byte the decoder verifies (inspect decoder: `hdr & 0x1f` and `(hdr >> 5) & 1`, so anything with type=0 and special_const=1 works; set frozen=1 for fixnums/true/false/nil — they're all frozen)
   - 1 small_value for the encoded VALUE: `(n << 1) | 1` for fixnums, `QTRUE`/`QFALSE`/`QNIL` for booleans/nil
3. Write the ORIGINAL offset array entries (patched by `iseq_list_delta` as today).
4. Write the new offset array entries — the absolute positions from step 2, patched by `iseq_list_delta`.
5. Write any trailing bytes that were after the original offset array (there shouldn't be any under normal layout, but preserve the existing trail-bytes write as defensive code).

The old `iseq_list_delta == 0 && obj_list_size == 0` fast path collapses into the general path; keep the existing "no delta, no append" fast path for the unmodified case by checking `@appended.nil? || @appended.empty?`.

Expose `@appended.size` (or equivalent) so Codec.encode can patch the header's `global_object_list_size`. Simplest: add `def appended_count; (@appended || []).size; end`.

- [ ] **Step 4: Patch `global_object_list_size` in `Codec.encode`** — `optimizer/lib/optimize/codec.rb`

After the existing header-field patches at lines ~138–140, add:

```ruby
appended = object_table.appended_count
if appended.positive?
  fresh_object_list_size = header.global_object_list_size + appended
  buf[24, 4] = [fresh_object_list_size].pack("V")
end
```

Also: the `iseq_list_delta` math today is `fresh_iseq_list_offset - header.iseq_list_offset`. That delta still applies to the original offset-array entries (their absolute positions shifted because the iseq region changed size). The new appended objects' absolute positions are written by `ObjectTable#encode` directly at their correct final positions (they're computed at write time from `writer.pos`), so no additional patching is needed for them.

- [ ] **Step 5: Run intern tests via MCP, expect pass.** `test_filter: "test/codec/object_table_intern_test.rb"`. All 5 tests.

- [ ] **Step 6: Full-suite regression via MCP.** Expected: previous 79 + 5 new = 84, 0 failures. The `test_unmodified_round_trip_still_byte_identical` test in this file plus every existing corpus round-trip test must still pass byte-for-byte — the fast path must remain intact.

If any existing byte-identical fixture drifts: `@appended` is leaking into the "no append" path. Guard explicitly.

- [ ] **Step 7: Commit**

```
jj commit -m "ObjectTable: intern new special-const values with encode-time append"
```

(Files: `optimizer/lib/optimize/codec/object_table.rb`, `optimizer/lib/optimize/codec.rb`, `optimizer/test/codec/object_table_intern_test.rb`.)

---

### Task 1: `LiteralValue` helper — read and emit Integer literals

**Context:** `putobject`'s `operands[0]` is an **object-table index** (confirmed during the Task 1a canary, documented in `IR::Instruction`'s docstring). `LiteralValue` is the bridge between "a `putobject` instruction" and "a Ruby Integer/boolean value" — it reads by resolving indices via `ObjectTable#objects` and emits by calling `ObjectTable#intern` (added in Task 1a) to get an index for the fold result.

Ruby 4.0.2 has three literal-producer shapes:

- `putobject_INT2FIX_0_` — pushes 0 (no operand)
- `putobject_INT2FIX_1_` — pushes 1 (no operand)
- `putobject <index>` — pushes `object_table.objects[index]`

`LiteralValue`'s two entry points:

- `LiteralValue.read(inst, object_table:)` → the Integer/boolean the instruction produces, or `nil` if it's not a recognized literal producer
- `LiteralValue.emit(value, line:, object_table:)` → a new `IR::Instruction` that pushes `value` onto the stack. Uses `putobject_INT2FIX_0_`/`_1_` for `0`/`1` (no table entry needed), and `putobject <intern(value)>` otherwise

**Files:**
- Create: `optimizer/lib/optimize/passes/literal_value.rb`
- Create: `optimizer/test/passes/literal_value_test.rb`

- [ ] **Step 1: Write the investigation + behavior test** — `optimizer/test/passes/literal_value_test.rb`

```ruby
# frozen_string_literal: true
require "test_helper"
require "optimize/codec"
require "optimize/passes/literal_value"

class LiteralValueTest < Minitest::Test
  def test_read_plain_putobject_resolves_via_object_table
    ir = Optimize::Codec.decode(
      RubyVM::InstructionSequence.compile("def f; 2; end; f").to_binary
    )
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    po = f.instructions.find { |i| i.opcode == :putobject }
    refute_nil po, "expected a plain putobject for literal 2"
    assert_equal 2, Optimize::Passes::LiteralValue.read(po, object_table: ot)
  end

  def test_read_handles_dedicated_0_and_1_opcodes
    ir = Optimize::Codec.decode(
      RubyVM::InstructionSequence.compile("def f; 0; end; def g; 1; end").to_binary
    )
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    g = find_iseq(ir, "g")
    zero = f.instructions.find { |i| i.opcode == :putobject_INT2FIX_0_ }
    one  = g.instructions.find { |i| i.opcode == :putobject_INT2FIX_1_ }
    refute_nil zero, "expected a putobject_INT2FIX_0_"
    refute_nil one,  "expected a putobject_INT2FIX_1_"
    assert_equal 0, Optimize::Passes::LiteralValue.read(zero, object_table: ot)
    assert_equal 1, Optimize::Passes::LiteralValue.read(one, object_table: ot)
  end

  def test_read_returns_nil_for_non_literal_producer
    ir = Optimize::Codec.decode(
      RubyVM::InstructionSequence.compile("def f; x = 1; x; end").to_binary
    )
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    getlocal = f.instructions.find { |i| i.opcode.to_s.start_with?("getlocal") }
    refute_nil getlocal
    assert_nil Optimize::Passes::LiteralValue.read(getlocal, object_table: ot)
  end

  def test_emit_prefers_dedicated_opcodes_for_0_and_1
    # Any object_table — 0/1 don't need it.
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile("nil").to_binary)
    ot = ir.misc[:object_table]
    zero = Optimize::Passes::LiteralValue.emit(0, line: 42, object_table: ot)
    one  = Optimize::Passes::LiteralValue.emit(1, line: 42, object_table: ot)
    assert_equal :putobject_INT2FIX_0_, zero.opcode
    assert_equal :putobject_INT2FIX_1_, one.opcode
    assert_empty zero.operands
    assert_empty one.operands
    assert_equal 42, zero.line
    assert_equal 42, one.line
  end

  def test_emit_interns_arbitrary_integer_and_is_readable
    ir = Optimize::Codec.decode(
      RubyVM::InstructionSequence.compile("def f; 2 + 3; end; f").to_binary
    )
    ot = ir.misc[:object_table]
    inst = Optimize::Passes::LiteralValue.emit(42, line: 7, object_table: ot)
    assert_equal :putobject, inst.opcode
    assert_equal 1, inst.operands.size
    assert_equal 42, ot.objects[inst.operands[0]]
    assert_equal 42, Optimize::Passes::LiteralValue.read(inst, object_table: ot)
    assert_equal 7, inst.line
  end

  def test_emit_true_and_false_via_intern
    ir = Optimize::Codec.decode(
      RubyVM::InstructionSequence.compile("def f; 1; end").to_binary
    )
    ot = ir.misc[:object_table]
    t = Optimize::Passes::LiteralValue.emit(true,  line: 1, object_table: ot)
    f = Optimize::Passes::LiteralValue.emit(false, line: 1, object_table: ot)
    assert_equal :putobject, t.opcode
    assert_equal :putobject, f.opcode
    assert_equal true,  Optimize::Passes::LiteralValue.read(t, object_table: ot)
    assert_equal false, Optimize::Passes::LiteralValue.read(f, object_table: ot)
  end

  def test_emit_reuses_existing_index_when_value_already_in_table
    ir = Optimize::Codec.decode(
      RubyVM::InstructionSequence.compile("def f; 2 + 3; end; f").to_binary
    )
    ot = ir.misc[:object_table]
    before_size = ot.objects.size
    inst = Optimize::Passes::LiteralValue.emit(3, line: 1, object_table: ot)
    # 3 is already in the table from the source — no new entry should appear.
    assert_equal before_size, ot.objects.size
    assert_equal 3, ot.objects[inst.operands[0]]
  end

  def test_emit_round_trips_through_codec
    # A fold-emit followed by re-encode must produce a loadable binary.
    src = "def f; 2 + 3; end; f"
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    # Sanity: unmodified round-trip first.
    assert_equal(
      RubyVM::InstructionSequence.compile(src).to_binary,
      Optimize::Codec.encode(ir),
    )
    # Emit an interned value; the binary should still load even though
    # we didn't actually splice the instruction anywhere.
    _unused = Optimize::Passes::LiteralValue.emit(99, line: 1, object_table: ot)
    loaded = RubyVM::InstructionSequence.load_from_binary(Optimize::Codec.encode(ir))
    assert_kind_of RubyVM::InstructionSequence, loaded
  end

  private

  def find_iseq(ir, name)
    return ir if ir.name == name
    ir.children&.each do |c|
      found = find_iseq(c, name)
      return found if found
    end
    nil
  end
end
```

- [ ] **Step 2: Run, expect LoadError** for `optimize/passes/literal_value`

Run: `mcp__ruby-bytecode__run_optimizer_tests` with `test_filter: "test/passes/literal_value_test.rb"`.

Expected: `cannot load such file -- optimize/passes/literal_value`.

- [ ] **Step 3: Implement `LiteralValue`** — `optimizer/lib/optimize/passes/literal_value.rb`

Implement the module. The behavior contract is fully specified by the tests above. The specific operand encoding for non-0/1 Integer literals — whether `operands[0]` is the raw VALUE `(n<<1)|1` or an object-table index — is determined by running the investigation test in Step 2 (it will fail until you inspect the actual operand and write the right `read` / `emit` code).

Full implementation:

```ruby
# frozen_string_literal: true
require "optimize/ir/instruction"

module Optimize
  module Passes
    # Reads and emits Integer and boolean literal-producer instructions.
    #
    # Ruby 4.0.2 has three literal-producer shapes:
    #   putobject_INT2FIX_0_     — pushes 0 (no operand)
    #   putobject_INT2FIX_1_     — pushes 1 (no operand)
    #   putobject <index>        — pushes object_table.objects[index]
    module LiteralValue
      module_function

      # @param inst         [IR::Instruction]
      # @param object_table [Codec::ObjectTable]
      # @return [Integer, true, false, nil] the pushed value, or nil if
      #   the instruction is not a recognized literal producer
      def read(inst, object_table:)
        case inst.opcode
        when :putobject_INT2FIX_0_ then 0
        when :putobject_INT2FIX_1_ then 1
        when :putobject
          idx = inst.operands[0]
          return nil unless idx.is_a?(Integer)
          object_table.objects[idx]
        end
      end

      # @param value        [Integer, true, false]
      # @param line         [Integer, nil]
      # @param object_table [Codec::ObjectTable]
      # @return [IR::Instruction]
      def emit(value, line:, object_table:)
        case value
        when 0
          IR::Instruction.new(opcode: :putobject_INT2FIX_0_, operands: [], line: line)
        when 1
          IR::Instruction.new(opcode: :putobject_INT2FIX_1_, operands: [], line: line)
        else
          idx = object_table.intern(value)
          IR::Instruction.new(opcode: :putobject, operands: [idx], line: line)
        end
      end
    end
  end
end
```

- [ ] **Step 4: Run tests via MCP, expect all 8 to pass.**

Run: `mcp__ruby-bytecode__run_optimizer_tests` with `test_filter: "test/passes/literal_value_test.rb"`.

- [ ] **Step 5: Full-suite regression via MCP.** Expected: previous 84 tests (79 baseline + 5 from Task 1a) + 8 new = 92, 0 failures.

- [ ] **Step 6: Commit**

```
jj commit -m "Add LiteralValue read/emit helper for const-fold pass"
```

(Files: `optimizer/lib/optimize/passes/literal_value.rb`, `optimizer/test/passes/literal_value_test.rb`.)

---

### Task 2: `ConstFoldPass` — single-triple Integer arithmetic fold

**Context:** Simplest working slice: one forward scan, arithmetic ops only (`opt_plus`, `opt_minus`, `opt_mult`, `opt_div`, `opt_mod`). The step-back-after-fold pattern is introduced here so simple chains work; the outer fixpoint arrives in Task 4. Comparisons arrive in Task 3, skip logging in Task 5.

**Interface change — thread `object_table` through `Pass#apply`:** `LiteralValue.read`/`.emit` take an `object_table:` keyword (Tasks 1 and 1a). The pass needs access. Extend `Pass#apply` to accept `object_table: nil` and update `Pipeline#run` to pull it from `ir.misc[:object_table]` and pass it to every `apply` call.

**Files:**
- Create: `optimizer/lib/optimize/passes/const_fold_pass.rb`
- Modify: `optimizer/lib/optimize/pass.rb` (Pass#apply keyword, NoopPass#apply keyword)
- Modify: `optimizer/lib/optimize/pipeline.rb` (pull object_table from root ir, thread through)
- Modify: `optimizer/test/pass_test.rb` (update NoopPass test call)
- Modify: `optimizer/test/pipeline_test.rb` (if it calls apply directly)
- Create: `optimizer/test/passes/const_fold_pass_test.rb`

- [ ] **Step 1: Write the failing test** — `optimizer/test/passes/const_fold_pass_test.rb`

```ruby
# frozen_string_literal: true
require "test_helper"
require "optimize/codec"
require "optimize/log"
require "optimize/passes/const_fold_pass"

class ConstFoldPassTest < Minitest::Test
  def test_folds_single_arithmetic_triple
    ir = Optimize::Codec.decode(
      RubyVM::InstructionSequence.compile("def f; 2 + 3; end; f").to_binary
    )
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    before_count = f.instructions.size
    log = Optimize::Log.new
    Optimize::Passes::ConstFoldPass.new.apply(f, type_env: nil, log: log, object_table: ot)
    # Three instructions collapse to one: net -2.
    assert_equal before_count - 2, f.instructions.size
    folded = f.instructions.find { |i| Optimize::Passes::LiteralValue.read(i, object_table: ot) == 5 }
    refute_nil folded, "expected a literal producer for 5 after the fold"
  end

  def test_folded_iseq_runs_and_returns_expected_value
    src = "def f; 2 + 3; end; f"
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    Optimize::Passes::ConstFoldPass.new.apply(find_iseq(ir, "f"), type_env: nil, log: Optimize::Log.new, object_table: ot)
    loaded = RubyVM::InstructionSequence.load_from_binary(Optimize::Codec.encode(ir))
    assert_equal 5, loaded.eval
  end

  def test_leaves_non_literal_operands_alone
    ir = Optimize::Codec.decode(
      RubyVM::InstructionSequence.compile("def f(x); x + 2; end").to_binary
    )
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    before = f.instructions.map(&:opcode)
    Optimize::Passes::ConstFoldPass.new.apply(f, type_env: nil, log: Optimize::Log.new, object_table: ot)
    assert_equal before, f.instructions.map(&:opcode)
  end

  private

  def find_iseq(ir, name)
    return ir if ir.name == name
    ir.children&.each do |c|
      found = find_iseq(c, name)
      return found if found
    end
    nil
  end
end
```

- [ ] **Step 2: Run, expect LoadError / NoMethodError.**

Run: `mcp__ruby-bytecode__run_optimizer_tests` with `test_filter: "test/passes/const_fold_pass_test.rb"`.

- [ ] **Step 3: Extend `Pass#apply` to accept `object_table:`** — `optimizer/lib/optimize/pass.rb`

Change `Pass#apply` and `NoopPass#apply` to:

```ruby
def apply(function, type_env:, log:, object_table: nil)
  raise NotImplementedError  # in Pass
end
```

Update `optimizer/lib/optimize/pipeline.rb`'s `#run`: after receiving the root `ir`, pull `object_table = ir.misc && ir.misc[:object_table]`, and pass `object_table: object_table` to every `pass.apply(...)` call. Update any existing test in `optimizer/test/pass_test.rb` / `optimizer/test/pipeline_test.rb` that calls `apply` directly to pass `object_table:` (nil is fine for NoopPass).

- [ ] **Step 4: Implement `ConstFoldPass`** — `optimizer/lib/optimize/passes/const_fold_pass.rb`

```ruby
# frozen_string_literal: true
require "optimize/pass"
require "optimize/passes/literal_value"

module Optimize
  module Passes
    class ConstFoldPass < Optimize::Pass
      ARITH_OPS = {
        opt_plus:  :+,
        opt_minus: :-,
        opt_mult:  :*,
        opt_div:   :/,
        opt_mod:   :%,
      }.freeze

      def apply(function, type_env:, log:, object_table: nil)
        _ = type_env # unused in tier 1
        return unless object_table # cannot fold without a table
        insts = function.instructions
        return unless insts

        i = 0
        while i <= insts.size - 3
          a  = insts[i]
          b  = insts[i + 1]
          op = insts[i + 2]
          new_inst = try_fold_arith(a, b, op, function, log, object_table)
          if new_inst
            insts[i, 3] = [new_inst]
            # Step back so we recheck at `i-1` in case the previous
            # instruction is now the first of a new foldable triple.
            i = i - 1 if i.positive?
          else
            i += 1
          end
        end
      end

      def name = :const_fold

      private

      def try_fold_arith(a, b, op, function, log, object_table)
        sym = ARITH_OPS[op.opcode]
        return nil unless sym
        av = LiteralValue.read(a, object_table: object_table)
        bv = LiteralValue.read(b, object_table: object_table)
        return nil unless av.is_a?(Integer) && bv.is_a?(Integer)
        result = av.public_send(sym, bv)
        LiteralValue.emit(result, line: a.line, object_table: object_table)
      rescue StandardError
        nil # would raise at runtime — leave the triple alone
      end
    end
  end
end
```

- [ ] **Step 5: Run the three test cases via MCP, expect pass.**

- [ ] **Step 6: Full-suite regression via MCP.** Expected: 95 runs, 0 failures. Any codec fixture that regressed means the length-changing encode path is off — diagnose before moving on (this is the first *real* length-changing mutation).

- [ ] **Step 7: Commit**

```
jj commit -m "ConstFoldPass: fold literal Integer arithmetic triples"
```

(Files: `optimizer/lib/optimize/pass.rb`, `optimizer/lib/optimize/pipeline.rb`, `optimizer/lib/optimize/passes/const_fold_pass.rb`, `optimizer/test/pass_test.rb`, `optimizer/test/pipeline_test.rb`, `optimizer/test/passes/const_fold_pass_test.rb`.)

---

### Task 3: Extend to comparison ops

**Context:** Add `opt_lt`, `opt_le`, `opt_gt`, `opt_ge`, `opt_eq`, `opt_neq` using the same triple shape. Result is `true`/`false`, emitted via `LiteralValue.emit(bool, ...)`.

**Files:**
- Modify: `optimizer/lib/optimize/passes/const_fold_pass.rb`
- Modify: `optimizer/test/passes/const_fold_pass_test.rb`

- [ ] **Step 1: Add failing tests** to `const_fold_pass_test.rb`

```ruby
  def test_folds_integer_comparison_to_boolean
    ir = Optimize::Codec.decode(
      RubyVM::InstructionSequence.compile("def f; 5 < 10; end; f").to_binary
    )
    f = find_iseq(ir, "f")
    Optimize::Passes::ConstFoldPass.new.apply(f, type_env: nil, log: Optimize::Log.new, object_table: ot)
    folded = f.instructions.find { |i| Optimize::Passes::LiteralValue.read(i, object_table: ot) == true }
    refute_nil folded
    loaded = RubyVM::InstructionSequence.load_from_binary(Optimize::Codec.encode(ir))
    assert_equal true, loaded.eval
  end

  def test_folds_integer_equality
    ir = Optimize::Codec.decode(
      RubyVM::InstructionSequence.compile("def f; 5 == 5; end; def g; 5 == 6; end").to_binary
    )
    f = find_iseq(ir, "f")
    g = find_iseq(ir, "g")
    pass = Optimize::Passes::ConstFoldPass.new
    pass.apply(f, type_env: nil, log: Optimize::Log.new, object_table: ot)
    pass.apply(g, type_env: nil, log: Optimize::Log.new, object_table: ot)
    assert(f.instructions.any? { |i| Optimize::Passes::LiteralValue.read(i, object_table: ot) == true })
    assert(g.instructions.any? { |i| Optimize::Passes::LiteralValue.read(i, object_table: ot) == false })
  end
```

- [ ] **Step 2: Run new tests via MCP, expect failure.**

- [ ] **Step 3: Extend `ConstFoldPass`** — replace `ARITH_OPS` with a unified op map and rename `try_fold_arith` → `try_fold_triple`:

```ruby
FOLDABLE_OPS = {
  opt_plus:  :+,
  opt_minus: :-,
  opt_mult:  :*,
  opt_div:   :/,
  opt_mod:   :%,
  opt_lt:    :<,
  opt_le:    :<=,
  opt_gt:    :>,
  opt_ge:    :>=,
  opt_eq:    :==,
  opt_neq:   :"!=",
}.freeze

private

def try_fold_triple(a, b, op, function, log, object_table)
  sym = FOLDABLE_OPS[op.opcode]
  return nil unless sym
  av = LiteralValue.read(a, object_table: object_table)
  bv = LiteralValue.read(b, object_table: object_table)
  return nil unless av.is_a?(Integer) && bv.is_a?(Integer)
  result = av.public_send(sym, bv)
  LiteralValue.emit(result, line: a.line, object_table: object_table)
rescue StandardError
  nil
end
```

Update the `apply` body's call to use the new name. `LiteralValue.emit` already handles the boolean result type.

- [ ] **Step 4: Run full const-fold test file via MCP, expect pass.**

- [ ] **Step 5: Full-suite regression via MCP.** Expected: 97 runs, 0 failures.

- [ ] **Step 6: Commit**

```
jj commit -m "ConstFoldPass: fold Integer comparison triples (lt/le/gt/ge/eq/neq)"
```

(Files: `optimizer/lib/optimize/passes/const_fold_pass.rb`, `optimizer/test/passes/const_fold_pass_test.rb`.)

---

### Task 4: Chain folding via internal fixpoint

**Context:** The Task 2 "step back on fold" trick handles *simple* chains like `A B op C op` (where folding `A B op` makes the new literal+C pair foldable at the next step). YARV's actual chain shape for `1 + 2 + 3` is:

```
putobject 1
putobject 2
opt_plus
putobject 3
opt_plus
```

After the first fold we have `putobject 3; putobject 3; opt_plus` — the step-back logic already catches this case. Add an explicit outer-loop fixpoint as belt-and-braces so any missed triple-shape is auto-covered, and prove the deep-chain case with a test.

**Files:**
- Modify: `optimizer/lib/optimize/passes/const_fold_pass.rb`
- Modify: `optimizer/test/passes/const_fold_pass_test.rb`

- [ ] **Step 1: Add failing test for deep chain**

```ruby
  def test_folds_deep_integer_chain_to_single_literal
    src = "def f; 1 + 2 + 3 + 4 + 5; end; f"
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    f = find_iseq(ir, "f")
    log = Optimize::Log.new
    Optimize::Passes::ConstFoldPass.new.apply(f, type_env: nil, log: log, object_table: ot)
    folded = f.instructions.find { |i| Optimize::Passes::LiteralValue.read(i, object_table: ot) == 15 }
    refute_nil folded, "expected the whole chain to fold to 15"
    loaded = RubyVM::InstructionSequence.load_from_binary(Optimize::Codec.encode(ir))
    assert_equal 15, loaded.eval
  end

  def test_partial_chain_fold_when_a_non_literal_breaks_it
    src = "def f(x); 1 + 2 + x + 3 + 4; end; f(10)"
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    f = find_iseq(ir, "f")
    Optimize::Passes::ConstFoldPass.new.apply(f, type_env: nil, log: Optimize::Log.new, object_table: ot)
    # The literal-only prefix (1+2) folds to 3, AND the literal-only
    # suffix (3+4) folds to 7 — `x` in the middle breaks the chain but
    # each sub-chain folds independently.
    values = f.instructions.filter_map { |i| Optimize::Passes::LiteralValue.read(i, object_table: ot) }
    assert_includes values, 3
    assert_includes values, 7
    loaded = RubyVM::InstructionSequence.load_from_binary(Optimize::Codec.encode(ir))
    assert_equal 20, loaded.eval # 3 + 10 + 7
  end
```

- [ ] **Step 2: Run, expect failure** if any triple-shape the step-back misses.

- [ ] **Step 3: Add an outer fixpoint loop** around the inner scan — safety net for any triple-shape the step-back misses:

```ruby
def apply(function, type_env:, log:, object_table: nil)
  _ = type_env
  return unless object_table
  insts = function.instructions
  return unless insts

  loop do
    folded_any = false
    i = 0
    while i <= insts.size - 3
      a, b, op = insts[i], insts[i + 1], insts[i + 2]
      new_inst = try_fold_triple(a, b, op, function, log, object_table)
      if new_inst
        insts[i, 3] = [new_inst]
        folded_any = true
        i = i - 1 if i.positive?
      else
        i += 1
      end
    end
    break unless folded_any
  end
end
```

- [ ] **Step 4: Run chain tests via MCP, expect pass.**

- [ ] **Step 5: Full-suite regression via MCP.** Expected: 99 runs, 0 failures.

- [ ] **Step 6: Commit**

```
jj commit -m "ConstFoldPass: chain folding via internal fixpoint"
```

(Files: `optimizer/lib/optimize/passes/const_fold_pass.rb`, `optimizer/test/passes/const_fold_pass_test.rb`.)

---

### Task 5: Skip and fold logging

**Context:** The talk uses the log as a feature: "the optimizer tells you what it folded and what it couldn't." Three reasons to cover:

- `:folded` — successful fold, one per triple replaced
- `:would_raise` — the operation would raise at runtime (div/mod by zero)
- `:non_integer_literal` — two `putobject`s where at least one holds a non-Integer/non-Boolean literal (e.g. a String) and the op is still an arith/compare op

**The `Log#skip` signature** only takes `pass:, reason:, file:, line:`. Folds are recorded through the same interface — reason `:folded` — to keep the pipeline's existing log shape. (A richer "fold detail" field can come in a follow-up; the talk's first slide just needs counts by reason.)

**Files:**
- Modify: `optimizer/lib/optimize/passes/const_fold_pass.rb`
- Modify: `optimizer/test/passes/const_fold_pass_test.rb`

- [ ] **Step 1: Add failing tests**

```ruby
  def test_logs_folded_reason_for_each_successful_fold
    src = "def f; 1 + 2 + 3; end; f"
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    log = Optimize::Log.new
    Optimize::Passes::ConstFoldPass.new.apply(find_iseq(ir, "f"), type_env: nil, log: log)
    folded_entries = log.for_pass(:const_fold).select { |e| e.reason == :folded }
    # 1+2 → 3, then 3+3 → 6 (folded triples in sequence)
    assert_operator folded_entries.size, :>=, 2
  end

  def test_logs_would_raise_for_division_by_zero
    src = "def f; 1 / 0; end"
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    f = find_iseq(ir, "f")
    before = f.instructions.map(&:opcode)
    log = Optimize::Log.new
    Optimize::Passes::ConstFoldPass.new.apply(f, type_env: nil, log: log, object_table: ot)
    # The triple is left alone.
    assert_equal before, f.instructions.map(&:opcode)
    skipped = log.for_pass(:const_fold).select { |e| e.reason == :would_raise }
    assert_operator skipped.size, :>=, 1, "expected a :would_raise skip entry"
  end

  def test_logs_non_integer_literal_when_string_operand_reaches_an_arith_op
    src = 'def f; "a" + "b"; end'
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    f = find_iseq(ir, "f")
    log = Optimize::Log.new
    Optimize::Passes::ConstFoldPass.new.apply(f, type_env: nil, log: log, object_table: ot)
    skipped = log.for_pass(:const_fold).select { |e| e.reason == :non_integer_literal }
    assert_operator skipped.size, :>=, 1
  end
```

- [ ] **Step 2: Run, expect failure.**

- [ ] **Step 3: Wire logging into `try_fold_triple`**:

```ruby
def try_fold_triple(a, b, op, function, log, object_table)
  sym = FOLDABLE_OPS[op.opcode]
  return nil unless sym
  av = LiteralValue.read(a, object_table: object_table)
  bv = LiteralValue.read(b, object_table: object_table)

  # Only fold Integer-on-Integer. A triple that LOOKS foldable but has
  # at least one non-Integer literal gets a log entry so the talk can
  # show it. A triple where one side isn't a literal at all (read → nil)
  # is silent — it's the common "variable + literal" case.
  unless av.is_a?(Integer) && bv.is_a?(Integer)
    both_literals = !av.nil? && !bv.nil?
    if both_literals
      log.skip(pass: :const_fold, reason: :non_integer_literal,
               file: function.path, line: (op.line || a.line || function.first_lineno))
    end
    return nil
  end

  result = av.public_send(sym, bv)
  log.skip(pass: :const_fold, reason: :folded,
           file: function.path, line: (op.line || a.line || function.first_lineno))
  LiteralValue.emit(result, line: a.line, object_table: object_table)
rescue StandardError
  log.skip(pass: :const_fold, reason: :would_raise,
           file: function.path, line: (op.line || a.line || function.first_lineno))
  nil
end
```

Note: `Log#skip` is the one interface we have — we reuse it for `:folded` too. If the pipeline spec later grows a distinct `Log#fold` method, this pass migrates. For now, `:folded` is just a reason tag alongside the skip reasons.

- [ ] **Step 4: Run new tests via MCP, expect pass.**

- [ ] **Step 5: Full-suite regression via MCP.** Expected: 102 runs, 0 failures.

- [ ] **Step 6: Commit**

```
jj commit -m "ConstFoldPass: log :folded, :would_raise, :non_integer_literal"
```

(Files: `optimizer/lib/optimize/passes/const_fold_pass.rb`, `optimizer/test/passes/const_fold_pass_test.rb`.)

---

### Task 6: Wire into default pipeline + corpus regression

**Context:** The pipeline currently runs `NoopPass` by default (or tests construct a pipeline explicitly). This task adds a `Pipeline.default` factory, makes `ConstFoldPass` the only default pass, and runs the full codec corpus through it to confirm no regression.

**Files:**
- Modify: `optimizer/lib/optimize/pipeline.rb`
- Modify: `optimizer/test/pipeline_test.rb`
- Create: `optimizer/test/passes/const_fold_pass_corpus_test.rb`

- [ ] **Step 1: Read current pipeline wiring**

Read `optimizer/lib/optimize/pipeline.rb` and `optimizer/test/pipeline_test.rb`. Confirm there is no existing `Pipeline.default`; this task adds it.

- [ ] **Step 2: Add a failing default-pipeline test** — `optimizer/test/pipeline_test.rb`

Append:

```ruby
  def test_default_pipeline_folds_integer_literals_in_every_function
    require "optimize/pipeline"
    require "optimize/passes/literal_value"
    ir = Optimize::Codec.decode(
      RubyVM::InstructionSequence.compile("def f; 2 + 3; end; f").to_binary
    )
    pipeline = Optimize::Pipeline.default
    pipeline.run(ir, type_env: nil)
    f = ir.children.flat_map { |c| [c, *(c.children || [])] }.find { |x| x.name == "f" }
    assert(f.instructions.any? { |i| Optimize::Passes::LiteralValue.read(i, object_table: ot) == 5 })
  end
```

- [ ] **Step 3: Add `Pipeline.default`** — `optimizer/lib/optimize/pipeline.rb`:

Add at the top of the file, inside the class body:

```ruby
require "optimize/passes/const_fold_pass"

# ... inside class Pipeline:

def self.default
  new([Passes::ConstFoldPass.new])
end
```

- [ ] **Step 4: Write the corpus regression test** — `optimizer/test/passes/const_fold_pass_corpus_test.rb`

```ruby
# frozen_string_literal: true
require "test_helper"
require "optimize/codec"
require "optimize/pipeline"

class ConstFoldPassCorpusTest < Minitest::Test
  def test_every_corpus_fixture_loads_and_runs_through_default_pipeline
    corpus = Dir[File.expand_path("../codec/corpus/*.rb", __dir__)]
    skip "no codec corpus" if corpus.empty?
    corpus.each do |path|
      src = File.read(path)
      ir = Optimize::Codec.decode(
        RubyVM::InstructionSequence.compile(src, path).to_binary
      )
      Optimize::Pipeline.default.run(ir, type_env: nil)
      bin = Optimize::Codec.encode(ir)
      loaded = RubyVM::InstructionSequence.load_from_binary(bin)
      assert_kind_of RubyVM::InstructionSequence, loaded,
        "#{File.basename(path)} did not re-load after the default pipeline"
    end
  end
end
```

- [ ] **Step 5: Run both tests via MCP, expect pass.**

Run: `mcp__ruby-bytecode__run_optimizer_tests` with `test_filter: "test/pipeline_test.rb test/passes/const_fold_pass_corpus_test.rb"`.

- [ ] **Step 6: Full-suite regression via MCP.** Expected: 104 runs, 0 failures.

If any corpus fixture fails: the fold is producing a shape the codec can't re-emit. Bisect by disabling the pass on that fixture and see whether the raw codec path still works; if so, the bug is in `LiteralValue.emit`'s operand form.

- [ ] **Step 7: Commit**

```
jj commit -m "Wire ConstFoldPass into default pipeline + corpus regression test"
```

(Files: `optimizer/lib/optimize/pipeline.rb`, `optimizer/test/pipeline_test.rb`, `optimizer/test/passes/const_fold_pass_corpus_test.rb`.)

---

### Task 7: Benchmark demo + README update

**Context:** One benchmark case via `mcp__ruby-bytecode__benchmark_ips` that documents the win (folded vs. unfolded), and a README line noting that `ConstFoldPass` (tier 1) is available.

**Files:**
- Modify: `optimizer/README.md`

- [ ] **Step 1: Read current README.**

- [ ] **Step 2: Add a "Passes" section** (or update an existing one). One paragraph:

```
## Passes

- `Optimize::Passes::ConstFoldPass` — tier 1 constant folding. Folds
  Integer literal arithmetic (`+ - * / %`) and Integer literal
  comparison (`< <= > >= == !=`) triples within a basic block,
  iterating until no more folds fire. Division/modulo by zero and
  non-Integer literal operands are left alone and logged
  (`:would_raise`, `:non_integer_literal`). The default pipeline runs
  `ConstFoldPass` only; inlining, arithmetic specialization, and
  higher tiers of const-fold are future plans.
```

- [ ] **Step 3: Run one benchmark to quantify the fold.**

Run `mcp__ruby-bytecode__benchmark_ips` with this script. It defines two methods by source and compares the call cost:

```ruby
def unfolded; 1 + 2 + 3 + 4 + 5; end
def folded;   15; end

Benchmark.ips do |x|
  x.report("unfolded") { unfolded }
  x.report("folded")   { folded }
  x.compare!
end
```

This compares what the VM does with an un-optimized chain vs. the shape our pass produces. Record the winner and ratio in the commit message.

- [ ] **Step 4: Commit**

```
jj commit -m "Document ConstFoldPass in README; record benchmark baseline"
```

(Files: `optimizer/README.md`.)

---

## Self-review

**Spec coverage** (from `2026-04-20-pass-const-fold-tier1.md`):

- "Within a single basic block, a foldable triple is [...]" — Task 2 (arith), Task 3 (compare). A linear scan over `function.instructions` cannot produce a triple that straddles a basic-block boundary in any realistic shape (the middle instruction would have to be a branch target *and* a literal producer *and* the last instruction an arith op — structurally impossible). The behavior matches a CFG-based scan with less ceremony.
- Literal detection covering `putobject_INT2FIX_0_`/`_1_` and plain `putobject` — Task 1.
- Iterative internal fixpoint — Task 4.
- `:would_raise`, `:non_integer_literal` skip logging — Task 5.
- `:folded` logging — Task 5.
- Line annotation inheritance from first removed instruction — Task 2 (`LiteralValue.emit(result, line: a.line, object_table: object_table)`).
- Pipeline placement as last/only default pass — Task 6.
- Codec interaction (dangling refs, stack_max, iseq_size handled by codec) — no pass-side work required.
- Corpus regression — Task 6.
- Benchmark demo — Task 7.

Gaps: none.

**Placeholder scan:** one explicit spike — the operand-encoding investigation in Task 1, Step 3. Resolution is scripted (read the failing test output, inspect the operand, write the right code). The "If the investigation reveals [...]" escalation condition names the exact observable (the `42` emit test) that would trigger it. No other TBDs survive.

**Type consistency:** `LiteralValue.read`/`.emit` signatures match across Tasks 1–4. `FOLDABLE_OPS` (Task 3) replaces `ARITH_OPS` (Task 2) in one place with matching call sites. `Log#skip` is the sole log interface used. `try_fold_triple` is named consistently from Task 3 onward.

**Known unknown:** the operand encoding for plain `putobject` with integers > 1. Surfaced and resolved in Task 1.

**Gaps for follow-up plans:** String / Array / Kernel tier 1 shapes, tier 2 (frozen constants), tier 3 (type-guided), tier 4 (ENV) — each its own plan. Cross-block constant propagation — out of scope.
