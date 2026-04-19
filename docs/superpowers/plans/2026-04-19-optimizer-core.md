# Optimizer Core + Harness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the decode/encode gap so modifications to IR survive round-trip, build the CFG + type env + pass pipeline infrastructure, and land a `load_iseq` harness so optimized code flows transparently from `require`.

**Architecture:** Layer on top of the binary codec: decode → IR (now with CFG) → passes (registered, run in order, emit a structured log) → encode (picks up IR modifications). A `load_iseq` override wires the VM into this pipeline for every loaded file unless opted out.

**Tech Stack:** Ruby 4.0.2, minitest, prism for parsing `@rbs` inline comments, the existing `ruby-bytecode` MCP for in-container test runs.

**Scope bounds:** This plan builds everything needed to *run* passes over an iseq — the passes themselves are subsequent plans. A `NoopPass` exists here only as proof-of-life. Instruction re-encoding is constrained to *same-byte-count* substitutions (arith specialization and const-fold fit; inlining will need a follow-up to handle instruction-count changes).

**Commit discipline:** Every commit step is written as `jj commit -m "<msg>"` for readability. Executors MUST translate this to `jj split -m "<msg>" -- <files>` using the exact file list from the task's Files section. Run tests via `mcp__ruby-bytecode__run_optimizer_tests`, never host `bundle exec rake test`.

---

## File structure

```
optimizer/
  lib/
    ruby_opt/
      codec/
        iseq_envelope.rb    # MODIFIED in Task 1 (re-encode instructions from IR)
      ir/
        function.rb         # MODIFIED in Task 3 (#cfg accessor)
        basic_block.rb      # NEW Task 2
        cfg.rb              # NEW Task 3
      contract.rb           # NEW Task 4
      log.rb                # NEW Task 5
      pass.rb               # NEW Task 6 (abstract + NoopPass)
      pipeline.rb           # NEW Task 7
      rbs_parser.rb         # NEW Task 8
      type_env.rb           # NEW Task 9
      harness.rb            # NEW Task 11
  test/
    codec/
      encode_modifications_test.rb   # NEW Task 1
    ir/
      basic_block_test.rb            # NEW Task 2
      cfg_test.rb                    # NEW Task 3
    contract_test.rb                 # NEW Task 4
    log_test.rb                      # NEW Task 5
    pass_test.rb                     # NEW Task 6
    pipeline_test.rb                 # NEW Task 7
    rbs_parser_test.rb               # NEW Task 8
    type_env_test.rb                 # NEW Task 9
    harness_test.rb                  # NEW Task 11, Task 12
    harness_fixtures/                # NEW Task 12
      plain.rb
      opted_out.rb
```

---

### Task 1: Re-encode instructions from `IR::Instruction` on modification

**Files:**
- Modify: `optimizer/lib/ruby_opt/codec/iseq_envelope.rb`
- Modify: `optimizer/lib/ruby_opt/codec/iseq_list.rb` (if its verbatim-region path blocks re-encoded instructions; inspect before editing)
- Create: `optimizer/test/codec/encode_modifications_test.rb`

**Context:** Today `IseqEnvelope.encode` writes `misc[:raw_body]` verbatim and `IseqList.encode` writes the entire iseq data region (including instruction bytes) verbatim. That's why the round-trip is byte-identical without the encoder actually doing work. This task makes the encoder respect `function.instructions`: if the instruction array has been mutated, the new bytes from `InstructionStream.encode` replace the original at the same offset.

**Scope constraint:** The re-encoded instruction bytes MUST be the same length as the original. If they differ, raise `RubyOpt::Codec::EncoderSizeChange` with a clear message. Full re-serialization (supporting length changes for inlining) is a later plan.

- [ ] **Step 1: Write the failing test** — `optimizer/test/codec/encode_modifications_test.rb`

```ruby
# frozen_string_literal: true
require "test_helper"
require "ruby_opt/codec"
require "ruby_opt/ir/instruction"

class EncodeModificationsTest < Minitest::Test
  def test_modifying_putobject_operand_changes_bytes
    src = "def f; 1 + 2; end; f"
    original = RubyVM::InstructionSequence.compile(src).to_binary
    ir = RubyOpt::Codec.decode(original)

    f = ir.children.find { |c| c.name == "f" }
    refute_nil f
    # Find the second `putobject` (the `2`) and change its operand to 5.
    putobjects = f.instructions.select { |i| i.opcode == :putobject }
    assert putobjects.size >= 2, "expected 2+ putobject ops, got #{f.instructions.inspect}"
    putobjects[1].operands[0] = 5

    modified = RubyOpt::Codec.encode(ir)
    refute_equal original, modified, "expected re-encoded bytes to differ after mutation"
    # And the modified program still loads and runs
    loaded = RubyVM::InstructionSequence.load_from_binary(modified)
    # f returns 1 + modified_operand; outer calls f.
    assert_equal 6, loaded.eval
  end

  def test_round_trip_is_still_identity_when_instructions_unmodified
    src = "[1, 2, 3].map { |n| n * 2 }"
    original = RubyVM::InstructionSequence.compile(src).to_binary
    ir = RubyOpt::Codec.decode(original)
    re_encoded = RubyOpt::Codec.encode(ir)
    assert_equal original, re_encoded
  end

  def test_length_change_raises_encoder_size_change
    src = "def f; 1 + 2; end"
    ir = RubyOpt::Codec.decode(
      RubyVM::InstructionSequence.compile(src).to_binary
    )
    f = ir.children.find { |c| c.name == "f" }
    # Drop an instruction — this will change the byte count.
    f.instructions.pop
    assert_raises(RubyOpt::Codec::EncoderSizeChange) do
      RubyOpt::Codec.encode(ir)
    end
  end
end
```

- [ ] **Step 2: Run test via MCP, expect failures**

Run: `mcp__ruby-bytecode__run_optimizer_tests` with `test_filter: "test/codec/encode_modifications_test.rb"`
Expected: test_modifying_putobject_operand_changes_bytes fails (modified==original because raw bytes are used), test_length_change raises NameError (EncoderSizeChange not defined).

- [ ] **Step 3: Define the new exception** in `optimizer/lib/ruby_opt/codec.rb`

Add alongside the other exceptions:

```ruby
    # Raised when a pass produces instructions whose total encoded byte
    # length differs from the original. Full re-serialization of catch
    # tables, line info, and other offset-dependent sections is a later
    # plan; until then, passes must preserve the instruction byte count.
    class EncoderSizeChange < StandardError; end
```

- [ ] **Step 4: Modify `IseqEnvelope.encode` to re-encode instructions from IR**

Read `optimizer/lib/ruby_opt/codec/iseq_envelope.rb` end-to-end first. The encode path currently writes `function.misc[:raw_body]` verbatim. The new behavior:

1. Re-encode `function.instructions` via `InstructionStream.encode(function.instructions, object_table, all_functions)`. Note: `InstructionStream.encode`'s existing signature may not take `object_table` / `all_functions`; use whatever it needs to serialize.
2. Compare the re-encoded bytes' length to `function.misc[:raw_bytecode].bytesize`. If different, raise `RubyOpt::Codec::EncoderSizeChange` with message `"instruction re-encode changed size: was #{original_len}, got #{new_len} in iseq #{function.name}"`.
3. Splice the new instruction bytes into `function.misc[:raw_bytecode]` (or into the region `IseqList` emits) at the correct offset.

The surrounding iseq data region (local_table, catch_table, line_info, etc.) still comes from the raw region — only the instruction bytes change. The existing round-trip tests MUST continue to pass because InstructionStream round-trips byte-for-byte on unmodified input.

Concretely, the end of `IseqEnvelope.decode` currently captures `raw_bytecode` from the binary. Keep that capture. Add to the encode path: if `function.instructions` is the same object decode stored, or unchanged, the re-encode still matches original bytes (InstructionStream is a proper codec). If it was mutated, the new bytes reflect the mutation.

Because `IseqList` writes the raw region verbatim, you need to either:
(a) pass the modified instruction bytes back to `IseqList` so it substitutes them in, or
(b) have `IseqList` call `InstructionStream.encode` directly for each function during its encode.

Option (b) is cleaner. Inspect `IseqList` and move the instruction-region write into it.

- [ ] **Step 5: Run tests**

Run: `mcp__ruby-bytecode__run_optimizer_tests` (no filter)
Expected: 38 runs (35 existing + 3 new), 0 failures, 0 errors.

If a prior round-trip test fails, the new encode path has a bug — most likely `InstructionStream.encode` isn't byte-identical to the raw input for some opcode. Isolate via `test_filter` and fix before committing.

- [ ] **Step 6: Commit**

```
jj commit -m "Re-encode instructions from IR on modification"
```

(files: `optimizer/lib/ruby_opt/codec/iseq_envelope.rb`, `optimizer/lib/ruby_opt/codec/iseq_list.rb` if modified, `optimizer/lib/ruby_opt/codec.rb`, `optimizer/test/codec/encode_modifications_test.rb`)

---

### Task 2: `IR::BasicBlock`

**Files:**
- Create: `optimizer/lib/ruby_opt/ir/basic_block.rb`
- Create: `optimizer/test/ir/basic_block_test.rb`

**Context:** A basic block is a maximal straight-line sequence of YARV instructions with one entry and one exit (branch, return/`leave`, or fallthrough into the next block). Leaders are identified by: first instruction of the iseq, target of any branch, instruction immediately following a branch or `leave`. This task defines the data structure; the next task builds the CFG that wires blocks together.

- [ ] **Step 1: Write the failing test** — `optimizer/test/ir/basic_block_test.rb`

```ruby
# frozen_string_literal: true
require "test_helper"
require "ruby_opt/ir/basic_block"
require "ruby_opt/ir/instruction"

class BasicBlockTest < Minitest::Test
  def test_holds_instructions_in_order
    insns = [
      RubyOpt::IR::Instruction.new(opcode: :putobject, operands: [1], line: 1),
      RubyOpt::IR::Instruction.new(opcode: :leave, operands: [], line: 1),
    ]
    bb = RubyOpt::IR::BasicBlock.new(id: 0, instructions: insns)
    assert_equal 0, bb.id
    assert_equal 2, bb.instructions.size
    assert_equal :leave, bb.terminator.opcode
  end

  def test_terminator_is_last_instruction
    insns = [
      RubyOpt::IR::Instruction.new(opcode: :putobject, operands: [1], line: 1),
      RubyOpt::IR::Instruction.new(opcode: :branchif, operands: [10], line: 1),
    ]
    bb = RubyOpt::IR::BasicBlock.new(id: 1, instructions: insns)
    assert_equal :branchif, bb.terminator.opcode
  end

  def test_empty_block_has_nil_terminator
    bb = RubyOpt::IR::BasicBlock.new(id: 2, instructions: [])
    assert_nil bb.terminator
  end
end
```

- [ ] **Step 2: Run, expect LoadError**

Run via MCP with `test_filter: "test/ir/basic_block_test.rb"`.

- [ ] **Step 3: Implement `BasicBlock`**

```ruby
# frozen_string_literal: true

module RubyOpt
  module IR
    # One basic block in a function's CFG: a maximal straight-line
    # sequence of instructions with one entry (first instruction) and
    # one exit (last instruction is a branch, leave, or falls through).
    class BasicBlock
      attr_reader :id
      attr_accessor :instructions

      def initialize(id:, instructions: [])
        @id = id
        @instructions = instructions
      end

      def terminator
        @instructions.last
      end

      def empty?
        @instructions.empty?
      end
    end
  end
end
```

- [ ] **Step 4: Run tests, expect pass**

Expected: 3 new runs pass; total suite 41 runs.

- [ ] **Step 5: Commit**

```
jj commit -m "Add IR::BasicBlock"
```

(files: `optimizer/lib/ruby_opt/ir/basic_block.rb`, `optimizer/test/ir/basic_block_test.rb`)

---

### Task 3: CFG construction + `Function#cfg`

**Files:**
- Create: `optimizer/lib/ruby_opt/ir/cfg.rb`
- Modify: `optimizer/lib/ruby_opt/ir/function.rb`
- Create: `optimizer/test/ir/cfg_test.rb`

**Context:** The CFG is the control-flow graph of a function — a list of basic blocks plus directed edges. Build it by scanning the instruction list, identifying leaders (first instruction; target of any branch; instruction after a branch or terminator), and slicing the instruction list into blocks. Edges come from branch operands and fall-throughs.

For the opcodes this project cares about:
- `leave` / `throw` — terminates the block, no successor (returns from iseq).
- `branchif`, `branchunless`, `branchnil` — terminates the block; two successors: the branch target (from operand 0, which is an instruction index or offset) and the fall-through block.
- `jump` — terminates the block; one successor: the branch target.
- Everything else — non-terminator; falls through to the next instruction.

Branch operand encoding: YARV instructions use signed instruction-index offsets. `InstructionStream.decode` returns operands as-is; they're indices into the `instructions` array. Verify this by inspecting what `InstructionStream.decode` puts in branch instructions' operands — if it stores byte offsets, you need to convert them to instruction indices before CFG work.

- [ ] **Step 1: Write the failing test** — `optimizer/test/ir/cfg_test.rb`

```ruby
# frozen_string_literal: true
require "test_helper"
require "ruby_opt/codec"
require "ruby_opt/ir/cfg"

class CfgTest < Minitest::Test
  def test_straight_line_function_has_one_block
    src = "def f; 1 + 2; end"
    ir = RubyOpt::Codec.decode(
      RubyVM::InstructionSequence.compile(src).to_binary
    )
    f = ir.children.find { |c| c.name == "f" }
    cfg = f.cfg
    assert_equal 1, cfg.blocks.size
    assert_equal :leave, cfg.blocks.first.terminator.opcode
    assert_empty cfg.successors(cfg.blocks.first)
  end

  def test_conditional_produces_two_successors
    src = "def f(x); if x then 1 else 2 end; end"
    ir = RubyOpt::Codec.decode(
      RubyVM::InstructionSequence.compile(src).to_binary
    )
    f = ir.children.find { |c| c.name == "f" }
    cfg = f.cfg
    # At least one block whose terminator is a branch, with 2 successors.
    branch_block = cfg.blocks.find { |b|
      b.terminator && %i[branchif branchunless branchnil].include?(b.terminator.opcode)
    }
    refute_nil branch_block, "expected a conditional-branch block, got terminators: #{cfg.blocks.map { |b| b.terminator&.opcode }.inspect}"
    assert_equal 2, cfg.successors(branch_block).size
  end

  def test_predecessors_are_inverse_of_successors
    src = "def f(x); if x then 1 else 2 end; end"
    ir = RubyOpt::Codec.decode(
      RubyVM::InstructionSequence.compile(src).to_binary
    )
    f = ir.children.find { |c| c.name == "f" }
    cfg = f.cfg
    cfg.blocks.each do |b|
      cfg.successors(b).each do |succ|
        assert_includes cfg.predecessors(succ), b,
          "predecessors(#{succ.id}) missing #{b.id}"
      end
    end
  end
end
```

- [ ] **Step 2: Run, expect failures.**

- [ ] **Step 3: Implement `CFG`** — `optimizer/lib/ruby_opt/ir/cfg.rb`

```ruby
# frozen_string_literal: true
require "ruby_opt/ir/basic_block"

module RubyOpt
  module IR
    # Control-flow graph of a function. Blocks are computed once from the
    # function's instruction list; successors/predecessors are queried via
    # edge lookups.
    class CFG
      BRANCH_OPCODES = %i[branchif branchunless branchnil].freeze
      JUMP_OPCODES = %i[jump].freeze
      TERMINATOR_OPCODES = (BRANCH_OPCODES + JUMP_OPCODES + %i[leave throw]).freeze

      attr_reader :blocks

      def self.build(instructions)
        leaders = compute_leaders(instructions)
        blocks = slice_into_blocks(instructions, leaders)
        edges = compute_edges(instructions, blocks)
        new(blocks, edges)
      end

      def initialize(blocks, edges)
        @blocks = blocks
        @edges = edges # { from_block_id => [to_block, ...] }
      end

      def successors(block)
        @edges[block.id] || []
      end

      def predecessors(block)
        @blocks.select { |b| successors(b).include?(block) }
      end

      def self.compute_leaders(instructions)
        return [] if instructions.empty?
        leaders = [0]
        instructions.each_with_index do |ins, i|
          next unless TERMINATOR_OPCODES.include?(ins.opcode)
          # The instruction after a terminator is a leader (if it exists).
          leaders << (i + 1) if i + 1 < instructions.size
          # Branch targets are leaders.
          if (BRANCH_OPCODES + JUMP_OPCODES).include?(ins.opcode)
            target = ins.operands[0]
            leaders << target if target.is_a?(Integer) && target >= 0 && target < instructions.size
          end
        end
        leaders.uniq.sort
      end

      def self.slice_into_blocks(instructions, leaders)
        return [] if instructions.empty?
        blocks = []
        leaders.each_with_index do |start, idx|
          stop = leaders[idx + 1] || instructions.size
          blocks << BasicBlock.new(id: idx, instructions: instructions[start...stop])
        end
        blocks
      end

      def self.compute_edges(instructions, blocks)
        # Map instruction index -> block
        insn_to_block = {}
        blocks.each do |b|
          # Find the global index of this block's first instruction
          # via identity comparison (blocks hold references, not copies).
          offset = instructions.index { |ins| ins.equal?(b.instructions.first) }
          next unless offset
          b.instructions.each_with_index do |_, j|
            insn_to_block[offset + j] = b
          end
        end

        edges = Hash.new { |h, k| h[k] = [] }
        blocks.each do |b|
          term = b.terminator
          next unless term
          case term.opcode
          when *BRANCH_OPCODES
            target = term.operands[0]
            fallthrough_idx = instructions.index { |i| i.equal?(term) } + 1
            if (tblock = insn_to_block[target])
              edges[b.id] << tblock
            end
            if (fblock = insn_to_block[fallthrough_idx])
              edges[b.id] << fblock
            end
          when *JUMP_OPCODES
            target = term.operands[0]
            if (tblock = insn_to_block[target])
              edges[b.id] << tblock
            end
          when :leave, :throw
            # no successors
          else
            # Non-terminator tail (shouldn't happen if leaders are right,
            # but fall through to the next block just in case).
            fallthrough_idx = instructions.index { |i| i.equal?(term) } + 1
            if (fblock = insn_to_block[fallthrough_idx])
              edges[b.id] << fblock
            end
          end
        end
        edges
      end
    end
  end
end
```

- [ ] **Step 4: Add `#cfg` to `IR::Function`** — `optimizer/lib/ruby_opt/ir/function.rb`

Append a method to the Struct (or reopen it):

```ruby
# At the bottom of the file, replace the plain Struct.new(...) assignment with:
require "ruby_opt/ir/cfg"

module RubyOpt
  module IR
    Function.class_eval do
      def cfg
        @cfg ||= CFG.build(instructions || [])
      end

      def invalidate_cfg
        @cfg = nil
      end
    end
  end
end
```

If `IR::Function` is defined as a simple `Struct.new(...)` assignment, the above reopening works. If it was defined with `do ... end` block, add the methods inside.

- [ ] **Step 5: Caveat on operand encoding.** If the test fails with "target is not a valid instruction index", the branch operands in `InstructionStream.decode` are likely byte offsets, not instruction indices. Two fixes, in order of preference:

  (a) Change `InstructionStream.decode` to convert branch targets from byte offsets to instruction indices at decode time, and the reverse at encode time. Document the convention with a comment: "branch operands are instruction indices in IR; byte offsets in the binary." This is the right long-term fix.

  (b) If that's more invasive than expected, do the conversion inside `CFG.build` using an auxiliary bytecode-offset table that the codec exposes.

Pick (a) unless it breaks Task 1's round-trip tests.

- [ ] **Step 6: Run tests**

Expected: 3 new cfg tests + 3 bb tests all pass; total suite 44 runs, 0 failures.

- [ ] **Step 7: Commit**

```
jj commit -m "Build CFG and expose Function#cfg"
```

(files: `optimizer/lib/ruby_opt/ir/cfg.rb`, `optimizer/lib/ruby_opt/ir/function.rb`, `optimizer/test/ir/cfg_test.rb`, plus `optimizer/lib/ruby_opt/codec/instruction_stream.rb` if Step 5 fix (a) was applied)

---

### Task 4: `RubyOpt::Contract`

**Files:**
- Create: `optimizer/lib/ruby_opt/contract.rb`
- Create: `optimizer/test/contract_test.rb`

**Context:** The contract is the hardcoded set of assumptions the optimizer makes, from the design spec. Passes consult it but don't configure it — accepting the optimizer means accepting all clauses. This task codifies it as a simple module with named predicates.

- [ ] **Step 1: Write the failing test** — `optimizer/test/contract_test.rb`

```ruby
# frozen_string_literal: true
require "test_helper"
require "ruby_opt/contract"

class ContractTest < Minitest::Test
  def test_all_five_clauses_are_asserted
    c = RubyOpt::Contract
    assert c.no_bop_redefinition?
    assert c.no_prepend_after_load?
    assert c.rbs_signatures_truthful?
    assert c.env_read_only?
    assert c.no_constant_reassignment?
  end

  def test_clauses_returns_all_five
    assert_equal 5, RubyOpt::Contract.clauses.size
    assert_includes RubyOpt::Contract.clauses, :no_bop_redefinition
  end

  def test_describe_returns_human_readable_strings
    text = RubyOpt::Contract.describe
    assert_kind_of String, text
    assert_match(/BOP/i, text)
    assert_match(/prepend/i, text)
    assert_match(/RBS/, text)
    assert_match(/ENV/, text)
    assert_match(/constant/i, text)
  end
end
```

- [ ] **Step 2: Run, expect LoadError.**

- [ ] **Step 3: Implement `Contract`**

```ruby
# frozen_string_literal: true

module RubyOpt
  # The hardcoded ground rules the optimizer assumes. Accepting the
  # optimizer means accepting all five. Breaking any is a miscompile,
  # not a slowdown.
  module Contract
    CLAUSES = {
      no_bop_redefinition: "Core basic operations (Integer#+, Array#[], String#==, ...) are not redefined.",
      no_prepend_after_load: "No `prepend` into any class after load; method tables are stable.",
      rbs_signatures_truthful: "Inline `@rbs` signatures accurately describe runtime types.",
      env_read_only: "`ENV` is read-only after load; `ENV[\"X\"]` resolves once.",
      no_constant_reassignment: "Top-level constants are assigned exactly once; no `const_set` after load.",
    }.freeze

    module_function

    def clauses
      CLAUSES.keys
    end

    def describe
      CLAUSES.map { |k, v| "- #{k}: #{v}" }.join("\n")
    end

    CLAUSES.each_key do |clause|
      define_method("#{clause}?") { true }
    end
  end
end
```

- [ ] **Step 4: Run tests, expect pass.**

- [ ] **Step 5: Commit**

```
jj commit -m "Add hardcoded Contract module"
```

(files: `optimizer/lib/ruby_opt/contract.rb`, `optimizer/test/contract_test.rb`)

---

### Task 5: `RubyOpt::Log`

**Files:**
- Create: `optimizer/lib/ruby_opt/log.rb`
- Create: `optimizer/test/log_test.rb`

**Context:** Every "I could have optimized this but didn't" decision from a pass gets logged with source location, pass name, and reason. The talk uses this as demo material. Structure is simple — an append-only array of `Entry` structs exposed via `Log#entries`.

- [ ] **Step 1: Write the failing test** — `optimizer/test/log_test.rb`

```ruby
# frozen_string_literal: true
require "test_helper"
require "ruby_opt/log"

class LogTest < Minitest::Test
  def test_records_entries_with_pass_name_and_reason
    log = RubyOpt::Log.new
    log.skip(pass: :inlining, reason: :receiver_not_resolvable, file: "a.rb", line: 12)
    log.skip(pass: :const_fold, reason: :mutable_receiver, file: "a.rb", line: 15)
    assert_equal 2, log.entries.size
    first = log.entries.first
    assert_equal :inlining, first.pass
    assert_equal :receiver_not_resolvable, first.reason
    assert_equal "a.rb", first.file
    assert_equal 12, first.line
  end

  def test_for_pass_filters_entries
    log = RubyOpt::Log.new
    log.skip(pass: :inlining, reason: :a, file: "x", line: 1)
    log.skip(pass: :arith, reason: :b, file: "x", line: 2)
    inlining_only = log.for_pass(:inlining)
    assert_equal 1, inlining_only.size
    assert_equal :inlining, inlining_only.first.pass
  end

  def test_empty_log_has_no_entries
    assert_empty RubyOpt::Log.new.entries
  end
end
```

- [ ] **Step 2: Run, expect LoadError.**

- [ ] **Step 3: Implement `Log`**

```ruby
# frozen_string_literal: true

module RubyOpt
  class Log
    Entry = Struct.new(:pass, :reason, :file, :line, keyword_init: true)

    def initialize
      @entries = []
    end

    def entries
      @entries.dup.freeze
    end

    def skip(pass:, reason:, file:, line:)
      @entries << Entry.new(pass: pass, reason: reason, file: file, line: line)
    end

    def for_pass(pass)
      @entries.select { |e| e.pass == pass }
    end
  end
end
```

- [ ] **Step 4: Run tests, expect pass.**

- [ ] **Step 5: Commit**

```
jj commit -m "Add structured optimizer Log"
```

(files: `optimizer/lib/ruby_opt/log.rb`, `optimizer/test/log_test.rb`)

---

### Task 6: `RubyOpt::Pass` base + `NoopPass`

**Files:**
- Create: `optimizer/lib/ruby_opt/pass.rb`
- Create: `optimizer/test/pass_test.rb`

**Context:** A pass operates on an `IR::Function` and optionally mutates its instructions. The base class defines the contract (one method: `apply`), gives passes access to the type env / contract / log, and provides a name. `NoopPass` is proof-of-life — it exists so Task 7's pipeline test can exercise pass orchestration without waiting on real passes.

- [ ] **Step 1: Write the failing test** — `optimizer/test/pass_test.rb`

```ruby
# frozen_string_literal: true
require "test_helper"
require "ruby_opt/pass"
require "ruby_opt/log"
require "ruby_opt/codec"

class PassTest < Minitest::Test
  def test_noop_pass_does_not_change_instructions
    ir = RubyOpt::Codec.decode(
      RubyVM::InstructionSequence.compile("1 + 2").to_binary
    )
    f = ir.children.first # outer iseq
    before = f.instructions.map(&:opcode)
    log = RubyOpt::Log.new
    RubyOpt::NoopPass.new.apply(f, type_env: nil, log: log)
    after = f.instructions.map(&:opcode)
    assert_equal before, after
    assert_empty log.entries
  end

  def test_base_pass_apply_raises_not_implemented
    assert_raises(NotImplementedError) do
      RubyOpt::Pass.new.apply(nil, type_env: nil, log: nil)
    end
  end

  def test_pass_has_a_name
    assert_equal :noop, RubyOpt::NoopPass.new.name
  end
end
```

- [ ] **Step 2: Run, expect LoadError.**

- [ ] **Step 3: Implement `Pass` + `NoopPass`** — `optimizer/lib/ruby_opt/pass.rb`

```ruby
# frozen_string_literal: true

module RubyOpt
  # Abstract base class for optimizer passes. Subclasses override #apply
  # and optionally #name.
  class Pass
    # Run this pass on a single IR::Function. The pass may mutate
    # `function.instructions` or `function.children` but must log any
    # skipped optimization decisions to `log`.
    #
    # @param function [RubyOpt::IR::Function]
    # @param type_env [RubyOpt::TypeEnv, nil]
    # @param log     [RubyOpt::Log]
    def apply(function, type_env:, log:)
      raise NotImplementedError
    end

    def name
      self.class.name.to_s.split("::").last.sub(/Pass$/, "").downcase.to_sym
    end
  end

  # Pass that does nothing. Used to exercise the pipeline without depending
  # on real passes.
  class NoopPass < Pass
    def apply(function, type_env:, log:)
      # Intentionally empty.
    end

    def name
      :noop
    end
  end
end
```

- [ ] **Step 4: Run tests, expect pass.**

- [ ] **Step 5: Commit**

```
jj commit -m "Add Pass base class and NoopPass"
```

(files: `optimizer/lib/ruby_opt/pass.rb`, `optimizer/test/pass_test.rb`)

---

### Task 7: `RubyOpt::Pipeline`

**Files:**
- Create: `optimizer/lib/ruby_opt/pipeline.rb`
- Create: `optimizer/test/pipeline_test.rb`

**Context:** Runs a fixed ordered list of passes over an `IR::Function` and all its descendants, threading through a shared `Log`. Catches pass exceptions, logs them as skips (pass name + reason `:pass_raised`), and continues with remaining passes so one bad pass doesn't abort the file.

- [ ] **Step 1: Write the failing test** — `optimizer/test/pipeline_test.rb`

```ruby
# frozen_string_literal: true
require "test_helper"
require "ruby_opt/pipeline"
require "ruby_opt/pass"
require "ruby_opt/codec"

class PipelineTest < Minitest::Test
  class TrackingPass < RubyOpt::Pass
    attr_reader :visited

    def initialize(name_sym)
      @name_sym = name_sym
      @visited = []
    end

    def apply(function, type_env:, log:)
      @visited << function.name
    end

    def name
      @name_sym
    end
  end

  class RaisingPass < RubyOpt::Pass
    def apply(function, type_env:, log:)
      raise "boom"
    end

    def name
      :raising
    end
  end

  def ir
    RubyOpt::Codec.decode(
      RubyVM::InstructionSequence.compile("def a; 1; end; def b; 2; end").to_binary
    )
  end

  def test_runs_passes_in_order_over_each_function
    t1 = TrackingPass.new(:first)
    t2 = TrackingPass.new(:second)
    pipeline = RubyOpt::Pipeline.new([t1, t2])
    log = pipeline.run(ir, type_env: nil)
    # Each pass visits every Function (outer + a + b)
    assert_equal 3, t1.visited.size
    assert_equal 3, t2.visited.size
    assert_kind_of RubyOpt::Log, log
  end

  def test_raising_pass_logs_and_continues
    raiser = RaisingPass.new
    tracker = TrackingPass.new(:tracker)
    pipeline = RubyOpt::Pipeline.new([raiser, tracker])
    log = pipeline.run(ir, type_env: nil)

    raised_entries = log.for_pass(:raising)
    refute_empty raised_entries, "expected raising pass to log a skip"
    assert_equal :pass_raised, raised_entries.first.reason

    # The subsequent pass still ran on every Function.
    assert_equal 3, tracker.visited.size
  end
end
```

- [ ] **Step 2: Run, expect LoadError.**

- [ ] **Step 3: Implement `Pipeline`** — `optimizer/lib/ruby_opt/pipeline.rb`

```ruby
# frozen_string_literal: true
require "ruby_opt/log"

module RubyOpt
  class Pipeline
    def initialize(passes)
      @passes = passes
    end

    # Run all passes over every Function in the IR tree.
    # Returns the RubyOpt::Log accumulated during the run.
    def run(ir, type_env:)
      log = Log.new
      each_function(ir) do |function|
        @passes.each do |pass|
          begin
            pass.apply(function, type_env: type_env, log: log)
          rescue => e
            log.skip(
              pass: pass.name,
              reason: :pass_raised,
              file: function.path,
              line: function.first_lineno || 0,
            )
          end
        end
      end
      log
    end

    private

    def each_function(function, &block)
      yield function
      function.children&.each do |child|
        each_function(child, &block)
      end
    end
  end
end
```

- [ ] **Step 4: Run tests, expect pass.**

- [ ] **Step 5: Commit**

```
jj commit -m "Add Pipeline for ordered pass execution"
```

(files: `optimizer/lib/ruby_opt/pipeline.rb`, `optimizer/test/pipeline_test.rb`)

---

### Task 8: `RubyOpt::RbsParser` — extract `@rbs` inline comments

**Files:**
- Create: `optimizer/lib/ruby_opt/rbs_parser.rb`
- Create: `optimizer/test/rbs_parser_test.rb`

**Context:** Inline `@rbs` comments attach type info to Ruby source without separate `.rbs` files. Syntax (from rbs-inline): a line comment starting with `# @rbs` immediately preceding a method def declares that method's signature. For this plan we support only the simplest form — a single-line `@rbs` attached to a top-level method or instance method:

```ruby
# @rbs (Integer, Integer) -> Integer
def add(a, b); a + b; end
```

The parser takes source text and returns an array of `Signature` records: `method_name`, `receiver_class` (nil for top-level, String for `Class#method` context), `arg_types` (Array<String>), `return_type` (String), `file`, `line`. We do not interpret the types — they're opaque strings for now. The passes will later parse these into something richer.

We use `prism` (already in the Gemfile) to walk the AST and find `DefNode`s, then look backward at preceding comments for the `@rbs` line.

- [ ] **Step 1: Write the failing test** — `optimizer/test/rbs_parser_test.rb`

```ruby
# frozen_string_literal: true
require "test_helper"
require "ruby_opt/rbs_parser"

class RbsParserTest < Minitest::Test
  def test_captures_top_level_def_signature
    src = <<~RUBY
      # @rbs (Integer, Integer) -> Integer
      def add(a, b); a + b; end
    RUBY
    sigs = RubyOpt::RbsParser.parse(src, "test.rb")
    assert_equal 1, sigs.size
    s = sigs.first
    assert_equal :add, s.method_name
    assert_nil s.receiver_class
    assert_equal ["Integer", "Integer"], s.arg_types
    assert_equal "Integer", s.return_type
  end

  def test_captures_instance_method_signature
    src = <<~RUBY
      class Point
        # @rbs (Point) -> Float
        def distance_to(other)
          0.0
        end
      end
    RUBY
    sigs = RubyOpt::RbsParser.parse(src, "test.rb")
    s = sigs.find { |x| x.method_name == :distance_to }
    refute_nil s
    assert_equal "Point", s.receiver_class
    assert_equal ["Point"], s.arg_types
    assert_equal "Float", s.return_type
  end

  def test_defs_without_rbs_comment_are_skipped
    src = <<~RUBY
      def plain(a); a; end
      # @rbs (Integer) -> Integer
      def annotated(a); a; end
    RUBY
    sigs = RubyOpt::RbsParser.parse(src, "test.rb")
    assert_equal 1, sigs.size
    assert_equal :annotated, sigs.first.method_name
  end

  def test_returns_empty_array_when_no_annotations
    assert_empty RubyOpt::RbsParser.parse("def hi; end", "test.rb")
  end
end
```

- [ ] **Step 2: Run, expect LoadError.**

- [ ] **Step 3: Implement `RbsParser`** — `optimizer/lib/ruby_opt/rbs_parser.rb`

```ruby
# frozen_string_literal: true
require "prism"

module RubyOpt
  # Minimal parser for inline `@rbs` comments.
  #
  # Recognized form (one-line signature immediately preceding a def):
  #
  #   # @rbs (Type, Type, ...) -> Type
  #   def method_name(args...)
  #
  # Multi-line signatures, generics, block types, and rbs-inline's other
  # forms are out of scope for this plan.
  module RbsParser
    Signature = Struct.new(
      :method_name, :receiver_class, :arg_types, :return_type, :file, :line,
      keyword_init: true,
    )

    SIG_RE = /\A#\s*@rbs\s*\((.*?)\)\s*->\s*(\S+)/

    module_function

    def parse(source, file)
      result = Prism.parse(source)
      # Build an index: comment line -> comment text, for lookup by def's line - 1.
      comment_by_line = {}
      result.comments.each do |c|
        comment_by_line[c.location.start_line] = c.slice
      end

      signatures = []
      walk(result.value, nil) do |node, class_ctx|
        next unless node.is_a?(Prism::DefNode)
        def_line = node.location.start_line
        # Find the @rbs comment immediately preceding the def (allowing
        # blank lines and consecutive normal comments).
        rbs_text = scan_back_for_rbs(comment_by_line, def_line)
        next unless rbs_text
        match = SIG_RE.match(rbs_text)
        next unless match
        arg_types = split_arg_types(match[1])
        signatures << Signature.new(
          method_name: node.name,
          receiver_class: class_ctx,
          arg_types: arg_types,
          return_type: match[2],
          file: file,
          line: def_line,
        )
      end
      signatures
    end

    def walk(node, class_ctx, &block)
      return unless node.is_a?(Prism::Node)
      if node.is_a?(Prism::ClassNode)
        new_ctx = node.constant_path.slice
        yield node, class_ctx
        node.compact_child_nodes.each { |c| walk(c, new_ctx, &block) }
      else
        yield node, class_ctx
        node.compact_child_nodes.each { |c| walk(c, class_ctx, &block) }
      end
    end

    def scan_back_for_rbs(comment_by_line, def_line)
      line = def_line - 1
      while line >= 1
        text = comment_by_line[line]
        return nil if text.nil?
        return text if text =~ /@rbs/
        line -= 1
      end
      nil
    end

    def split_arg_types(inside_parens)
      return [] if inside_parens.strip.empty?
      # Simple split on commas that aren't inside brackets.
      depth = 0
      buf = +""
      parts = []
      inside_parens.each_char do |ch|
        case ch
        when "(", "[", "<" then depth += 1; buf << ch
        when ")", "]", ">" then depth -= 1; buf << ch
        when ","
          if depth.zero?
            parts << buf.strip
            buf = +""
          else
            buf << ch
          end
        else
          buf << ch
        end
      end
      parts << buf.strip unless buf.empty?
      parts
    end
  end
end
```

- [ ] **Step 4: Run tests, expect pass.**

- [ ] **Step 5: Commit**

```
jj commit -m "Add RbsParser for inline @rbs signatures"
```

(files: `optimizer/lib/ruby_opt/rbs_parser.rb`, `optimizer/test/rbs_parser_test.rb`)

---

### Task 9: `RubyOpt::TypeEnv`

**Files:**
- Create: `optimizer/lib/ruby_opt/type_env.rb`
- Create: `optimizer/test/type_env_test.rb`

**Context:** Wraps the output of `RbsParser` with a query interface passes will consume. For this plan we ship only the one query passes are known to need: `signature_for(receiver_class, method_name) -> Signature`. Class-of / call-resolution helpers come in pass plans as they're needed.

- [ ] **Step 1: Write the failing test** — `optimizer/test/type_env_test.rb`

```ruby
# frozen_string_literal: true
require "test_helper"
require "ruby_opt/type_env"

class TypeEnvTest < Minitest::Test
  def test_lookup_by_class_and_method_returns_signature
    src = <<~RUBY
      # @rbs (Integer, Integer) -> Integer
      def add(a, b); a + b; end

      class Point
        # @rbs (Point) -> Float
        def distance_to(other); 0.0; end
      end
    RUBY
    env = RubyOpt::TypeEnv.from_source(src, "test.rb")

    top = env.signature_for(receiver_class: nil, method_name: :add)
    refute_nil top
    assert_equal "Integer", top.return_type

    inst = env.signature_for(receiver_class: "Point", method_name: :distance_to)
    refute_nil inst
    assert_equal "Float", inst.return_type
  end

  def test_lookup_with_no_signature_returns_nil
    env = RubyOpt::TypeEnv.from_source("def hi; end", "test.rb")
    assert_nil env.signature_for(receiver_class: nil, method_name: :hi)
  end

  def test_empty_env_for_empty_source
    env = RubyOpt::TypeEnv.from_source("", "test.rb")
    assert_kind_of RubyOpt::TypeEnv, env
  end
end
```

- [ ] **Step 2: Run, expect LoadError.**

- [ ] **Step 3: Implement `TypeEnv`** — `optimizer/lib/ruby_opt/type_env.rb`

```ruby
# frozen_string_literal: true
require "ruby_opt/rbs_parser"

module RubyOpt
  class TypeEnv
    def self.from_source(source, file)
      new(RbsParser.parse(source, file))
    end

    def initialize(signatures)
      @by_key = {}
      signatures.each do |s|
        @by_key[[s.receiver_class, s.method_name]] = s
      end
    end

    def signature_for(receiver_class:, method_name:)
      @by_key[[receiver_class, method_name]]
    end

    def empty?
      @by_key.empty?
    end
  end
end
```

- [ ] **Step 4: Run tests, expect pass.**

- [ ] **Step 5: Commit**

```
jj commit -m "Add TypeEnv over RbsParser output"
```

(files: `optimizer/lib/ruby_opt/type_env.rb`, `optimizer/test/type_env_test.rb`)

---

### Task 10: Magic-comment opt-out helper

**Files:**
- Create: `optimizer/lib/ruby_opt/harness.rb` (partial — just the helper)
- Create: `optimizer/test/harness_test.rb` (partial)

**Context:** Files opt out of optimization with `# rbs-optimize: false` anywhere in the first ~5 lines of the file. This task implements the detection helper in isolation, tested without hooking `load_iseq`.

- [ ] **Step 1: Write the failing test** — `optimizer/test/harness_test.rb`

```ruby
# frozen_string_literal: true
require "test_helper"
require "ruby_opt/harness"

class HarnessOptOutTest < Minitest::Test
  def test_opt_out_detected_in_top_comment
    src = "# rbs-optimize: false\nputs 1\n"
    assert RubyOpt::Harness.opted_out?(src)
  end

  def test_default_is_opted_in
    assert_equal false, RubyOpt::Harness.opted_out?("puts 1\n")
  end

  def test_opt_out_in_deep_comment_is_ignored
    src = "puts 1\n" * 20 + "# rbs-optimize: false\n"
    assert_equal false, RubyOpt::Harness.opted_out?(src),
      "only the top of the file is scanned for the opt-out"
  end

  def test_matches_with_loose_whitespace
    assert RubyOpt::Harness.opted_out?("#rbs-optimize:false\n")
    assert RubyOpt::Harness.opted_out?("#   rbs-optimize:   false   \n")
  end
end
```

- [ ] **Step 2: Run, expect LoadError.**

- [ ] **Step 3: Implement the helper** — `optimizer/lib/ruby_opt/harness.rb` (first cut)

```ruby
# frozen_string_literal: true

module RubyOpt
  module Harness
    OPT_OUT_RE = /\A#\s*rbs-optimize\s*:\s*false\s*\z/

    module_function

    # Whether the source file has opted out of optimization. Scans the
    # first 5 lines for a `# rbs-optimize: false` directive.
    def opted_out?(source)
      source.each_line.first(5).any? { |line| OPT_OUT_RE.match?(line.chomp) }
    end
  end
end
```

- [ ] **Step 4: Run tests, expect pass.**

- [ ] **Step 5: Commit**

```
jj commit -m "Add Harness.opted_out? helper"
```

(files: `optimizer/lib/ruby_opt/harness.rb`, `optimizer/test/harness_test.rb`)

---

### Task 11: `load_iseq` override

**Files:**
- Modify: `optimizer/lib/ruby_opt/harness.rb`
- Modify: `optimizer/test/harness_test.rb`
- Create: `optimizer/test/harness_fixtures/plain.rb`
- Create: `optimizer/test/harness_fixtures/opted_out.rb`

**Context:** Final piece. The `load_iseq` override intercepts every `require`/`load`, compiles the source, decodes, runs the pipeline, re-encodes, and hands back an iseq via `load_from_binary`. On ANY failure (parse error, codec error, pipeline exception), the override returns `nil`, which tells the VM to fall back to the normal compilation path. This way a broken optimizer never breaks `require`.

- [ ] **Step 1: Create fixtures**

`optimizer/test/harness_fixtures/plain.rb`:
```ruby
# Simple fixture loaded through the harness.
class HarnessPlainFixture
  def self.answer
    6 * 7
  end
end
```

`optimizer/test/harness_fixtures/opted_out.rb`:
```ruby
# rbs-optimize: false
class HarnessOptedOutFixture
  def self.answer
    99
  end
end
```

- [ ] **Step 2: Add the integration tests to `optimizer/test/harness_test.rb`** (append to the existing file)

```ruby
class HarnessLoadIseqTest < Minitest::Test
  FIXTURE_DIR = File.expand_path("harness_fixtures", __dir__)

  def setup
    @passes_seen = []
    passes = [TrackingNoopPass.new(@passes_seen)]
    @harness = RubyOpt::Harness::LoadIseqHook.new(passes: passes)
  end

  class TrackingNoopPass < RubyOpt::Pass
    def initialize(tracker)
      @tracker = tracker
    end

    def apply(function, type_env:, log:)
      @tracker << function.name
    end

    def name
      :tracking_noop
    end
  end

  def test_install_and_load_runs_pipeline_and_returns_iseq
    @harness.install
    load File.join(FIXTURE_DIR, "plain.rb")
    assert_equal 42, HarnessPlainFixture.answer
    # The outer iseq + the class body + the singleton method all got visited.
    refute_empty @passes_seen
  ensure
    @harness.uninstall
    Object.send(:remove_const, :HarnessPlainFixture) if defined?(HarnessPlainFixture)
  end

  def test_opted_out_file_bypasses_pipeline
    @harness.install
    load File.join(FIXTURE_DIR, "opted_out.rb")
    assert_equal 99, HarnessOptedOutFixture.answer
    assert_empty @passes_seen,
      "opted-out file must not be visited by any pass"
  ensure
    @harness.uninstall
    Object.send(:remove_const, :HarnessOptedOutFixture) if defined?(HarnessOptedOutFixture)
  end
end
```

These tests require `require "ruby_opt/pass"` at the top of the file if not already there.

- [ ] **Step 3: Extend `optimizer/lib/ruby_opt/harness.rb`**

```ruby
# frozen_string_literal: true
require "ruby_opt/codec"
require "ruby_opt/pipeline"
require "ruby_opt/type_env"

module RubyOpt
  module Harness
    OPT_OUT_RE = /\A#\s*rbs-optimize\s*:\s*false\s*\z/

    module_function

    def opted_out?(source)
      source.each_line.first(5).any? { |line| OPT_OUT_RE.match?(line.chomp) }
    end

    # Intercepts RubyVM::InstructionSequence.load_iseq, runs the
    # configured pipeline on every loaded iseq, and falls back to the
    # built-in compiler on any failure.
    class LoadIseqHook
      def initialize(passes:)
        @pipeline = Pipeline.new(passes)
        @installed = false
      end

      def install
        return if @installed
        hook = self
        @prev_singleton = nil
        meta = class << RubyVM::InstructionSequence; self; end
        if meta.method_defined?(:load_iseq)
          @prev_singleton = meta.instance_method(:load_iseq)
        end
        meta.define_method(:load_iseq) do |path|
          hook.__transform(path)
        end
        @installed = true
      end

      def uninstall
        return unless @installed
        meta = class << RubyVM::InstructionSequence; self; end
        if @prev_singleton
          meta.define_method(:load_iseq, @prev_singleton)
        else
          meta.remove_method(:load_iseq)
        end
        @installed = false
      end

      # Public for the hook's use only — name is __-prefixed to discourage
      # direct callers.
      def __transform(path)
        source = File.read(path)
        return nil if Harness.opted_out?(source)

        iseq = RubyVM::InstructionSequence.compile(source, path, path)
        binary = iseq.to_binary
        ir = Codec.decode(binary)
        type_env = TypeEnv.from_source(source, path)
        @pipeline.run(ir, type_env: type_env)
        modified = Codec.encode(ir)
        RubyVM::InstructionSequence.load_from_binary(modified)
      rescue => e
        warn "[ruby_opt] harness fell back on #{path}: #{e.class}: #{e.message}"
        nil
      end
    end
  end
end
```

- [ ] **Step 4: Run tests**

Run via MCP. Expected: 4 opt-out tests + 2 load_iseq tests pass; total suite up to ~57 runs, 0 failures, 0 errors.

If the `load_iseq` tests fail because Ruby's `load` caches the file and doesn't re-invoke `load_iseq` on repeated runs, each test is fine since they use different constants. If they fail because the hook isn't being invoked at all, verify `RubyVM::InstructionSequence.singleton_class` actually dispatches to the defined `load_iseq` method — Ruby's internals may call it via a different mechanism that `define_method` doesn't override. In that case, use `class << RubyVM::InstructionSequence; def load_iseq(path); ...; end; end` directly in install/uninstall (closure-free) and stash the hook as a class-level state.

- [ ] **Step 5: Commit**

```
jj commit -m "Add load_iseq harness with opt-out and fallback"
```

(files: `optimizer/lib/ruby_opt/harness.rb`, `optimizer/test/harness_test.rb`, `optimizer/test/harness_fixtures/plain.rb`, `optimizer/test/harness_fixtures/opted_out.rb`)

---

### Task 12: Update README with the new surface

**Files:**
- Modify: `optimizer/README.md`

**Context:** Bring the README's "Status" and "Layout" sections up to date now that the optimizer core and harness are in place.

- [ ] **Step 1: Replace the relevant README sections**

Read the current `optimizer/README.md`, then replace the `## Status` and `## Layout` sections with:

```markdown
## Status

- **Binary codec**: round-trippable decoder/encoder for YARB binaries.
  Modifications to `IR::Function#instructions` are re-encoded (same-byte-count
  substitutions). Length-changing edits (required for inlining) are a future
  plan.
- **IR**: `IR::Function` (one per iseq), `IR::Instruction` (one per YARV op),
  `IR::BasicBlock` and `IR::CFG` for control-flow analysis.
- **Passes**: base class (`RubyOpt::Pass`), orchestrator (`RubyOpt::Pipeline`),
  hardcoded contract (`RubyOpt::Contract`), structured log (`RubyOpt::Log`).
  A `NoopPass` ships as proof-of-life. Real passes come in subsequent plans.
- **Type env**: `RubyOpt::RbsParser` extracts inline `@rbs` signatures;
  `RubyOpt::TypeEnv` exposes `#signature_for`.
- **Harness**: `RubyOpt::Harness::LoadIseqHook` installs a `load_iseq`
  override that runs the pipeline on every loaded file. Opt out with
  `# rbs-optimize: false` at the top of the file. Any failure falls back
  to MRI's built-in compilation.

## Layout

- `lib/ruby_opt/codec/` — YARB binary surgery
- `lib/ruby_opt/ir/` — `Function`, `Instruction`, `BasicBlock`, `CFG`
- `lib/ruby_opt/pass.rb` — Pass base class + NoopPass
- `lib/ruby_opt/pipeline.rb` — pass orchestration
- `lib/ruby_opt/contract.rb` — the hardcoded ground rules
- `lib/ruby_opt/log.rb` — structured optimizer log
- `lib/ruby_opt/rbs_parser.rb` — inline `@rbs` extraction
- `lib/ruby_opt/type_env.rb` — typed-environment queries
- `lib/ruby_opt/harness.rb` — `load_iseq` override
- `test/` — minitest suites, fixtures under `test/harness_fixtures/`
```

- [ ] **Step 2: Commit**

```
jj commit -m "Update README with optimizer core surface"
```

(files: `optimizer/README.md`)

---

## Self-review

Skim the spec (`docs/superpowers/specs/2026-04-19-optimizer.md`) against this plan:

- **IR with CFG** — Tasks 2, 3 ✓
- **Contract** — Task 4 ✓
- **Log** — Task 5 ✓
- **Pipeline of passes** — Tasks 6, 7 ✓
- **Type env from inline RBS** — Tasks 8, 9 ✓
- **Round-trippable encode** — Task 1 (partial: same-byte-count only; length changes deferred)
- **Harness with opt-out** — Tasks 10, 11 ✓
- **Pass order** — specified in pipeline spec, enforced by caller at install time (not in this plan)
- **Demo-log format** — Task 5 ✓ (entries carry pass, reason, file, line)

Gaps to call out for the next plan (pass plans):

- **Length-changing instruction edits** are not supported yet. Inlining will require extending `InstructionStream.encode` and re-serializing the iseq body section from IR rather than splicing over raw bytes.
- **`TypeEnv#class_of` / `#resolve_call`** are not implemented. Passes that need them (inlining, arith specialization) will extend `TypeEnv` as part of their own plans.
- **Branch operand normalization** (Task 3 Step 5) may surface a latent codec bug; if the round-trip tests break during Task 3, fix it there rather than deferring.
