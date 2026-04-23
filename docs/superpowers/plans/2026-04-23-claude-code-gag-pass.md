# Claude Code Gag Pass — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a runnable demo driver that serializes an IR function to JSON, sends it to `claude -p`, validates structurally + semantically with up-to-3 retry loop feeding validator errors back, and renders the full transcript as a committed demo artifact for the talk's §7 close.

**Architecture:** New namespace `Optimize::Demo::Claude` (outside `Pipeline.default`), driven by a new `bin/demo-claude` entry point. Six small focused files: `claude.rb` (orchestrator), `claude/serializer.rb`, `claude/validator.rb`, `claude/prompt.rb`, `claude/invoker.rb`, `claude/transcript.rb`. Tested via stubbed `Invoker` for the loop; real `claude -p` only runs during `rake demo:regenerate_claude` (opt-in).

**Tech Stack:** Ruby 4.0, existing `Optimize::Codec`, `RubyVM::InstructionSequence.load_from_binary`, `Open3.capture3` for the `claude` CLI, minitest, existing demo-artifact pattern.

**Spec:** `docs/superpowers/specs/2026-04-23-claude-code-gag-pass-design.md`

---

## File Structure

**New files:**
- `optimizer/examples/claude_gag.rb` — fixture (`def answer; 2 + 3; end`)
- `optimizer/lib/optimize/demo/claude.rb` — top-level orchestrator
- `optimizer/lib/optimize/demo/claude/serializer.rb` — IR ↔ JSON array
- `optimizer/lib/optimize/demo/claude/validator.rb` — structural + semantic
- `optimizer/lib/optimize/demo/claude/prompt.rb` — initial + retry prompts
- `optimizer/lib/optimize/demo/claude/invoker.rb` — `claude -p` shell I/O
- `optimizer/lib/optimize/demo/claude/transcript.rb` — markdown render
- `optimizer/bin/demo-claude` — CLI entry point
- `optimizer/test/demo/claude/serializer_test.rb`
- `optimizer/test/demo/claude/validator_test.rb`
- `optimizer/test/demo/claude/prompt_test.rb`
- `optimizer/test/demo/claude/transcript_test.rb`
- `optimizer/test/demo/claude_integration_test.rb`
- `docs/demo_artifacts/claude_gag.md` — captured transcript (final task)

**Modified files:**
- `optimizer/Rakefile` — new `demo:regenerate_claude` task
- `mcp-server/Dockerfile.test` — install `claude` CLI (optional; covered in Task 11)
- `docs/todo.md` — strike §7 gag item

---

## Task 1: Fixture

**Files:**
- Create: `optimizer/examples/claude_gag.rb`

- [ ] **Step 1: Create the fixture.**

```ruby
# frozen_string_literal: true

def answer
  2 + 3
end
```

- [ ] **Step 2: Verify it loads and returns 5.**

Run: `cd optimizer && bundle exec ruby -Ilib -e 'require "./examples/claude_gag"; raise unless answer == 5; puts "ok"'`
Expected: `ok`

- [ ] **Step 3: Commit.**

```bash
jj commit -m "feat(demo): claude_gag fixture"
```

---

## Task 2: Serializer — happy path test

**Files:**
- Create: `optimizer/test/demo/claude/serializer_test.rb`
- Create: `optimizer/lib/optimize/demo/claude/serializer.rb`

- [ ] **Step 1: Write failing test for `serialize`.**

```ruby
# frozen_string_literal: true
require "test_helper"
require "optimize/harness"
require "optimize/codec"
require "optimize/demo/claude/serializer"

module Optimize
  module Demo
    module Claude
      class SerializerTest < Minitest::Test
        def decode_source(src)
          iseq = RubyVM::InstructionSequence.compile(src)
          envelope = Codec.decode(iseq.to_binary)
          envelope.iseq_list.fetch(0) # top-level function
        end

        def test_serialize_emits_tuple_per_instruction
          fn = decode_source("2 + 3")
          arr = Serializer.serialize(fn)
          assert_kind_of Array, arr
          assert arr.all? { |t| t.is_a?(Array) && t.first.is_a?(String) }
          # Must contain at least the literal pushes + opt_plus + leave
          opcodes = arr.map(&:first)
          assert_includes opcodes, "putobject"
          assert_includes opcodes, "opt_plus"
          assert_includes opcodes, "leave"
        end

        def test_serialize_resolves_value_operands
          fn = decode_source("2 + 3")
          arr = Serializer.serialize(fn)
          putobjects = arr.select { |t| t.first == "putobject" }
          # Operands are resolved Ruby values, not object-table indices
          values = putobjects.map { |t| t[1] }
          assert_includes values, 2
          assert_includes values, 3
        end

        def test_serialize_call_data_as_hash
          fn = decode_source("2 + 3")
          arr = Serializer.serialize(fn)
          plus = arr.find { |t| t.first == "opt_plus" }
          assert plus, "expected opt_plus"
          cd = plus[1]
          assert_kind_of Hash, cd
          assert_equal "+", cd.fetch("mid")
          assert_equal 1, cd.fetch("argc")
        end
      end
    end
  end
end
```

- [ ] **Step 2: Run the test, confirm it fails.**

Run: `cd optimizer && bundle exec rake test TEST=test/demo/claude/serializer_test.rb`
Expected: FAIL with `cannot load such file -- optimize/demo/claude/serializer`

- [ ] **Step 3: Implement `serialize`.**

Create `optimizer/lib/optimize/demo/claude/serializer.rb`:

```ruby
# frozen_string_literal: true
require "optimize/ir/instruction"

module Optimize
  module Demo
    module Claude
      # IR <-> JSON-serializable array of [opcode_string, *operands] tuples.
      #
      # Operand handling:
      #   TS_VALUE / TS_ID  -> resolved Ruby value (integer, symbol string, string literal)
      #   TS_CALLDATA       -> Hash {"mid" => String, "argc" => Integer, "flag" => Integer}
      #   TS_OFFSET / TS_LINDEX / TS_NUM -> Integer
      #   TS_ISEQ           -> Integer (iseq-list index)
      #
      # Locals, insns_info, line entries, and catch table are NOT part of
      # the JSON; they are carried over verbatim from the original function
      # on deserialize. Claude does not get to rewrite iseq-level metadata.
      module Serializer
        module_function

        def serialize(function)
          function.instructions.map { |insn| serialize_instruction(function, insn) }
        end

        def serialize_instruction(function, insn)
          tuple = [insn.opcode.to_s]
          insn.operands.each_with_index do |op, i|
            tuple << serialize_operand(function, insn.opcode, i, op)
          end
          tuple
        end

        def serialize_operand(function, opcode, idx, op)
          kinds = RubyVM::InstructionSequence
                    .instance_method(:to_a) # keep require trail clean
          # Lookup via call_data list on the function for CD operands.
          cd = resolve_call_data(function, opcode, idx, op)
          return cd if cd

          case op
          when Integer, Symbol, String, TrueClass, FalseClass, NilClass
            op.is_a?(Symbol) ? op.to_s : op
          else
            op.inspect
          end
        end

        def resolve_call_data(function, opcode, idx, op)
          return nil unless %i[send opt_send_without_block invokesuper
                               opt_plus opt_minus opt_mult opt_div opt_mod
                               opt_eq opt_neq opt_lt opt_le opt_gt opt_ge
                               opt_ltlt opt_and opt_or opt_not opt_aref
                               opt_aset opt_length opt_size opt_empty_p
                               opt_succ opt_regexpmatch2 opt_aref_with
                               opt_aset_with opt_str_freeze opt_str_uminus
                               opt_nil_p opt_hash_freeze opt_ary_freeze
                               opt_call_c_function].include?(opcode)
          cd = function.call_data[op]
          return nil unless cd
          {
            "mid"  => cd.mid.to_s,
            "argc" => cd.argc,
            "flag" => cd.flag,
          }
        end
      end
    end
  end
end
```

- [ ] **Step 4: Run the test — it should pass.**

Run: `cd optimizer && bundle exec rake test TEST=test/demo/claude/serializer_test.rb`
Expected: 3 passing.

- [ ] **Step 5: Commit.**

```bash
jj commit -m "feat(demo/claude): serializer — IR to JSON array"
```

---

## Task 3: Serializer — deserialize

**Files:**
- Modify: `optimizer/test/demo/claude/serializer_test.rb`
- Modify: `optimizer/lib/optimize/demo/claude/serializer.rb`

- [ ] **Step 1: Add a failing round-trip test.**

Append to `serializer_test.rb` inside the `SerializerTest` class:

```ruby
def test_deserialize_round_trip_preserves_opcodes
  fn = decode_source("2 + 3")
  json = Serializer.serialize(fn)
  restored = Serializer.deserialize(json, template: fn)
  assert_equal fn.instructions.map(&:opcode),
               restored.instructions.map(&:opcode)
end

def test_deserialize_raises_on_unknown_opcode_in_strict_mode
  fn = decode_source("2 + 3")
  bad = [["not_a_real_opcode"]]
  assert_raises(Serializer::DeserializeError) do
    Serializer.deserialize(bad, template: fn, strict: true)
  end
end

def test_deserialize_tolerates_unknown_opcode_in_lax_mode
  fn = decode_source("2 + 3")
  bad = [["not_a_real_opcode"], ["leave"]]
  # Lax mode: the IR round-trips even if opcodes aren't in the insn
  # table; validator (not serializer) flags unknowns.
  restored = Serializer.deserialize(bad, template: fn, strict: false)
  assert_equal %i[not_a_real_opcode leave],
               restored.instructions.map(&:opcode)
end
```

- [ ] **Step 2: Run test to verify failures.**

Run: `cd optimizer && bundle exec rake test TEST=test/demo/claude/serializer_test.rb`
Expected: 3 failures — `Serializer.deserialize` undefined.

- [ ] **Step 3: Implement `deserialize`.**

Add to `serializer.rb` inside `module Serializer`:

```ruby
class DeserializeError < StandardError; end

KNOWN_OPCODES = RubyVM::INSTRUCTION_NAMES.map(&:to_sym).to_set.freeze

def self.deserialize(json, template:, strict: false)
  raise DeserializeError, "expected Array, got #{json.class}" unless json.is_a?(Array)

  new_instructions = json.each_with_index.map do |tuple, i|
    unless tuple.is_a?(Array) && tuple.first.is_a?(String)
      raise DeserializeError, "tuple #{i} is not [String, *ops]: #{tuple.inspect}"
    end
    opcode = tuple.first.to_sym
    if strict && !KNOWN_OPCODES.include?(opcode)
      raise DeserializeError, "unknown opcode :#{opcode} at index #{i}"
    end
    operands = tuple.drop(1).map do |op|
      op.is_a?(Hash) ? deserialize_call_data(template, op) : op
    end
    IR::Instruction.new(opcode: opcode, operands: operands, line: nil)
  end

  # Clone template, swap instructions. CallData, locals, catch_table,
  # line entries all reused from template.
  template.dup.tap do |fn|
    fn.instructions = new_instructions
  end
end

def self.deserialize_call_data(template, hash)
  mid  = hash.fetch("mid").to_sym
  argc = hash.fetch("argc")
  flag = hash.fetch("flag", 0)
  existing = template.call_data.find { |cd| cd.mid == mid && cd.argc == argc && cd.flag == flag }
  return template.call_data.index(existing) if existing
  # New CD: append to template's call_data. Claude can only invent CDs
  # that are structurally well-formed; whether the call makes sense is
  # a semantic-validator concern.
  new_cd = template.call_data.first.class.new(mid: mid, argc: argc, flag: flag)
  template.call_data << new_cd
  template.call_data.size - 1
end
```

Note: confirm that `IR::Function` has a writable `instructions` accessor. If not, add an `attr_accessor` in `ir/function.rb` as part of this task — but check first; it may already be writable.

- [ ] **Step 4: Run tests — pass.**

Run: `cd optimizer && bundle exec rake test TEST=test/demo/claude/serializer_test.rb`
Expected: 6 passing.

- [ ] **Step 5: Commit.**

```bash
jj commit -m "feat(demo/claude): serializer — deserialize with lax/strict modes"
```

---

## Task 4: Validator — structural

**Files:**
- Create: `optimizer/test/demo/claude/validator_test.rb`
- Create: `optimizer/lib/optimize/demo/claude/validator.rb`

- [ ] **Step 1: Write failing structural tests.**

```ruby
# frozen_string_literal: true
require "test_helper"
require "optimize/demo/claude/serializer"
require "optimize/demo/claude/validator"

module Optimize
  module Demo
    module Claude
      class ValidatorTest < Minitest::Test
        def decode_source(src)
          iseq = RubyVM::InstructionSequence.compile(src)
          envelope = Optimize::Codec.decode(iseq.to_binary)
          envelope.iseq_list.fetch(0)
        end

        def test_structural_passes_on_clean_ir
          fn = decode_source("2 + 3")
          errors = Validator.structural(fn)
          assert_empty errors
        end

        def test_structural_reports_unknown_opcode
          fn = decode_source("2 + 3")
          fn.instructions << Optimize::IR::Instruction.new(
            opcode: :opt_fastmath, operands: [], line: nil
          )
          errors = Validator.structural(fn)
          assert errors.any? { |e| e.include?("opt_fastmath") && e.include?("unknown") }
        end

        def test_structural_reports_arity_mismatch
          fn = decode_source("2 + 3")
          # putobject takes exactly 1 operand
          fn.instructions << Optimize::IR::Instruction.new(
            opcode: :putobject, operands: [], line: nil
          )
          errors = Validator.structural(fn)
          assert errors.any? { |e| e.include?("putobject") && e.include?("operand") }
        end
      end
    end
  end
end
```

- [ ] **Step 2: Run — fails (no Validator).**

Run: `cd optimizer && bundle exec rake test TEST=test/demo/claude/validator_test.rb`
Expected: 3 errors.

- [ ] **Step 3: Implement structural validator.**

```ruby
# frozen_string_literal: true
require "set"

module Optimize
  module Demo
    module Claude
      module Validator
        module_function

        KNOWN_OPCODES = RubyVM::INSTRUCTION_NAMES.map(&:to_sym).to_set.freeze

        # Hand-derived arity table: opcode => operand count.
        # Source: insns.def / compile.c. Only the opcodes our fixtures
        # can plausibly emit are listed; unknown opcodes in this table
        # bypass arity checking (structural pass still catches them
        # via KNOWN_OPCODES).
        ARITY = {
          putnil: 0, putself: 0, leave: 0, pop: 0, dup: 0, swap: 0,
          putobject: 1, putstring: 1, putobject_INT2FIX_0_: 0, putobject_INT2FIX_1_: 0,
          getlocal: 2, setlocal: 2, getlocal_WC_0: 1, setlocal_WC_0: 1,
          getlocal_WC_1: 1, setlocal_WC_1: 1,
          getinstancevariable: 2, setinstancevariable: 2,
          getconstant: 1,
          opt_plus: 1, opt_minus: 1, opt_mult: 1, opt_div: 1, opt_mod: 1,
          opt_eq: 1, opt_neq: 1, opt_lt: 1, opt_le: 1, opt_gt: 1, opt_ge: 1,
          opt_send_without_block: 1, send: 2,
          branchif: 1, branchunless: 1, branchnil: 1, jump: 1,
          nop: 0,
        }.freeze

        def structural(function)
          errors = []
          function.instructions.each_with_index do |insn, i|
            unless KNOWN_OPCODES.include?(insn.opcode)
              errors << "instruction #{i}: unknown opcode :#{insn.opcode}"
              next
            end
            expected = ARITY[insn.opcode]
            actual = insn.operands.size
            if expected && expected != actual
              errors << "instruction #{i}: opcode :#{insn.opcode} takes #{expected} operand(s), got #{actual}"
            end
          end
          errors
        end
      end
    end
  end
end
```

- [ ] **Step 4: Run — pass.**

Run: `cd optimizer && bundle exec rake test TEST=test/demo/claude/validator_test.rb`
Expected: 3 passing.

- [ ] **Step 5: Commit.**

```bash
jj commit -m "feat(demo/claude): validator — structural opcode + arity"
```

---

## Task 5: Validator — semantic

**Files:**
- Modify: `optimizer/test/demo/claude/validator_test.rb`
- Modify: `optimizer/lib/optimize/demo/claude/validator.rb`

- [ ] **Step 1: Add failing semantic tests.**

Append to `ValidatorTest` class:

```ruby
def test_semantic_passes_when_iseq_returns_expected
  fn = decode_source("2 + 3")
  errors = Validator.semantic(fn, expected: 5)
  assert_empty errors
end

def test_semantic_reports_wrong_return_value
  fn = decode_source("2 + 3")
  errors = Validator.semantic(fn, expected: 999)
  assert errors.any? { |e| e.include?("999") && (e.include?("5") || e.include?("returned")) }
end

def test_semantic_reports_crash_on_malformed_iseq
  fn = decode_source("2 + 3")
  # Chop off `leave` — loader or VM will fail.
  fn.instructions = fn.instructions.reject { |i| i.opcode == :leave }
  errors = Validator.semantic(fn, expected: 5)
  refute_empty errors
end
```

- [ ] **Step 2: Run — fails.**

- [ ] **Step 3: Implement semantic validator.**

Append to `validator.rb`:

```ruby
require "optimize/codec"

def self.semantic(function, expected:)
  errors = []
  begin
    envelope = function.envelope # assumes IR::Function#envelope returns the enclosing envelope
    binary = Optimize::Codec.encode(envelope)
    iseq = RubyVM::InstructionSequence.load_from_binary(binary)
    result = iseq.eval
    unless result == expected
      errors << "iseq returned #{result.inspect}; expected #{expected.inspect}"
    end
  rescue => e
    errors << "loader/runtime error: #{e.class}: #{e.message}"
  end
  errors
end
```

Note: if `IR::Function#envelope` back-reference doesn't exist, the test fixture needs to pass in an envelope. Check `optimizer/lib/optimize/ir/function.rb` first. If the API is function-only, rework so `semantic` takes the envelope as a second required arg:

```ruby
def self.semantic(envelope, expected:)
  # ... encode envelope, load, eval
end
```

Adjust tests accordingly (store envelope in `decode_source` return).

- [ ] **Step 4: Run — pass.**

- [ ] **Step 5: Commit.**

```bash
jj commit -m "feat(demo/claude): validator — semantic encode-load-run"
```

---

## Task 6: Prompt builder

**Files:**
- Create: `optimizer/test/demo/claude/prompt_test.rb`
- Create: `optimizer/lib/optimize/demo/claude/prompt.rb`
- Create: `optimizer/test/demo/claude/fixtures/initial_prompt.txt` (golden)
- Create: `optimizer/test/demo/claude/fixtures/retry_prompt.txt` (golden)

- [ ] **Step 1: Write failing tests with golden files.**

```ruby
# frozen_string_literal: true
require "test_helper"
require "optimize/demo/claude/prompt"

module Optimize
  module Demo
    module Claude
      class PromptTest < Minitest::Test
        FIXTURES = File.expand_path("fixtures", __dir__)

        def test_initial_matches_golden
          out = Prompt.initial(
            source:        "def answer; 2 + 3; end",
            expected:      5,
            iseq_json:     [["putobject", 2], ["putobject", 3], ["opt_plus", {"mid" => "+", "argc" => 1, "flag" => 16}], ["leave"]],
          )
          golden = File.read(File.join(FIXTURES, "initial_prompt.txt"))
          assert_equal golden, out
        end

        def test_retry_matches_golden
          out = Prompt.retry_message(errors: [
            "instruction 3: unknown opcode :opt_fastmath",
            "iseq returned 7; expected 5",
          ])
          golden = File.read(File.join(FIXTURES, "retry_prompt.txt"))
          assert_equal golden, out
        end
      end
    end
  end
end
```

Create `optimizer/test/demo/claude/fixtures/initial_prompt.txt` (exact contents; if the test fails, update this file to match the emitted string the first time, then lock it in):

```
You are given a YARV iseq as a JSON array of instructions. Emit a semantically equivalent but optimized iseq.

Constraints:
- Output a single JSON array of [opcode_string, ...operands] tuples.
- Each opcode must be a real YARV opcode (examples: putobject, opt_plus, opt_minus, opt_mult, opt_div, opt_mod, leave, pop, dup, getlocal_WC_0, setlocal_WC_0).
- Preserve stack discipline: the iseq must end with a value on the stack, consumed by `leave`.
- Do not add or remove locals; the local table is fixed.
- Call-data operands are objects of the form {"mid": String, "argc": Integer, "flag": Integer}.

Fixture source:
def answer; 2 + 3; end

Expected return value: 5

Input iseq:
[["putobject",2],["putobject",3],["opt_plus",{"mid":"+","argc":1,"flag":16}],["leave"]]

Reply with ONLY the JSON array. No prose, no fences.
```

And `retry_prompt.txt`:

```
Your previous response was rejected:
- instruction 3: unknown opcode :opt_fastmath
- iseq returned 7; expected 5

Emit a corrected iseq as a JSON array. Reply with ONLY the JSON array.
```

- [ ] **Step 2: Run — fails.**

- [ ] **Step 3: Implement prompt.**

```ruby
# frozen_string_literal: true
require "json"

module Optimize
  module Demo
    module Claude
      module Prompt
        module_function

        INITIAL_TEMPLATE = <<~PROMPT
          You are given a YARV iseq as a JSON array of instructions. Emit a semantically equivalent but optimized iseq.

          Constraints:
          - Output a single JSON array of [opcode_string, ...operands] tuples.
          - Each opcode must be a real YARV opcode (examples: putobject, opt_plus, opt_minus, opt_mult, opt_div, opt_mod, leave, pop, dup, getlocal_WC_0, setlocal_WC_0).
          - Preserve stack discipline: the iseq must end with a value on the stack, consumed by `leave`.
          - Do not add or remove locals; the local table is fixed.
          - Call-data operands are objects of the form {"mid": String, "argc": Integer, "flag": Integer}.

          Fixture source:
          %<source>s

          Expected return value: %<expected>s

          Input iseq:
          %<iseq_json>s

          Reply with ONLY the JSON array. No prose, no fences.
        PROMPT

        def initial(source:, expected:, iseq_json:)
          format(INITIAL_TEMPLATE,
                 source:    source.strip,
                 expected:  expected.inspect,
                 iseq_json: JSON.generate(iseq_json))
        end

        def retry_message(errors:)
          lines = errors.map { |e| "- #{e}" }.join("\n")
          <<~PROMPT
            Your previous response was rejected:
            #{lines}

            Emit a corrected iseq as a JSON array. Reply with ONLY the JSON array.
          PROMPT
        end
      end
    end
  end
end
```

- [ ] **Step 4: Run — pass. Adjust goldens if whitespace differs (then commit them).**

- [ ] **Step 5: Commit.**

```bash
jj commit -m "feat(demo/claude): prompt builder + golden fixtures"
```

---

## Task 7: Invoker

**Files:**
- Create: `optimizer/test/demo/claude/invoker_test.rb`
- Create: `optimizer/lib/optimize/demo/claude/invoker.rb`

- [ ] **Step 1: Write failing tests using a stubbed `Open3`.**

```ruby
# frozen_string_literal: true
require "test_helper"
require "optimize/demo/claude/invoker"

module Optimize
  module Demo
    module Claude
      class InvokerTest < Minitest::Test
        def test_call_extracts_result_from_claude_json
          fake_out = JSON.generate(
            "type" => "result",
            "subtype" => "success",
            "result" => "[[\"putobject\",5],[\"leave\"]]",
          )
          Open3.stub(:capture3, [fake_out, "", stub_status(0)]) do
            json = Invoker.call(prompt: "hi")
            assert_equal [["putobject", 5], ["leave"]], json
          end
        end

        def test_call_raises_on_nonzero_exit
          Open3.stub(:capture3, ["", "boom", stub_status(1)]) do
            assert_raises(Invoker::CLIError) { Invoker.call(prompt: "hi") }
          end
        end

        def test_call_raises_on_unparseable_claude_output
          Open3.stub(:capture3, ["not json at all", "", stub_status(0)]) do
            assert_raises(Invoker::CLIError) { Invoker.call(prompt: "hi") }
          end
        end

        private

        def stub_status(code)
          Struct.new(:exitstatus, :success?).new(code, code.zero?)
        end
      end
    end
  end
end
```

- [ ] **Step 2: Run — fails.**

- [ ] **Step 3: Implement.**

```ruby
# frozen_string_literal: true
require "open3"
require "json"

module Optimize
  module Demo
    module Claude
      # Thin wrapper around `claude -p --output-format json`.
      # Single responsibility: shell I/O. No retry, no validation.
      module Invoker
        class CLIError < StandardError; end

        module_function

        # Returns the JSON-parsed "result" field. The `claude -p` JSON envelope
        # looks like {"type":"result","subtype":"success","result":"<assistant text>", ...}.
        # The `result` field is a JSON-encoded string of the assistant's text;
        # we JSON.parse it a second time to get the IR array.
        def call(prompt:, binary: "claude")
          out, err, status = Open3.capture3(binary, "-p", "--output-format", "json",
                                            stdin_data: prompt)
          unless status.success?
            raise CLIError, "#{binary} exited #{status.exitstatus}: #{err}"
          end

          envelope = begin
            JSON.parse(out)
          rescue JSON::ParserError => e
            raise CLIError, "could not parse #{binary} JSON envelope: #{e.message}"
          end

          result_text = envelope["result"] or
            raise CLIError, "#{binary} envelope missing 'result' field: #{envelope.inspect}"

          begin
            JSON.parse(result_text)
          rescue JSON::ParserError => e
            raise CLIError, "could not parse assistant JSON: #{e.message}\n---\n#{result_text}"
          end
        end
      end
    end
  end
end
```

- [ ] **Step 4: Run — pass.**

- [ ] **Step 5: Commit.**

```bash
jj commit -m "feat(demo/claude): invoker — claude -p shell wrapper"
```

---

## Task 8: Transcript renderer

**Files:**
- Create: `optimizer/test/demo/claude/transcript_test.rb`
- Create: `optimizer/test/demo/claude/fixtures/transcript_success.md`
- Create: `optimizer/test/demo/claude/fixtures/transcript_gave_up.md`
- Create: `optimizer/lib/optimize/demo/claude/transcript.rb`

- [ ] **Step 1: Write failing golden tests.**

```ruby
# frozen_string_literal: true
require "test_helper"
require "optimize/demo/claude/transcript"

module Optimize
  module Demo
    module Claude
      class TranscriptTest < Minitest::Test
        FIXTURES = File.expand_path("fixtures", __dir__)

        def test_renders_success_after_two_failures
          t = Transcript.new(fixture: "claude_gag", source: "def answer; 2 + 3; end", expected: 5)
          t.record(iteration: 1, prompt: "prompt1", raw: "[[\"bad\"]]", parsed: [["bad"]], errors: ["instruction 0: unknown opcode :bad"])
          t.record(iteration: 2, prompt: "prompt2", raw: "[[\"putobject\",7],[\"leave\"]]", parsed: [["putobject", 7], ["leave"]], errors: ["iseq returned 7; expected 5"])
          t.record(iteration: 3, prompt: "prompt3", raw: "[[\"putobject\",5],[\"leave\"]]", parsed: [["putobject", 5], ["leave"]], errors: [])
          t.finish(outcome: :success)
          assert_equal File.read(File.join(FIXTURES, "transcript_success.md")), t.render
        end

        def test_renders_gave_up
          t = Transcript.new(fixture: "claude_gag", source: "def answer; 2 + 3; end", expected: 5)
          3.times do |i|
            t.record(iteration: i + 1, prompt: "p", raw: "r", parsed: [], errors: ["err#{i}"])
          end
          t.finish(outcome: :gave_up)
          assert_equal File.read(File.join(FIXTURES, "transcript_gave_up.md")), t.render
        end
      end
    end
  end
end
```

Create fixtures (fill in after first run; hand-write to be stable):

`transcript_success.md`:

````markdown
# Claude gag — claude_gag

**Fixture source:**

```ruby
def answer; 2 + 3; end
```

**Expected return value:** `5`

## Iteration 1

**Prompt:**

```
prompt1
```

**Raw response:**

```
[["bad"]]
```

**Parsed IR:**

```json
[["bad"]]
```

**Validator errors:**
- instruction 0: unknown opcode :bad

## Iteration 2

**Prompt:**

```
prompt2
```

**Raw response:**

```
[["putobject",7],["leave"]]
```

**Parsed IR:**

```json
[["putobject",7],["leave"]]
```

**Validator errors:**
- iseq returned 7; expected 5

## Iteration 3

**Prompt:**

```
prompt3
```

**Raw response:**

```
[["putobject",5],["leave"]]
```

**Parsed IR:**

```json
[["putobject",5],["leave"]]
```

**Validator errors:** (none)

## Outcome: success
````

`transcript_gave_up.md` — same shape, 3 iterations with errors, ends with `## Outcome: gave up after 3 attempts`.

- [ ] **Step 2: Run — fails.**

- [ ] **Step 3: Implement.**

```ruby
# frozen_string_literal: true
require "json"

module Optimize
  module Demo
    module Claude
      class Transcript
        def initialize(fixture:, source:, expected:)
          @fixture = fixture
          @source = source
          @expected = expected
          @iterations = []
          @outcome = nil
        end

        def record(iteration:, prompt:, raw:, parsed:, errors:)
          @iterations << {iteration: iteration, prompt: prompt, raw: raw, parsed: parsed, errors: errors}
        end

        def finish(outcome:)
          @outcome = outcome
        end

        def render
          parts = []
          parts << "# Claude gag — #{@fixture}"
          parts << ""
          parts << "**Fixture source:**"
          parts << ""
          parts << "```ruby"
          parts << @source.strip
          parts << "```"
          parts << ""
          parts << "**Expected return value:** `#{@expected.inspect}`"
          parts << ""
          @iterations.each { |it| parts.concat(render_iteration(it)) }
          parts << outcome_line
          parts << ""
          parts.join("\n")
        end

        private

        def render_iteration(it)
          lines = []
          lines << "## Iteration #{it[:iteration]}"
          lines << ""
          lines << "**Prompt:**"
          lines << ""
          lines << "```"
          lines << it[:prompt]
          lines << "```"
          lines << ""
          lines << "**Raw response:**"
          lines << ""
          lines << "```"
          lines << it[:raw]
          lines << "```"
          lines << ""
          lines << "**Parsed IR:**"
          lines << ""
          lines << "```json"
          lines << JSON.generate(it[:parsed])
          lines << "```"
          lines << ""
          if it[:errors].empty?
            lines << "**Validator errors:** (none)"
          else
            lines << "**Validator errors:**"
            it[:errors].each { |e| lines << "- #{e}" }
          end
          lines << ""
          lines
        end

        def outcome_line
          case @outcome
          when :success then "## Outcome: success"
          when :gave_up then "## Outcome: gave up after #{@iterations.size} attempts"
          else raise "unknown outcome #{@outcome.inspect}"
          end
        end
      end
    end
  end
end
```

- [ ] **Step 4: Run — pass (update fixtures once if whitespace differs, then lock in).**

- [ ] **Step 5: Commit.**

```bash
jj commit -m "feat(demo/claude): transcript renderer + goldens"
```

---

## Task 9: Orchestrator + integration test

**Files:**
- Create: `optimizer/test/demo/claude_integration_test.rb`
- Create: `optimizer/lib/optimize/demo/claude.rb`

- [ ] **Step 1: Write failing integration test with stubbed Invoker.**

```ruby
# frozen_string_literal: true
require "test_helper"
require "optimize/demo/claude"

module Optimize
  module Demo
    class ClaudeIntegrationTest < Minitest::Test
      class FakeInvoker
        def initialize(responses)
          @responses = responses.dup
        end

        def call(prompt:, **)
          raise "no more responses" if @responses.empty?
          @responses.shift
        end
      end

      def test_success_on_third_try
        responses = [
          [["bad_opcode"]],
          [["putobject", 7], ["leave"]],
          [["putobject", 5], ["leave"]],
        ]
        outcome = Claude.run(
          fixture_path: File.expand_path("../../examples/claude_gag.rb", __dir__),
          expected: 5,
          invoker: FakeInvoker.new(responses),
          max_iterations: 3,
        )
        assert_equal :success, outcome.outcome
        assert_equal 3, outcome.iterations.size
      end

      def test_gave_up_after_three_failures
        responses = [
          [["bad1"]],
          [["bad2"]],
          [["bad3"]],
        ]
        outcome = Claude.run(
          fixture_path: File.expand_path("../../examples/claude_gag.rb", __dir__),
          expected: 5,
          invoker: FakeInvoker.new(responses),
          max_iterations: 3,
        )
        assert_equal :gave_up, outcome.outcome
        assert_equal 3, outcome.iterations.size
      end
    end
  end
end
```

- [ ] **Step 2: Run — fails.**

- [ ] **Step 3: Implement orchestrator.**

```ruby
# frozen_string_literal: true
require "optimize/codec"
require "optimize/demo/claude/serializer"
require "optimize/demo/claude/validator"
require "optimize/demo/claude/prompt"
require "optimize/demo/claude/invoker"
require "optimize/demo/claude/transcript"

module Optimize
  module Demo
    module Claude
      Outcome = Struct.new(:outcome, :iterations, :transcript, keyword_init: true)

      module_function

      def run(fixture_path:, expected:, invoker: Invoker, max_iterations: 3)
        source = File.read(fixture_path)
        iseq = RubyVM::InstructionSequence.compile_file(fixture_path)
        envelope = Optimize::Codec.decode(iseq.to_binary)
        function = envelope.iseq_list.fetch(0)

        iseq_json = Serializer.serialize(function)
        transcript = Transcript.new(
          fixture: File.basename(fixture_path, ".rb"),
          source: source,
          expected: expected,
        )

        history = Prompt.initial(source: source, expected: expected, iseq_json: iseq_json)
        prior_errors = nil

        max_iterations.times do |i|
          prompt =
            if prior_errors.nil?
              history
            else
              "#{history}\n\n#{Prompt.retry_message(errors: prior_errors)}"
            end
          raw = invoker.call(prompt: prompt)

          # `invoker` may return either a pre-parsed Array (test stub) or a
          # raw JSON string (live Invoker). Normalize.
          parsed = raw.is_a?(String) ? JSON.parse(raw) : raw

          attempt = Serializer.deserialize(parsed, template: function, strict: false)
          errors = Validator.structural(attempt)
          if errors.empty?
            errors = Validator.semantic(envelope_with(attempt, envelope), expected: expected)
          end

          transcript.record(
            iteration: i + 1,
            prompt: prompt,
            raw: raw.to_s,
            parsed: parsed,
            errors: errors,
          )

          if errors.empty?
            transcript.finish(outcome: :success)
            return Outcome.new(outcome: :success, iterations: transcript_iterations(transcript), transcript: transcript)
          end

          prior_errors = errors
        end

        transcript.finish(outcome: :gave_up)
        Outcome.new(outcome: :gave_up, iterations: transcript_iterations(transcript), transcript: transcript)
      end

      def envelope_with(function, original_envelope)
        # Shallow swap the first iseq_list entry. Codec.encode reads from the
        # envelope's iseq_list; all other metadata is reused.
        cloned = original_envelope.dup
        cloned.iseq_list = original_envelope.iseq_list.dup
        cloned.iseq_list[0] = function
        cloned
      end

      def transcript_iterations(transcript)
        transcript.instance_variable_get(:@iterations)
      end
    end
  end
end
```

Note: `envelope_with` and the `attr_accessor :iseq_list` on `IseqEnvelope` may or may not exist. Check `optimizer/lib/optimize/codec/iseq_envelope.rb`; if not writable, either add an accessor or use `dup`-with-swap per whatever idiom the codec uses internally.

- [ ] **Step 4: Run — pass.**

- [ ] **Step 5: Commit.**

```bash
jj commit -m "feat(demo/claude): orchestrator — 3-try retry loop"
```

---

## Task 10: CLI entry point

**Files:**
- Create: `optimizer/bin/demo-claude`

- [ ] **Step 1: Write the bin.**

```ruby
#!/usr/bin/env ruby
# frozen_string_literal: true
require "bundler/setup"
require "optimize/demo/claude"

fixture = File.expand_path("../examples/claude_gag.rb", __dir__)
output  = File.expand_path("../../docs/demo_artifacts/claude_gag.md", __dir__)

outcome = Optimize::Demo::Claude.run(fixture_path: fixture, expected: 5)
File.write(output, outcome.transcript.render)
puts "wrote #{output}"
puts "outcome: #{outcome.outcome}"
```

- [ ] **Step 2: Make it executable.**

```bash
chmod +x optimizer/bin/demo-claude
```

- [ ] **Step 3: Do NOT run live yet.** This will shell out to `claude` which needs setup from Task 11.

- [ ] **Step 4: Commit.**

```bash
jj commit -m "feat(demo/claude): bin/demo-claude entry point"
```

---

## Task 11: Docker image — install claude CLI

**Files:**
- Modify: `mcp-server/Dockerfile.test`
- Reference: https://docs.claude.com/en/docs/claude-code/quickstart for install command

- [ ] **Step 1: Add `claude` install to the Dockerfile.**

Edit `mcp-server/Dockerfile.test`:

```dockerfile
FROM ruby:4.0.2-slim
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends \
    build-essential git docker.io ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

# Install Claude Code CLI. Uses the official installer script. Requires
# a setup-token or ANTHROPIC_API_KEY at runtime, passed via `docker run -e`.
RUN curl -fsSL https://claude.ai/install.sh | bash || true
ENV PATH="/root/.local/bin:${PATH}"

WORKDIR /w
COPY Gemfile Gemfile.lock* ./
RUN bundle config set --local path vendor/bundle && bundle install
COPY . .
CMD ["bundle", "exec", "ruby", "bin/ruby-bytecode-mcp"]
```

Note: the install URL above is a placeholder — verify the current official install command before running. If the Ruby Docker image can't install the CLI this way (e.g., it needs Node), swap to `npm install -g @anthropic-ai/claude-code` with a Node install step above it. Adjust as needed; the task is "claude binary is on PATH in the built image."

- [ ] **Step 2: Build and smoke test.**

```bash
docker build -t ruby-bytecode-mcp-test -f mcp-server/Dockerfile.test mcp-server
docker run --rm ruby-bytecode-mcp-test which claude
```

Expected: prints a path (e.g., `/root/.local/bin/claude`) and exits 0.

- [ ] **Step 3: Commit.**

```bash
jj commit -m "build(docker): install claude CLI in mcp test image"
```

---

## Task 12: Rake task — regenerate_claude

**Files:**
- Modify: `optimizer/Rakefile`

- [ ] **Step 1: Add the task.**

Append to `optimizer/Rakefile`, inside the `namespace :demo` block:

```ruby
desc "Regenerate docs/demo_artifacts/claude_gag.md (requires ANTHROPIC_API_KEY or claude setup-token). Non-deterministic: review the diff."
task :regenerate_claude do
  unless ENV["ANTHROPIC_API_KEY"] || ENV["CLAUDE_CODE_SSO_TOKEN"]
    warn "Warning: neither ANTHROPIC_API_KEY nor CLAUDE_CODE_SSO_TOKEN set."
    warn "If `claude setup-token` hasn't been run in this environment, the invocation will fail."
  end
  warn "This will overwrite docs/demo_artifacts/claude_gag.md. Claude's output is non-deterministic; review the diff before committing."
  sh "bin/demo-claude"
end
```

- [ ] **Step 2: Verify it's listed.**

Run: `cd optimizer && bundle exec rake -T demo:`
Expected: `demo:regenerate_claude` appears in the listing.

- [ ] **Step 3: Verify `demo:verify` does NOT try to call claude.**

Run: `cd optimizer && bundle exec rake demo:verify`
Expected: still passes against existing fixtures. `claude_gag.md` does not yet exist, so `demo:verify` will fail with "missing committed artifact: claude_gag" — that's expected for now and gets fixed in Task 13.

Actually, to avoid a failing `demo:verify` between this task and Task 13, scope the verify loop to sidecars only (it already uses `*.walkthrough.yml`, and `claude_gag.rb` has no sidecar — so verify will skip it). Confirm this by reading the `demo:verify` task body: it globs `*.walkthrough.yml`, claude_gag has none, so it's naturally skipped. Good.

- [ ] **Step 4: Commit.**

```bash
jj commit -m "build(rake): demo:regenerate_claude task"
```

---

## Task 13: Capture the transcript

**Prerequisite:** Docker image from Task 11 built, `claude setup-token` run (or `ANTHROPIC_API_KEY` exported) in the host or container.

**Files:**
- Create: `docs/demo_artifacts/claude_gag.md`

- [ ] **Step 1: Run the regenerator.**

Run: `cd optimizer && bundle exec rake demo:regenerate_claude`

Expected: `wrote .../docs/demo_artifacts/claude_gag.md` + `outcome: <success|gave_up>`.

- [ ] **Step 2: Review the transcript.**

Read `docs/demo_artifacts/claude_gag.md`. Confirm:
- Fixture source appears at top.
- 1–3 iteration sections, each with prompt / raw / parsed / errors.
- Outcome line at bottom.

If the transcript is unusable (e.g., Claude refused entirely and there's no useful comedy), rerun. You get one rerun before committing; the non-determinism is part of the frame but if the captured run is actively bad (no iteration-loop visible), rerun.

- [ ] **Step 3: Commit.**

```bash
jj commit -m "docs(demo): claude_gag captured transcript"
```

---

## Task 14: Wire into `demo:verify` + update todo

**Files:**
- Modify: `optimizer/Rakefile`
- Modify: `docs/todo.md`

- [ ] **Step 1: Extend `demo:verify` to also checksum `claude_gag.md`.**

In `optimizer/Rakefile`, inside the `demo:verify` task body, after the sidecars loop, add:

```ruby
# Claude gag has no sidecar (non-deterministic, regenerated opt-in).
# Verify only checks it exists and is non-empty — not content-equality.
claude_artifact = File.join(committed_dir, "claude_gag.md")
if File.exist?(claude_artifact) && File.size(claude_artifact) > 0
  # ok
else
  mismatches << "claude_gag.md missing or empty"
end
```

- [ ] **Step 2: Run verify.**

Run: `cd optimizer && bundle exec rake demo:verify`
Expected: `demo:verify OK (3 fixtures)` (or however many sidecars exist).

- [ ] **Step 3: Update `docs/todo.md`.**

In the "Roadmap gap, ranked by talk-ROI" list, strike item 5:

```markdown
5. ~~**Claude Code gag pass.** §7 close. Scripted output is fine.~~
   **Shipped 2026-04-23.** Plan: `docs/superpowers/plans/2026-04-23-claude-code-gag-pass.md`.
   Spec: `docs/superpowers/specs/2026-04-23-claude-code-gag-pass-design.md`.
   `Optimize::Demo::Claude` drives a 3-try retry loop (structural +
   semantic validator errors fed back to `claude -p` each retry) over
   the `claude_gag` fixture; transcript captured to
   `docs/demo_artifacts/claude_gag.md`. Not in `Pipeline.default`.
   Regeneration is opt-in via `rake demo:regenerate_claude` (needs
   setup-token); `demo:verify` only checks the file is non-empty
   (Claude's output is non-deterministic).
```

Also update the "Cross-cutting infrastructure not yet built" section:
- Strike "Claude Code gag pass. §7 of talk-structure. Not specced." (now specced and shipped).

And update the "Last updated:" line at the top to today + mention claude_gag.

- [ ] **Step 4: Commit.**

```bash
jj commit -m "docs(todo): strike claude code gag pass — shipped"
```

---

## Self-review

**Spec coverage:**
- Architecture (new namespace, outside Pipeline.default): Tasks 2–10 ✓
- Six components per spec: Tasks 2, 4, 5, 6, 7, 8, 9 ✓
- Data flow (serialize → claude → validate → feedback loop): Task 9 ✓
- Serialization format (JSON tuples, CD as hash, metadata carried over): Tasks 2, 3 ✓
- Prompt shape: Task 6 ✓
- Three error tiers: Task 7 (Tier 1 CLI), Task 4 (Tier 3 structural), Task 5 (Tier 3 semantic), Task 9 (Tier 2 parse → feeds back as validator error — not explicitly covered; adding as a note in Task 9 is sufficient). **Gap:** Tier 2 parse failure path. Claude may return unparseable JSON; Invoker raises CLIError which currently aborts the whole run. Spec says it should feed back as a validator error. **Fix:** Task 9's orchestrator must rescue `Invoker::CLIError` where the cause is parse-level and convert it to a validator error rather than propagating. This is a small addition; apply in Task 9 implementation — wrap the `invoker.call` in a rescue that distinguishes "could not parse" from "binary exited non-zero" and only converts the former. Spec amendment: Invoker's `CLIError` should probably be split into `CLIError` (fatal) and `ParseError` (feeds back). Update Task 7 to expose `ParseError` and Task 9 to rescue it. — **Action: revisit Tasks 7 and 9 during implementation to add this split; noting here so the executor sees it.**
- Exhaustion path: Task 9 ✓
- Determinism (verify doesn't hit network, regenerate is opt-in): Tasks 12, 14 ✓
- Docker changes: Task 11 ✓
- Testing (unit + integration, no live CI calls): Tasks 2–9 ✓
- Docker smoke test: Task 11 step 2 ✓
- Fixture: Task 1 ✓

**Placeholder scan:** one explicit placeholder in Task 11 — the install URL. Flagged inline with a note to verify the current official command. Acceptable: the installer URL is an implementation detail, not a design ambiguity.

**Type consistency:** `Serializer.serialize(function)` and `Serializer.deserialize(json, template:, strict:)` used consistently. `Validator.structural(function)` and `Validator.semantic(envelope, expected:)` — note the semantic one takes envelope, not function, because it needs to encode. Task 5 flags this inconsistency and resolves it (pass envelope to `semantic`; adjust tests). Task 9 orchestrator uses `envelope_with(function, envelope)` to build the envelope before calling `semantic`. Consistent.

**Split of `CLIError` → `CLIError` + `ParseError`:** flagged in self-review above; executor should apply during Task 7 and Task 9.
