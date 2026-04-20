# Codec Length-Changing Edits Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend the codec so passes can insert or delete instructions — not just substitute same-size ones — by re-serializing the iseq body from IR with correctly recomputed section offsets, catch table, line info, arg-position tables, and stack depth.

**Architecture:** Move every section of the iseq body that contains instruction-position references (catch table, insns_info, opt_table, keyword defaults) from raw bytes in `misc[:raw_body]` into decoded IR fields whose references are to `IR::Instruction` objects by identity. On encode, resolve identity back to the current index. Replace `IseqEnvelope.encode`'s verbatim-body path with a full re-serialization that lays out the data region from IR and emits the body record with computed offsets.

**Tech Stack:** Ruby 4.0.2, minitest, the existing `ruby-bytecode` MCP for in-container test runs.

**Scope bounds:** Enough to support any length-changing edit a pass might perform. Inlining can now work; so can the literal/reassoc branches of const-fold and arith specialization. Stack-depth recomputation is a conservative upper bound via symbolic execution — tight enough to be accepted by `load_from_binary`, not necessarily minimal.

**Commit discipline:** Every commit step is written as `jj commit -m "<msg>"` for readability. Executors MUST translate this to `jj split -m "<msg>" -- <files>` using the exact file list from the task's Files section. Run tests via `mcp__ruby-bytecode__run_optimizer_tests`, never host bash.

---

## File structure

```
optimizer/
  lib/
    ruby_opt/
      ir/
        function.rb            # MODIFIED (catch_entries, line_entries, arg_positions, stack_max fields)
        catch_entry.rb         # NEW Task 1
        line_entry.rb          # NEW Task 2
      codec/
        iseq_envelope.rb       # MODIFIED Tasks 1–5
        catch_table.rb         # NEW Task 1 (decode/encode)
        line_info.rb           # NEW Task 2
        arg_positions.rb       # NEW Task 3
        stack_max.rb           # NEW Task 4
        iseq_list.rb           # MODIFIED Task 5 (drop raw data region path)
      codec.rb                 # MODIFIED Task 6 (remove EncoderSizeChange)
  test/
    codec/
      catch_table_test.rb            # NEW Task 1
      line_info_test.rb              # NEW Task 2
      arg_positions_test.rb          # NEW Task 3
      stack_max_test.rb              # NEW Task 4
      length_change_test.rb          # NEW Task 6
```

---

### Task 1: Catch table — decode into IR, re-encode from IR

**Files:**
- Create: `optimizer/lib/ruby_opt/ir/catch_entry.rb`
- Create: `optimizer/lib/ruby_opt/codec/catch_table.rb`
- Modify: `optimizer/lib/ruby_opt/codec/iseq_envelope.rb`
- Modify: `optimizer/lib/ruby_opt/ir/function.rb`
- Create: `optimizer/test/codec/catch_table_test.rb`

**Context:** The catch table records exception handlers (`rescue`, `ensure`, `retry`, `break`, `redo`, `next` targets). Each entry has a type tag, start/end/cont positions into the instruction stream, a stack depth, and (for rescue/ensure) a reference to a child iseq that runs as the handler. Positions are currently buried in `misc[:raw_body]`. To support length changes we need them in IR, referencing `IR::Instruction` objects by identity.

**Format reference:** `research/cruby/ibf-format.md` §5 has the catch table byte layout. Consult it for the per-entry fields. If the doc omits anything, inspect `compile.c` in CRuby 4.0.2 via WebFetch on `https://raw.githubusercontent.com/ruby/ruby/v4.0.2/compile.c` and update the research doc as part of this task.

- [ ] **Step 1: Write the failing test** — `optimizer/test/codec/catch_table_test.rb`

```ruby
# frozen_string_literal: true
require "test_helper"
require "ruby_opt/codec"

class CatchTableTest < Minitest::Test
  def test_rescue_method_round_trips_through_catch_entries
    src = <<~RUBY
      def safe_divide(a, b)
        a / b
      rescue ZeroDivisionError
        :nope
      end
      safe_divide(10, 2)
      safe_divide(10, 0)
    RUBY
    original = RubyVM::InstructionSequence.compile(src).to_binary
    ir = RubyOpt::Codec.decode(original)

    safe_divide = ir.children.find { |c| c.name == "safe_divide" }
    refute_nil safe_divide
    # There is at least one :rescue entry in the method's catch table
    refute_empty safe_divide.catch_entries
    rescue_entry = safe_divide.catch_entries.find { |e| e.type == :rescue }
    refute_nil rescue_entry
    # Entry references instructions by identity and the referenced
    # instructions are in the method's instruction list.
    assert_includes safe_divide.instructions, rescue_entry.start_inst
    assert_includes safe_divide.instructions, rescue_entry.end_inst

    # Byte-identical round-trip still passes.
    assert_equal original, RubyOpt::Codec.encode(ir)
  end
end
```

- [ ] **Step 2: Run via MCP, expect NoMethodError for `#catch_entries`**

Run: `mcp__ruby-bytecode__run_optimizer_tests` with `test_filter: "test/codec/catch_table_test.rb"`.

- [ ] **Step 3: Define `IR::CatchEntry`** — `optimizer/lib/ruby_opt/ir/catch_entry.rb`

```ruby
# frozen_string_literal: true

module RubyOpt
  module IR
    # One entry in a function's catch table. Positions are references
    # to IR::Instruction objects by identity, so mutations to the
    # instruction list don't invalidate them.
    #
    #   type         — one of :rescue, :ensure, :retry, :break, :redo, :next
    #   iseq_index   — index into the parent's children array for the
    #                  handler iseq (nil for entries without a handler
    #                  iseq, such as :retry)
    #   start_inst   — IR::Instruction marking the start of the covered range
    #   end_inst     — IR::Instruction marking the end (exclusive)
    #   cont_inst    — IR::Instruction where control resumes after handling
    #                  (nil for entries that transfer control elsewhere)
    #   stack_depth  — operand-stack depth at which the handler runs
    CatchEntry = Struct.new(
      :type, :iseq_index, :start_inst, :end_inst, :cont_inst, :stack_depth,
      keyword_init: true,
    )
  end
end
```

- [ ] **Step 4: Implement `Codec::CatchTable`** — `optimizer/lib/ruby_opt/codec/catch_table.rb`

```ruby
# frozen_string_literal: true
require "ruby_opt/ir/catch_entry"

module RubyOpt
  module Codec
    # Decode/encode a single iseq's catch table.
    #
    # The on-disk format uses start/end/cont positions expressed as
    # YARV-slot offsets into the instruction stream. IR expresses them
    # as IR::Instruction references. The caller provides a position <=>
    # instruction mapping since the stream's slot layout is owned by
    # InstructionStream.
    module CatchTable
      TYPE_TO_SYM = {
        1 => :rescue, 2 => :ensure, 3 => :retry,
        4 => :break, 5 => :redo, 6 => :next,
      }.freeze
      SYM_TO_TYPE = TYPE_TO_SYM.invert.freeze

      module_function

      # @param reader [BinaryReader] positioned at the start of the catch table
      # @param count  [Integer] number of entries
      # @param slot_to_inst [Hash{Integer=>IR::Instruction}] map from YARV-slot
      #         position to the instruction at that slot
      # @return [Array<IR::CatchEntry>]
      def decode(reader, count, slot_to_inst)
        Array.new(count) do
          type_num = reader.read_small_value
          iseq_index = reader.read_small_value
          iseq_index = nil if iseq_index == 0xFFFFFFFF
          start_pos = reader.read_small_value
          end_pos   = reader.read_small_value
          cont_pos  = reader.read_small_value
          stack_depth = reader.read_small_value

          IR::CatchEntry.new(
            type: TYPE_TO_SYM.fetch(type_num) {
              raise MalformedBinary, "unknown catch type #{type_num}"
            },
            iseq_index: iseq_index,
            start_inst: slot_to_inst[start_pos] or raise_pos_error("start", start_pos),
            end_inst:   slot_to_inst[end_pos] or raise_pos_error("end", end_pos),
            cont_inst:  cont_pos.zero? ? nil : (slot_to_inst[cont_pos] or raise_pos_error("cont", cont_pos)),
            stack_depth: stack_depth,
          )
        end
      end

      # @param writer [BinaryWriter]
      # @param entries [Array<IR::CatchEntry>]
      # @param inst_to_slot [Hash{IR::Instruction=>Integer}] reverse map
      def encode(writer, entries, inst_to_slot)
        entries.each do |e|
          writer.write_small_value(SYM_TO_TYPE.fetch(e.type))
          writer.write_small_value(e.iseq_index || 0xFFFFFFFF)
          writer.write_small_value(inst_to_slot.fetch(e.start_inst))
          writer.write_small_value(inst_to_slot.fetch(e.end_inst))
          writer.write_small_value(e.cont_inst.nil? ? 0 : inst_to_slot.fetch(e.cont_inst))
          writer.write_small_value(e.stack_depth)
        end
      end

      def raise_pos_error(which, pos)
        raise MalformedBinary, "catch table #{which} position #{pos} does not align with any instruction"
      end
    end
  end
end
```

- [ ] **Step 5: Wire it into `IseqEnvelope.decode` / `encode`**

Read `optimizer/lib/ruby_opt/codec/iseq_envelope.rb`. After decoding the instructions (which produces `instructions` array + a `slot_to_inst` mapping derived from `InstructionStream.decode`'s per-instruction slot-offset table), call `CatchTable.decode` using the catch table offset + count from the body record. Store the result in `function.catch_entries` — add this as a new field on `IR::Function`.

On encode, before writing the body record, call `CatchTable.encode` to produce the catch table bytes (using `inst_to_slot` derived from the current instructions). Position it in the new data region layout (see Task 5 for that integration; for now, just emit into the existing raw data region path).

Note: `InstructionStream.decode` probably doesn't currently expose a `slot_to_inst` map — you'll need to either make it return one (cleanest) or reconstruct it from the decoded instructions by computing each instruction's slot size. Prefer exposing it from `InstructionStream.decode` as an additional return value (or a small struct).

- [ ] **Step 6: Add `catch_entries` field to `IR::Function`**

Modify `optimizer/lib/ruby_opt/ir/function.rb` — add `:catch_entries` to the Struct members (keyword_init). Default to `nil` in decode paths that don't yet populate it (forward-compat).

- [ ] **Step 7: Run tests via MCP**

Full suite: `mcp__ruby-bytecode__run_optimizer_tests` (no filter). Expected: all 68 existing tests pass + 1 new = 69, 0 failures.

If a previously-passing corpus test fails (`rescue_block.rb`, for instance), the encode/decode is not yet symmetric. Iterate until it is.

- [ ] **Step 8: Commit**

```
jj commit -m "Decode/encode catch table via IR"
```

(Files: every file listed at the top of this task that you actually touched.)

---

### Task 2: Line info (insns_info) — decode into IR, re-encode from IR

**Files:**
- Create: `optimizer/lib/ruby_opt/ir/line_entry.rb`
- Create: `optimizer/lib/ruby_opt/codec/line_info.rb`
- Modify: `optimizer/lib/ruby_opt/codec/iseq_envelope.rb`
- Modify: `optimizer/lib/ruby_opt/ir/function.rb`
- Create: `optimizer/test/codec/line_info_test.rb`

**Context:** `insns_info` is an array of entries that map instruction positions to (line_no, node_id, event_flags). `IR::Instruction` already carries a `:line` field populated on decode. This task elevates the full entry form into IR so we can re-serialize after instruction-count changes.

**Format reference:** `research/cruby/ibf-format.md` §5 — "insns_info" subsection. CRuby writes these in a delta-compressed form; we need to decode to full (position, line, node_id, events) tuples and re-encode with fresh deltas at encode time.

- [ ] **Step 1: Write the failing test** — `optimizer/test/codec/line_info_test.rb`

```ruby
# frozen_string_literal: true
require "test_helper"
require "ruby_opt/codec"

class LineInfoTest < Minitest::Test
  def test_multiline_method_has_line_entries_per_instruction_group
    src = <<~RUBY
      def multi
        x = 1
        y = 2
        x + y
      end
      multi
    RUBY
    original = RubyVM::InstructionSequence.compile(src).to_binary
    ir = RubyOpt::Codec.decode(original)

    m = ir.children.find { |c| c.name == "multi" }
    refute_nil m
    refute_empty m.line_entries
    # Every entry references an instruction in the method
    m.line_entries.each do |e|
      assert_includes m.instructions, e.inst, "line entry points at a non-member instruction"
    end
    # At least 3 distinct source lines appear (the 3 statements)
    assert_operator m.line_entries.map(&:line_no).uniq.size, :>=, 3

    # Byte-identical round-trip
    assert_equal original, RubyOpt::Codec.encode(ir)
  end
end
```

- [ ] **Step 2: Run, expect NoMethodError for `#line_entries`.**

- [ ] **Step 3: Define `IR::LineEntry`** — `optimizer/lib/ruby_opt/ir/line_entry.rb`

```ruby
# frozen_string_literal: true

module RubyOpt
  module IR
    # One entry in an iseq's line-info table.
    #
    #   inst     — the IR::Instruction this entry annotates
    #   line_no  — source line number (1-based)
    #   node_id  — parser node id (opaque integer; preserved on round-trip)
    #   events   — flags bitmap for tracepoint events (RUBY_EVENT_LINE, etc.)
    LineEntry = Struct.new(:inst, :line_no, :node_id, :events, keyword_init: true)
  end
end
```

- [ ] **Step 4: Implement `Codec::LineInfo`** — `optimizer/lib/ruby_opt/codec/line_info.rb`

Implement `LineInfo.decode(reader, size, slot_to_inst)` and `LineInfo.encode(writer, entries, inst_to_slot)` following the delta-compressed format in the IBF reference. The entries returned from decode are `IR::LineEntry` structs.

```ruby
# frozen_string_literal: true
require "ruby_opt/ir/line_entry"

module RubyOpt
  module Codec
    # Decode/encode an iseq's insns_info table. On-disk the format is
    # delta-compressed (successive position deltas + run-length encoded
    # line numbers); we decode to a flat list of LineEntry and re-encode
    # the deltas on write.
    module LineInfo
      module_function

      # @param reader [BinaryReader] positioned at insns_info
      # @param size   [Integer] number of entries in the table
      # @param slot_to_inst [Hash{Integer=>IR::Instruction}]
      # @return [Array<IR::LineEntry>]
      def decode(reader, size, slot_to_inst)
        # Refer to research/cruby/ibf-format.md §5. The encoding uses
        # ibf_dump_line_info / ibf_load_line_info; both consist of
        # small_value-encoded deltas. Walk `size` times, accumulating
        # position and line_no, and emit one LineEntry per entry.
        entries = []
        pos = 0
        line = 0
        size.times do
          pos_delta = reader.read_small_value
          line_delta = reader.read_small_value_signed
          node_id = reader.read_small_value
          events = reader.read_small_value

          pos += pos_delta
          line += line_delta
          inst = slot_to_inst[pos] or raise MalformedBinary,
            "line_info position #{pos} does not align with any instruction"

          entries << IR::LineEntry.new(
            inst: inst,
            line_no: line,
            node_id: node_id,
            events: events,
          )
        end
        entries
      end

      def encode(writer, entries, inst_to_slot)
        prev_pos = 0
        prev_line = 0
        entries.each do |e|
          pos = inst_to_slot.fetch(e.inst)
          writer.write_small_value(pos - prev_pos)
          writer.write_small_value_signed(e.line_no - prev_line)
          writer.write_small_value(e.node_id)
          writer.write_small_value(e.events)
          prev_pos = pos
          prev_line = e.line_no
        end
      end
    end
  end
end
```

Note the signed-small-value helpers `read_small_value_signed` / `write_small_value_signed`. If they don't exist in `BinaryReader`/`BinaryWriter`, add them as part of this task — signed small-value is zigzag encoded, matching CRuby's convention.

- [ ] **Step 5: Wire into `IseqEnvelope.decode`/`encode`** — populate `function.line_entries` on decode; call `LineInfo.encode` on encode.

- [ ] **Step 6: Add `line_entries` to `IR::Function`** (Struct member).

- [ ] **Step 7: Run tests via MCP.** Expected: 70 runs, 0 failures.

If the exact delta encoding my sketch shows differs from what CRuby uses, the round-trip bytes will mismatch. Inspect the original bytes vs the re-encoded bytes for one failing iseq to diagnose; update `LineInfo` until round-trip is identity.

- [ ] **Step 8: Commit**

```
jj commit -m "Decode/encode line info (insns_info) via IR"
```

---

### Task 3: Arg positions (opt_table + keyword defaults) — decode + re-encode from IR

**Files:**
- Create: `optimizer/lib/ruby_opt/codec/arg_positions.rb`
- Modify: `optimizer/lib/ruby_opt/codec/iseq_envelope.rb`
- Modify: `optimizer/lib/ruby_opt/ir/function.rb`
- Create: `optimizer/test/codec/arg_positions_test.rb`

**Context:** Methods with optional arguments or keyword arguments carry two position tables. `opt_table` is an array of YARV slot positions, one per optional arg, pointing to the first instruction of that arg's default-value code. `keyword.default_values` similarly points at keyword-default evaluation. Both shift when the instruction stream resizes, so both must live in IR as `IR::Instruction` references.

Today these live as raw bytes inside the body record (see `misc[:arg_spec]` which was extracted in Task 7 of the codec plan). We'll decode them into typed `IR::Function#arg_positions` — an Array<IR::Instruction> for `opt_table`, plus a typed struct for keyword defaults.

- [ ] **Step 1: Write the failing test** — `optimizer/test/codec/arg_positions_test.rb`

```ruby
# frozen_string_literal: true
require "test_helper"
require "ruby_opt/codec"

class ArgPositionsTest < Minitest::Test
  def test_method_with_optional_args_round_trips_opt_table
    src = <<~RUBY
      def f(a, b = 10, c = 20)
        a + b + c
      end
      f(1)
      f(1, 2, 3)
    RUBY
    original = RubyVM::InstructionSequence.compile(src).to_binary
    ir = RubyOpt::Codec.decode(original)

    f = ir.children.find { |c| c.name == "f" }
    refute_nil f
    refute_empty f.arg_positions.opt_table
    f.arg_positions.opt_table.each do |inst|
      assert_includes f.instructions, inst,
        "opt_table entry does not reference a method instruction"
    end

    assert_equal original, RubyOpt::Codec.encode(ir)
  end

  def test_method_with_keyword_args_round_trips
    src = <<~RUBY
      def g(name:, greeting: "hi")
        "#{greeting} #{name}"
      end
      g(name: "x")
    RUBY
    original = RubyVM::InstructionSequence.compile(src).to_binary
    ir = RubyOpt::Codec.decode(original)
    assert_equal original, RubyOpt::Codec.encode(ir)
  end
end
```

- [ ] **Step 2: Run, expect NoMethodError for `#arg_positions`.**

- [ ] **Step 3: Implement `Codec::ArgPositions`** with `decode` and `encode` helpers that take `slot_to_inst` / `inst_to_slot` maps. Define a small IR struct (in `ir/function.rb` or a sibling file) that holds `opt_table` (Array<IR::Instruction>) and `keyword_defaults` (Array<IR::Instruction>, or nil when there are no keyword args).

Use the same pattern as Tasks 1 and 2. The format reference is `research/cruby/ibf-format.md` §5 (arg_spec sub-layout, specifically `param.opt_table` and `param.keyword`).

- [ ] **Step 4: Wire into `IseqEnvelope.decode`/`encode`** to populate and re-emit the field.

- [ ] **Step 5: Run tests via MCP.** Expected: 72 runs, 0 failures.

- [ ] **Step 6: Commit**

```
jj commit -m "Decode/encode arg positions (opt_table + keyword defaults) via IR"
```

---

### Task 4: Stack-max recomputation

**Files:**
- Create: `optimizer/lib/ruby_opt/codec/stack_max.rb`
- Modify: `optimizer/lib/ruby_opt/codec/iseq_envelope.rb`
- Create: `optimizer/test/codec/stack_max_test.rb`

**Context:** Every iseq has a `stack_max` field in its body record — the high-water mark of the operand stack during execution. MRI's `load_from_binary` uses this to preallocate frame slots and rejects the iseq if the stored value is too low. After length-changing edits, the correct `stack_max` may differ.

We recompute it via symbolic execution: walk the instruction list tracking depth changes per opcode. YARV's `insns.def` declares each opcode's `[num_pop, num_push]` (sometimes variable). For variable cases (e.g. `send` instructions where arg count is in the call info), treat them conservatively by reading the stashed info — all relevant metadata (calldata argc, array size for `newarray`, etc.) is available on the `IR::Instruction#operands`.

For this task, implement a conservative upper-bound: model the ops used in the corpus accurately, and for unknown-depth ops use the maximum plausible delta the opcode could produce (`0 → +N` for variadic pushes). Over-allocating is safe; under-allocating breaks load_from_binary.

- [ ] **Step 1: Write the failing test** — `optimizer/test/codec/stack_max_test.rb`

```ruby
# frozen_string_literal: true
require "test_helper"
require "ruby_opt/codec"
require "ruby_opt/codec/stack_max"

class StackMaxTest < Minitest::Test
  def test_matches_or_exceeds_ruby_computed_value
    # For every corpus fixture, our computed stack_max must be >=
    # the value Ruby assigned at compile time.
    Dir[File.expand_path("corpus/*.rb", __dir__)].each do |path|
      src = File.read(path)
      ir = RubyOpt::Codec.decode(
        RubyVM::InstructionSequence.compile(src, path).to_binary
      )
      walk_ir(ir) do |function|
        original = function.misc[:stack_max] || 0
        computed = RubyOpt::Codec::StackMax.compute(function)
        assert_operator computed, :>=, original,
          "#{path} / #{function.name}: computed #{computed} < ruby's #{original}"
      end
    end
  end

  private

  def walk_ir(ir, &block)
    yield ir if ir.instructions
    ir.children&.each { |c| walk_ir(c, &block) }
  end
end
```

- [ ] **Step 2: Run, expect LoadError.**

- [ ] **Step 3: Implement `Codec::StackMax`** with a per-opcode delta table + a walker:

```ruby
# frozen_string_literal: true

module RubyOpt
  module Codec
    module StackMax
      # Map opcode symbol -> [pop_count, push_count] or a lambda
      # (instruction) -> [pop, push] for variadic opcodes.
      DELTA = {
        # ...populated from insns.def for Ruby 4.0.2 / empirical inspection
      }.freeze

      module_function

      # @param function [IR::Function]
      # @return [Integer] the high-water stack depth
      def compute(function)
        max = 0
        depth = 0
        (function.instructions || []).each do |ins|
          pop, push = delta_for(ins)
          depth -= pop
          depth = 0 if depth.negative? # conservative
          depth += push
          max = depth if depth > max
        end
        max
      end

      def delta_for(ins)
        entry = DELTA[ins.opcode]
        case entry
        when Array then entry
        when Proc then entry.call(ins)
        else
          # Unknown opcode — be conservative: pop 0, push 1.
          [0, 1]
        end
      end
    end
  end
end
```

Populate `DELTA` using the same information that builds `InstructionStream::INSN_TABLE`. You can borrow from YJIT's stackmap tables or CRuby's `insns.def` (the `sp_inc` / attr `sp_inc` lines). For `send`-family ops, use the calldata's argc + 1 (receiver).

- [ ] **Step 4: Wire into `IseqEnvelope.encode`** — when emitting the body record, use `StackMax.compute(function)` for the stack_max field instead of `function.misc[:stack_max]`. Store `:stack_max` in misc during decode for the test above to compare.

- [ ] **Step 5: Run tests via MCP.** Expected: 73 runs, 0 failures.

The first run will likely surface missing opcodes. Add them to DELTA until the stack_max test passes for every corpus fixture.

- [ ] **Step 6: Commit**

```
jj commit -m "Recompute stack_max from IR via symbolic execution"
```

---

### Task 5: Full body-record re-serialization from IR

> **⚠️ Lessons from a failed first attempt (2026-04-20):** The original Task 5 prompt asked for one monolithic rewrite — replacing `codec.rb` orchestration, `iseq_list.rb` per-section emission, and `IseqEnvelope.encode`'s signature all at once. The result was non-debuggable:
>
> - Round-trip fell 12 bytes short on the simplest corpus fixture (`[1,2,3].map { |n| n*2 }`). No test localized which section drifted.
> - `LineInfo.encode` raised `KeyError` when an instruction referenced by a line entry had been removed from `function.instructions` (encoder must filter dangling entries first — the original plan didn't say so).
> - `load_from_binary` raised "unexpected path object" on the modification test, meaning a body-record offset field pointed at the wrong section (field-ordering bug).
> - One fixture SIGSEGV'd Ruby itself in `ibf_load_iseq_each` — a wrong offset or size field let the loader dereference garbage.
>
> Abandoned as `vvpqumlr`. 73/73 tests remain green at the Task 4 baseline.
>
> **The fix: split Task 5 into 5a–5d, each with a tight byte-diff assertion so the single thing that broke is always visible.** Execute them in order; do not skip ahead.

**Files (across 5a–5d):**
- Modify: `optimizer/lib/ruby_opt/codec/iseq_envelope.rb`
- Modify: `optimizer/lib/ruby_opt/codec/iseq_list.rb`
- Modify: `optimizer/lib/ruby_opt/codec/line_info.rb` (filter dangling refs in 5d)
- Modify: `optimizer/lib/ruby_opt/codec/catch_table.rb` (filter dangling refs in 5d)

---

#### Task 5a: `data_region_offsets` parameter, same behavior

Introduce a `data_region_offsets` hash parameter into `IseqEnvelope.encode`. For this task:

- `IseqList.encode` populates `data_region_offsets` with the ORIGINAL absolute offsets from decode-time `misc` (bytecode_abs, catch_table_abs, etc.) — no layout changes.
- `IseqEnvelope.encode` still writes `misc[:raw_body]` verbatim, UNCHANGED.
- Inside `IseqEnvelope.encode`, before the raw-body write, add assertions: re-read each of the 45 small_values from the raw body, resolve each relative-offset field back to an absolute, and assert it equals the corresponding value in `data_region_offsets`. If any mismatch, raise with a clear message naming the field (`"body-record offset drift: field=insns_body_rel stored_rel=X resolved_abs=Y data_region_abs=Z"`).

This is the TDD setup: if a later task accidentally passes wrong offsets, the assertion fires with a targeted message.

End state: 73 tests still pass, 0 new tests.

Commit: `jj commit -m "Thread data_region_offsets through IseqEnvelope.encode (assertion-only)"`.

#### Task 5b: IR-driven body record emission (keeping original data region layout)

Switch `IseqEnvelope.encode` from `writer.write_bytes(misc[:raw_body])` to emitting each of the 45 small_values from IR fields + `data_region_offsets`. `IseqList.encode` is unchanged — it still writes `@raw_iseq_region` verbatim. (The offsets passed in will match the raw region because nothing has moved.)

Contract: byte-identical round-trip on the corpus. If any single field's re-emission differs from what was in `misc[:raw_body]`, a fixture will fail; diff the two body records field-by-field to isolate which one.

Pay special attention to:
- `iseq_size`: for unmodified IR, `InstructionStream.slots_for`-summed value must equal `misc[:iseq_size]`. Use `misc[:iseq_size]` directly for now; 5d switches to recomputed.
- `stack_max`: use `misc[:stack_max]` unchanged; 5d switches to `Codec::StackMax.compute`.
- Field order: the decoder's read sequence is authoritative. Mirror it literally; don't reorder.

End state: 73 tests still pass.

Commit: `jj commit -m "Emit iseq body record from IR fields"`.

#### Task 5c: Per-section data region emission, one section per sub-commit

Replace `IseqList.encode`'s `@raw_iseq_region` emission with per-section writes from IR. Do this **one section per sub-commit** with the corpus round-trip test re-run after each:

- 5c.i: Bytecode — `InstructionStream.encode(fn.instructions, object_table, functions)` at `writer.pos`. Record new `bytecode_abs`/`bytecode_size` into `data_region_offsets`.
- 5c.ii: opt_table — 8-byte (VALUE) alignment pad before; emit via `ArgPositions.encode`.
- 5c.iii: kw raw bytes at new offset.
- 5c.iv: insns_info body + positions via `LineInfo.encode`.
- 5c.v: local_table raw bytes.
- 5c.vi: lvar_states raw bytes.
- 5c.vii: catch_table via `CatchTable.encode`.
- 5c.viii: ci_entries raw bytes.
- 5c.ix: outer_vars raw bytes.

After each sub-step, the full corpus round-trip test must still pass byte-for-byte. A failure means only that section's emission is suspect.

**Critical alignment rules (rediscovered the hard way):**
- 4-byte alignment padding is required BEFORE the iseq offset array (per `research/cruby/ibf-format.md` §7).
- 8-byte (VALUE) alignment is required BEFORE `opt_table`.
- If a fixture's round-trip falls 4 or 8 bytes short after any sub-step, alignment is likely the cause — inspect the two byte streams at the boundary.

**Do NOT modify `codec.rb`'s top-level encode orchestration here.** The `Header.encode` → `IseqList.encode` → `ObjectTable.encode` sequence stays as-is. Only `IseqList.encode`'s internal layout changes.

Commit each sub-step separately so any regression can be bisected to a single section.

#### Task 5d: Filter dangling refs + switch to recomputed fields

Now that the encoder is fully IR-driven, handle length-changing edits cleanly:

- `LineInfo.encode`: filter out `LineEntry`s whose `inst` is no longer in the instruction list (reference comparison via `inst_to_slot.key?`). Add a test: decode, `function.instructions.pop` an instruction with a line entry, re-encode without raising `KeyError`.
- `CatchTable.encode`: similarly filter entries whose `start_inst`/`end_inst`/`cont_inst` are missing.
- Switch the body record's `stack_max` from `misc[:stack_max]` to `Codec::StackMax.compute(function)` — add a corpus-wide assertion that the computed value ≥ stored value (the stack_max test from Task 4 already covers this, but run it).
- Switch `iseq_size` to the recomputed value from `InstructionStream.slots_for` — assert this matches the stored value for unmodified IR across the corpus.

After 5d: length-changing edits are supported end-to-end. Task 6's delete/insert integration tests become possible.

Commit: `jj commit -m "Filter dangling IR refs and switch to recomputed stack_max/iseq_size"`.

---

The remaining steps below are preserved from the original monolithic plan; Task 5's sub-steps above supersede them. If you're executing this plan, follow 5a–5d and skip the steps below.

- [ ] **Step 1: Add failing tests** to `optimizer/test/codec/length_change_test.rb` (this file is created here, expanded in Task 6):

```ruby
# frozen_string_literal: true
require "test_helper"
require "ruby_opt/codec"
require "ruby_opt/ir/instruction"

class LengthChangePreambleTest < Minitest::Test
  # Every corpus fixture still round-trips byte-identically under the
  # new IR-driven encoder.
  def test_corpus_round_trips_under_ir_driven_encoder
    Dir[File.expand_path("corpus/*.rb", __dir__)].each do |path|
      src = File.read(path)
      original = RubyVM::InstructionSequence.compile(src, path).to_binary
      ir = RubyOpt::Codec.decode(original)
      re_encoded = RubyOpt::Codec.encode(ir)
      assert_equal original, re_encoded, "mismatch for #{File.basename(path)}"
    end
  end
end
```

- [ ] **Step 2: Replace `IseqEnvelope.encode`** with an IR-driven implementation.

Read the current `encode` end-to-end. The output it produces is the body record bytes (41 small_values). Rewrite it to:

1. Accept (in addition to `writer, function`) a `data_region_offsets` hash populated by `IseqList.encode` — containing the absolute offsets where each of this iseq's sections were placed.
2. Pull every field from `function`:
   - name, path, absolute_path, first_lineno, type → already decoded
   - arg_spec fields → from `function.arg_spec` (existing) and `function.arg_positions` (Task 3)
   - bytecode_abs, bytecode_size → from `data_region_offsets[:bytecode]`
   - catch_table_abs, catch_table_size → from region
   - line_info (insns_info) offset + size → from region
   - local_table → from raw in misc (unchanged)
   - opt_table, kw → from region
   - stack_max → `Codec::StackMax.compute(function)`
3. Write them as small_values in the exact order the decoder expects.

- [ ] **Step 3: Replace `IseqList.encode`'s data-region emission** with per-section layout:

```ruby
# Pseudo-code sketch
def encode_iseq_data_region(writer, functions, object_table)
  region_offsets = {} # fn -> { bytecode: abs, catch_table: abs, ... }
  functions.each do |fn|
    o = {}
    # Instructions
    o[:bytecode] = writer.pos
    inst_bytes = InstructionStream.encode(fn.instructions, object_table, functions)
    writer.write_bytes(inst_bytes)
    o[:bytecode_size] = inst_bytes.bytesize

    # Inst-to-slot / slot-to-inst maps for other sections
    inst_to_slot = InstructionStream.slot_map(fn.instructions)

    # Catch table
    o[:catch_table] = writer.pos
    CatchTable.encode(writer, fn.catch_entries || [], inst_to_slot)
    o[:catch_table_size] = writer.pos - o[:catch_table]

    # Line info
    o[:line_info] = writer.pos
    LineInfo.encode(writer, fn.line_entries || [], inst_to_slot)
    o[:line_info_size] = fn.line_entries&.size || 0

    # Local table (raw from misc — no inst refs)
    o[:local_table] = writer.pos
    writer.write_bytes(fn.misc[:local_table_raw] || "")
    o[:local_table_size] = (fn.misc[:local_table_raw]&.bytesize) || 0

    # ...similarly for lvar_states, opt_table, kw, ci_entries, outer_vars

    region_offsets[fn] = o
  end
  region_offsets
end
```

Then emit each iseq's body record using the collected offsets, replacing the current verbatim-body write.

This is the largest integration step in the plan. Work iteratively: get the bytecode region right first (existing behavior), then add catch, then line, then local, etc. Run the corpus round-trip test after each addition.

- [ ] **Step 4: Run full suite via MCP.** Expected: 74 runs (includes the preamble test), 0 failures. Any fixture that now mismatches means a section emission is off; isolate and fix.

- [ ] **Step 5: Commit**

```
jj commit -m "Emit iseq body and data region from IR"
```

---

### Task 6: Remove `EncoderSizeChange` + length-change integration tests

**Files:**
- Modify: `optimizer/lib/ruby_opt/codec.rb`
- Modify: `optimizer/lib/ruby_opt/codec/iseq_list.rb` (or wherever the constraint currently lives)
- Modify: `optimizer/test/codec/length_change_test.rb`

- [ ] **Step 1: Expand `optimizer/test/codec/length_change_test.rb`** with real length-change cases:

```ruby
class LengthChangeTest < Minitest::Test
  def test_deleting_an_instruction_re_encodes_to_a_loadable_iseq
    src = "def f; x = 1; x + 2; end; f"
    ir = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    f = ir.children.find { |c| c.name == "f" }
    # Remove the `setlocal` for x — we keep the value on the stack
    # and rely on the + to consume it. This is a deliberately-minimal
    # mutation; the test only cares that the encoder can produce a
    # runnable iseq from an instruction list shorter than the original.
    setlocal_idx = f.instructions.index { |i| i.opcode.to_s.start_with?("setlocal") }
    skip "no setlocal in test fixture" unless setlocal_idx
    f.instructions.delete_at(setlocal_idx)

    modified = RubyOpt::Codec.encode(ir)
    loaded = RubyVM::InstructionSequence.load_from_binary(modified)
    assert_kind_of RubyVM::InstructionSequence, loaded
  end

  def test_inserting_a_nop_extends_the_iseq
    src = "def f; 1 + 2; end; f"
    ir = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    f = ir.children.find { |c| c.name == "f" }
    f.instructions.unshift(
      RubyOpt::IR::Instruction.new(opcode: :nop, operands: [], line: f.instructions.first.line)
    )
    modified = RubyOpt::Codec.encode(ir)
    loaded = RubyVM::InstructionSequence.load_from_binary(modified)
    # Calling the outer iseq should still produce 3
    assert_equal 3, loaded.eval
  end

  def test_round_trip_is_byte_identical_on_unmodified_ir
    Dir[File.expand_path("corpus/*.rb", __dir__)].each do |path|
      src = File.read(path)
      original = RubyVM::InstructionSequence.compile(src, path).to_binary
      ir = RubyOpt::Codec.decode(original)
      assert_equal original, RubyOpt::Codec.encode(ir), "mismatch for #{File.basename(path)}"
    end
  end
end
```

Remove the preamble test from Task 5 (it's superseded by `test_round_trip_is_byte_identical_on_unmodified_ir`).

- [ ] **Step 2: Remove the `EncoderSizeChange` constraint.**

In `optimizer/lib/ruby_opt/codec/iseq_list.rb` (or wherever the constraint was added in Plan 1b Task 1), remove the length-comparison + raise. Keep the exception class defined in `codec.rb` for a deprecation cycle — mark it with a comment:

```ruby
# Kept for backwards-compatibility with callers that rescue it. The
# encoder now supports length changes; this exception is never raised
# by code in this repo.
class EncoderSizeChange < StandardError; end
```

Also: Plan 1b Task 1 added a test (`test_length_change_raises_encoder_size_change` in `encode_modifications_test.rb`) that asserts the raise happens. Delete that test in this task — the new behavior is "length changes are supported, so the raise is gone." Note the deletion in your commit message.

- [ ] **Step 3: Run full suite via MCP.** Expected: around 75 runs, 0 failures.

- [ ] **Step 4: Commit**

```
jj commit -m "Support length-changing edits in codec"
```

---

### Task 7: Corpus validation + README refresh

**Files:**
- Modify: `optimizer/README.md`

- [ ] **Step 1: Update the README** — read `optimizer/README.md`, replace the status line about length-changing edits:

Before:
```
Modifications to `IR::Function#instructions` are re-encoded (same-byte-count
substitutions). Length-changing edits (required for inlining) are a future
plan.
```

After:
```
Modifications to `IR::Function#instructions` are re-encoded including
length changes — passes can freely insert, delete, or replace instructions.
`IR::Function` also carries decoded `#catch_entries`, `#line_entries`, and
`#arg_positions` whose references to instructions are by identity, so they
survive instruction-list mutation; the encoder resolves identity to
current positions at emit time.
```

Preserve the rest of the README.

- [ ] **Step 2: Final corpus run via MCP.** Confirm 0 failures.

- [ ] **Step 3: Commit**

```
jj commit -m "Document length-changing edits in README"
```

---

## Self-review

**Coverage against the optimizer spec's round-trip section:**

- "Preserving iseq metadata (arg shape, local table layout, catch-table entries)" — Tasks 1 (catch), 3 (arg positions). Local table stays raw (no inst refs). ✓
- "Adjusting stack-depth annotations (stack_max) when instruction counts change" — Task 4. ✓
- "Preserving line numbers where we can, synthesizing where we can't" — Task 2. ✓
- "Version-gated: fails loudly on mismatch" — unchanged; Header decode still does this. ✓
- "Punts on constructs it can't round-trip" — constructs that currently don't round-trip fall through to the `raise UnsupportedOpcode` / `UnsupportedObjectKind` paths, which are unchanged. ✓

**Placeholder scan:** every task has concrete code for its new types and interfaces. Implementation steps that need the IBF format reference (Tasks 1–3) explicitly name the section of `research/cruby/ibf-format.md` to consult; the research doc already exists (Codec plan Task 2). No "TBD" / "add appropriate X" phrasing survived the review.

**Type consistency:** `IR::Function` gains four new fields across this plan — `catch_entries`, `line_entries`, `arg_positions`, and (via misc) `stack_max`. All consistently keyword-init Structs. `slot_to_inst` / `inst_to_slot` are used with the same name everywhere. Small-value signed variants are added in Task 2 if missing — if the engineer finds they already exist, skip the "add signed helpers" substep.

**Gaps for follow-up plans:**

- Some opcodes still stash specialized data (e.g. `TS_CALLDATA`) in separate ci_entries. Inlining will need to add new call-data entries as it splices call sites; Task 5's current design keeps ci_entries raw, which blocks inlining cross-iseq calls. The inlining plan will extend Task 5's re-serialization to include ci_entries — out of scope here.
- `opt_table` and keyword defaults point at default-value code regions. Inlining across methods with defaults means merging these tables; out of scope here.
- Stack-max is a conservative upper bound; tightening it is a micro-optimization, not a correctness requirement.
