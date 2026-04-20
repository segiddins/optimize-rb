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
  lib/ruby_opt/
    passes/
      const_fold_pass.rb        # NEW — the pass
      literal_value.rb          # NEW — shared literal-read/emit helper
    pipeline.rb                 # MODIFIED (default pipeline uses ConstFoldPass)
  test/
    passes/
      literal_value_test.rb     # NEW — operand encoding investigation + helpers
      const_fold_pass_test.rb   # NEW — unit + end-to-end
      const_fold_pass_corpus_test.rb  # NEW — corpus regression under default pipeline
```

---

### Task 1: `LiteralValue` helper — read and emit Integer literals

**Context:** Two knowns from empirical inspection of Ruby 4.0.2 disasm output:

- `putobject_INT2FIX_0_` and `putobject_INT2FIX_1_` are dedicated no-operand opcodes for the literals 0 and 1. They round-trip through the existing codec already.
- For other integer literals, CRuby emits `putobject <value>` where the operand is a small_value.

**Unknown (resolve in this task):** whether `putobject`'s `operands[0]` in our decoded `IR::Instruction` is (a) the raw Ruby VALUE — `(n << 1) | 1` for fixnums — or (b) an object-table index. The answer determines how we emit a freshly-folded literal.

This task writes an investigation test that decodes a known fixture, reads the operand shape, and implements a `LiteralValue` module whose two entry points are:

- `LiteralValue.read(inst)` → the Integer the instruction produces, or `nil` if it's not a recognized integer literal producer
- `LiteralValue.emit(value, line:)` → a new `IR::Instruction` that pushes `value` onto the stack (preferring the dedicated INT2FIX opcodes for 0 and 1; falling back to `putobject` for other integers; emits `putobject` for `true`/`false` using the `Qtrue`/`Qfalse` special-const VALUEs `20` and `0`)

**Files:**
- Create: `optimizer/lib/ruby_opt/passes/literal_value.rb`
- Create: `optimizer/test/passes/literal_value_test.rb`

- [ ] **Step 1: Write the investigation + behavior test** — `optimizer/test/passes/literal_value_test.rb`

```ruby
# frozen_string_literal: true
require "test_helper"
require "ruby_opt/codec"
require "ruby_opt/passes/literal_value"

class LiteralValueTest < Minitest::Test
  # Investigation: inspect the putobject operand encoding for a small
  # non-0/non-1 integer. The test documents what we find so future
  # readers can see the format at a glance.
  def test_putobject_two_operand_shape
    ir = RubyOpt::Codec.decode(
      RubyVM::InstructionSequence.compile("def f; 2; end; f").to_binary
    )
    f = find_iseq(ir, "f")
    po = f.instructions.find { |i| i.opcode == :putobject }
    refute_nil po, "expected a plain putobject for literal 2"
    # Whatever the stored shape is, LiteralValue.read must return 2.
    assert_equal 2, RubyOpt::Passes::LiteralValue.read(po)
  end

  def test_read_handles_dedicated_0_and_1_opcodes
    ir = RubyOpt::Codec.decode(
      RubyVM::InstructionSequence.compile("def f; 0; end; def g; 1; end").to_binary
    )
    f = find_iseq(ir, "f")
    g = find_iseq(ir, "g")
    zero = f.instructions.find { |i| i.opcode == :putobject_INT2FIX_0_ }
    one  = g.instructions.find { |i| i.opcode == :putobject_INT2FIX_1_ }
    refute_nil zero, "expected a putobject_INT2FIX_0_"
    refute_nil one,  "expected a putobject_INT2FIX_1_"
    assert_equal 0, RubyOpt::Passes::LiteralValue.read(zero)
    assert_equal 1, RubyOpt::Passes::LiteralValue.read(one)
  end

  def test_read_returns_nil_for_non_literal_producer
    ir = RubyOpt::Codec.decode(
      RubyVM::InstructionSequence.compile("def f; x = 1; x; end").to_binary
    )
    f = find_iseq(ir, "f")
    getlocal = f.instructions.find { |i| i.opcode.to_s.start_with?("getlocal") }
    refute_nil getlocal
    assert_nil RubyOpt::Passes::LiteralValue.read(getlocal)
  end

  def test_emit_prefers_dedicated_opcodes_for_0_and_1
    zero = RubyOpt::Passes::LiteralValue.emit(0, line: 42)
    one  = RubyOpt::Passes::LiteralValue.emit(1, line: 42)
    assert_equal :putobject_INT2FIX_0_, zero.opcode
    assert_equal :putobject_INT2FIX_1_, one.opcode
    assert_empty zero.operands
    assert_empty one.operands
    assert_equal 42, zero.line
    assert_equal 42, one.line
  end

  def test_emit_falls_through_to_plain_putobject_for_other_integers
    inst = RubyOpt::Passes::LiteralValue.emit(42, line: 7)
    assert_equal :putobject, inst.opcode
    # Whatever the operand shape the codec expects, a round-trip through
    # read must recover the value.
    assert_equal 42, RubyOpt::Passes::LiteralValue.read(inst)
    assert_equal 7, inst.line
  end

  def test_emit_true_and_false_use_putobject_with_special_const_value
    t = RubyOpt::Passes::LiteralValue.emit(true,  line: 1)
    f = RubyOpt::Passes::LiteralValue.emit(false, line: 1)
    assert_equal :putobject, t.opcode
    assert_equal :putobject, f.opcode
    assert_equal true,  RubyOpt::Passes::LiteralValue.read(t)
    assert_equal false, RubyOpt::Passes::LiteralValue.read(f)
  end

  def test_emit_round_trips_through_codec
    # Sanity check: encoding unmodified IR still round-trips byte-identically.
    src = "def f; 2 + 3; end; f"
    ir = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    assert_equal(
      RubyVM::InstructionSequence.compile(src).to_binary,
      RubyOpt::Codec.encode(ir),
    )
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

- [ ] **Step 2: Run, expect LoadError** for `ruby_opt/passes/literal_value`

Run: `mcp__ruby-bytecode__run_optimizer_tests` with `test_filter: "test/passes/literal_value_test.rb"`.

Expected: `cannot load such file -- ruby_opt/passes/literal_value`.

- [ ] **Step 3: Implement `LiteralValue`** — `optimizer/lib/ruby_opt/passes/literal_value.rb`

Implement the module. The behavior contract is fully specified by the tests above. The specific operand encoding for non-0/1 Integer literals — whether `operands[0]` is the raw VALUE `(n<<1)|1` or an object-table index — is determined by running the investigation test in Step 2 (it will fail until you inspect the actual operand and write the right `read` / `emit` code).

Start here, finish the two methods after running the Step 2 test once:

```ruby
# frozen_string_literal: true
require "ruby_opt/ir/instruction"

module RubyOpt
  module Passes
    # Reads and emits Integer and boolean literal-producer instructions.
    #
    # Ruby 4.0.2 has three shapes for "push a literal":
    #   putobject_INT2FIX_0_          — pushes 0 (no operand)
    #   putobject_INT2FIX_1_          — pushes 1 (no operand)
    #   putobject <value>             — pushes any other literal
    #
    # For the plain `putobject` form, the operand encoding is documented
    # in the test-driven spike above.
    module LiteralValue
      module_function

      # @param inst [IR::Instruction]
      # @return [Integer, true, false, nil] the pushed value, or nil if
      #   the instruction is not a recognized literal producer
      def read(inst)
        # ...resolve via inst.opcode / inst.operands as the test dictates
      end

      # @param value [Integer, true, false]
      # @param line  [Integer, nil]
      # @return [IR::Instruction]
      def emit(value, line:)
        # ...return the right opcode form per the tests
      end
    end
  end
end
```

**If the investigation reveals** that plain `putobject` stores an object-table index (rather than the raw VALUE), then `emit(value, …)` for an integer not already in the table cannot work with just this helper — the pass would need to extend the object table, which is out of scope for this plan. In that case: halt, report the finding, and escalate. The `LiteralValue.emit` test for `42` is the canary.

- [ ] **Step 4: Run tests via MCP, expect all 7 to pass.**

Run: `mcp__ruby-bytecode__run_optimizer_tests` with `test_filter: "test/passes/literal_value_test.rb"`.

- [ ] **Step 5: Full-suite regression via MCP.** Expected: previous 79 tests + 7 new = 86, 0 failures.

- [ ] **Step 6: Commit**

```
jj commit -m "Add LiteralValue read/emit helper for const-fold pass"
```

(Files: `optimizer/lib/ruby_opt/passes/literal_value.rb`, `optimizer/test/passes/literal_value_test.rb`.)

---

### Task 2: `ConstFoldPass` — single-triple Integer arithmetic fold

**Context:** Simplest working slice: one forward scan, arithmetic ops only (`opt_plus`, `opt_minus`, `opt_mult`, `opt_div`, `opt_mod`). The step-back-after-fold pattern is introduced here so simple chains work; the outer fixpoint arrives in Task 4. Comparisons arrive in Task 3, skip logging in Task 5.

**Files:**
- Create: `optimizer/lib/ruby_opt/passes/const_fold_pass.rb`
- Create: `optimizer/test/passes/const_fold_pass_test.rb`

- [ ] **Step 1: Write the failing test** — `optimizer/test/passes/const_fold_pass_test.rb`

```ruby
# frozen_string_literal: true
require "test_helper"
require "ruby_opt/codec"
require "ruby_opt/log"
require "ruby_opt/passes/const_fold_pass"

class ConstFoldPassTest < Minitest::Test
  def test_folds_single_arithmetic_triple
    ir = RubyOpt::Codec.decode(
      RubyVM::InstructionSequence.compile("def f; 2 + 3; end; f").to_binary
    )
    f = find_iseq(ir, "f")
    before_count = f.instructions.size
    log = RubyOpt::Log.new
    RubyOpt::Passes::ConstFoldPass.new.apply(f, type_env: nil, log: log)
    # Three instructions collapse to one: net -2.
    assert_equal before_count - 2, f.instructions.size
    folded = f.instructions.find { |i| RubyOpt::Passes::LiteralValue.read(i) == 5 }
    refute_nil folded, "expected a literal producer for 5 after the fold"
  end

  def test_folded_iseq_runs_and_returns_expected_value
    src = "def f; 2 + 3; end; f"
    ir = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    RubyOpt::Passes::ConstFoldPass.new.apply(find_iseq(ir, "f"), type_env: nil, log: RubyOpt::Log.new)
    loaded = RubyVM::InstructionSequence.load_from_binary(RubyOpt::Codec.encode(ir))
    assert_equal 5, loaded.eval
  end

  def test_leaves_non_literal_operands_alone
    ir = RubyOpt::Codec.decode(
      RubyVM::InstructionSequence.compile("def f(x); x + 2; end").to_binary
    )
    f = find_iseq(ir, "f")
    before = f.instructions.map(&:opcode)
    RubyOpt::Passes::ConstFoldPass.new.apply(f, type_env: nil, log: RubyOpt::Log.new)
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

- [ ] **Step 3: Implement `ConstFoldPass`** — `optimizer/lib/ruby_opt/passes/const_fold_pass.rb`

```ruby
# frozen_string_literal: true
require "ruby_opt/pass"
require "ruby_opt/passes/literal_value"

module RubyOpt
  module Passes
    class ConstFoldPass < RubyOpt::Pass
      ARITH_OPS = {
        opt_plus:  :+,
        opt_minus: :-,
        opt_mult:  :*,
        opt_div:   :/,
        opt_mod:   :%,
      }.freeze

      def apply(function, type_env:, log:)
        _ = type_env # unused in tier 1
        insts = function.instructions
        return unless insts

        i = 0
        while i <= insts.size - 3
          a  = insts[i]
          b  = insts[i + 1]
          op = insts[i + 2]
          new_inst = try_fold_arith(a, b, op, function, log)
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

      def try_fold_arith(a, b, op, function, log)
        sym = ARITH_OPS[op.opcode]
        return nil unless sym
        av = LiteralValue.read(a)
        bv = LiteralValue.read(b)
        return nil unless av.is_a?(Integer) && bv.is_a?(Integer)
        result = av.public_send(sym, bv)
        LiteralValue.emit(result, line: a.line)
      rescue StandardError
        nil # would raise at runtime — leave the triple alone
      end
    end
  end
end
```

- [ ] **Step 4: Run the three test cases via MCP, expect pass.**

- [ ] **Step 5: Full-suite regression via MCP.** Expected: 89 runs, 0 failures. Any codec fixture that regressed means the length-changing encode path is off — diagnose before moving on (this is the first *real* length-changing mutation).

- [ ] **Step 6: Commit**

```
jj commit -m "ConstFoldPass: fold literal Integer arithmetic triples"
```

(Files: `optimizer/lib/ruby_opt/passes/const_fold_pass.rb`, `optimizer/test/passes/const_fold_pass_test.rb`.)

---

### Task 3: Extend to comparison ops

**Context:** Add `opt_lt`, `opt_le`, `opt_gt`, `opt_ge`, `opt_eq`, `opt_neq` using the same triple shape. Result is `true`/`false`, emitted via `LiteralValue.emit(bool, ...)`.

**Files:**
- Modify: `optimizer/lib/ruby_opt/passes/const_fold_pass.rb`
- Modify: `optimizer/test/passes/const_fold_pass_test.rb`

- [ ] **Step 1: Add failing tests** to `const_fold_pass_test.rb`

```ruby
  def test_folds_integer_comparison_to_boolean
    ir = RubyOpt::Codec.decode(
      RubyVM::InstructionSequence.compile("def f; 5 < 10; end; f").to_binary
    )
    f = find_iseq(ir, "f")
    RubyOpt::Passes::ConstFoldPass.new.apply(f, type_env: nil, log: RubyOpt::Log.new)
    folded = f.instructions.find { |i| RubyOpt::Passes::LiteralValue.read(i) == true }
    refute_nil folded
    loaded = RubyVM::InstructionSequence.load_from_binary(RubyOpt::Codec.encode(ir))
    assert_equal true, loaded.eval
  end

  def test_folds_integer_equality
    ir = RubyOpt::Codec.decode(
      RubyVM::InstructionSequence.compile("def f; 5 == 5; end; def g; 5 == 6; end").to_binary
    )
    f = find_iseq(ir, "f")
    g = find_iseq(ir, "g")
    pass = RubyOpt::Passes::ConstFoldPass.new
    pass.apply(f, type_env: nil, log: RubyOpt::Log.new)
    pass.apply(g, type_env: nil, log: RubyOpt::Log.new)
    assert(f.instructions.any? { |i| RubyOpt::Passes::LiteralValue.read(i) == true })
    assert(g.instructions.any? { |i| RubyOpt::Passes::LiteralValue.read(i) == false })
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

def try_fold_triple(a, b, op, function, log)
  sym = FOLDABLE_OPS[op.opcode]
  return nil unless sym
  av = LiteralValue.read(a)
  bv = LiteralValue.read(b)
  return nil unless av.is_a?(Integer) && bv.is_a?(Integer)
  result = av.public_send(sym, bv)
  LiteralValue.emit(result, line: a.line)
rescue StandardError
  nil
end
```

Update the `apply` body's call to use the new name. `LiteralValue.emit` already handles the boolean result type.

- [ ] **Step 4: Run full const-fold test file via MCP, expect pass.**

- [ ] **Step 5: Full-suite regression via MCP.** Expected: 91 runs, 0 failures.

- [ ] **Step 6: Commit**

```
jj commit -m "ConstFoldPass: fold Integer comparison triples (lt/le/gt/ge/eq/neq)"
```

(Files: `optimizer/lib/ruby_opt/passes/const_fold_pass.rb`, `optimizer/test/passes/const_fold_pass_test.rb`.)

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
- Modify: `optimizer/lib/ruby_opt/passes/const_fold_pass.rb`
- Modify: `optimizer/test/passes/const_fold_pass_test.rb`

- [ ] **Step 1: Add failing test for deep chain**

```ruby
  def test_folds_deep_integer_chain_to_single_literal
    src = "def f; 1 + 2 + 3 + 4 + 5; end; f"
    ir = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    f = find_iseq(ir, "f")
    log = RubyOpt::Log.new
    RubyOpt::Passes::ConstFoldPass.new.apply(f, type_env: nil, log: log)
    folded = f.instructions.find { |i| RubyOpt::Passes::LiteralValue.read(i) == 15 }
    refute_nil folded, "expected the whole chain to fold to 15"
    loaded = RubyVM::InstructionSequence.load_from_binary(RubyOpt::Codec.encode(ir))
    assert_equal 15, loaded.eval
  end

  def test_partial_chain_fold_when_a_non_literal_breaks_it
    src = "def f(x); 1 + 2 + x + 3 + 4; end; f(10)"
    ir = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    f = find_iseq(ir, "f")
    RubyOpt::Passes::ConstFoldPass.new.apply(f, type_env: nil, log: RubyOpt::Log.new)
    # The literal-only prefix (1+2) folds to 3, AND the literal-only
    # suffix (3+4) folds to 7 — `x` in the middle breaks the chain but
    # each sub-chain folds independently.
    values = f.instructions.filter_map { |i| RubyOpt::Passes::LiteralValue.read(i) }
    assert_includes values, 3
    assert_includes values, 7
    loaded = RubyVM::InstructionSequence.load_from_binary(RubyOpt::Codec.encode(ir))
    assert_equal 20, loaded.eval # 3 + 10 + 7
  end
```

- [ ] **Step 2: Run, expect failure** if any triple-shape the step-back misses.

- [ ] **Step 3: Add an outer fixpoint loop** around the inner scan — safety net for any triple-shape the step-back misses:

```ruby
def apply(function, type_env:, log:)
  _ = type_env
  insts = function.instructions
  return unless insts

  loop do
    folded_any = false
    i = 0
    while i <= insts.size - 3
      a, b, op = insts[i], insts[i + 1], insts[i + 2]
      new_inst = try_fold_triple(a, b, op, function, log)
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

- [ ] **Step 5: Full-suite regression via MCP.** Expected: 93 runs, 0 failures.

- [ ] **Step 6: Commit**

```
jj commit -m "ConstFoldPass: chain folding via internal fixpoint"
```

(Files: `optimizer/lib/ruby_opt/passes/const_fold_pass.rb`, `optimizer/test/passes/const_fold_pass_test.rb`.)

---

### Task 5: Skip and fold logging

**Context:** The talk uses the log as a feature: "the optimizer tells you what it folded and what it couldn't." Three reasons to cover:

- `:folded` — successful fold, one per triple replaced
- `:would_raise` — the operation would raise at runtime (div/mod by zero)
- `:non_integer_literal` — two `putobject`s where at least one holds a non-Integer/non-Boolean literal (e.g. a String) and the op is still an arith/compare op

**The `Log#skip` signature** only takes `pass:, reason:, file:, line:`. Folds are recorded through the same interface — reason `:folded` — to keep the pipeline's existing log shape. (A richer "fold detail" field can come in a follow-up; the talk's first slide just needs counts by reason.)

**Files:**
- Modify: `optimizer/lib/ruby_opt/passes/const_fold_pass.rb`
- Modify: `optimizer/test/passes/const_fold_pass_test.rb`

- [ ] **Step 1: Add failing tests**

```ruby
  def test_logs_folded_reason_for_each_successful_fold
    src = "def f; 1 + 2 + 3; end; f"
    ir = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    log = RubyOpt::Log.new
    RubyOpt::Passes::ConstFoldPass.new.apply(find_iseq(ir, "f"), type_env: nil, log: log)
    folded_entries = log.for_pass(:const_fold).select { |e| e.reason == :folded }
    # 1+2 → 3, then 3+3 → 6 (folded triples in sequence)
    assert_operator folded_entries.size, :>=, 2
  end

  def test_logs_would_raise_for_division_by_zero
    src = "def f; 1 / 0; end"
    ir = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    f = find_iseq(ir, "f")
    before = f.instructions.map(&:opcode)
    log = RubyOpt::Log.new
    RubyOpt::Passes::ConstFoldPass.new.apply(f, type_env: nil, log: log)
    # The triple is left alone.
    assert_equal before, f.instructions.map(&:opcode)
    skipped = log.for_pass(:const_fold).select { |e| e.reason == :would_raise }
    assert_operator skipped.size, :>=, 1, "expected a :would_raise skip entry"
  end

  def test_logs_non_integer_literal_when_string_operand_reaches_an_arith_op
    src = 'def f; "a" + "b"; end'
    ir = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    f = find_iseq(ir, "f")
    log = RubyOpt::Log.new
    RubyOpt::Passes::ConstFoldPass.new.apply(f, type_env: nil, log: log)
    skipped = log.for_pass(:const_fold).select { |e| e.reason == :non_integer_literal }
    assert_operator skipped.size, :>=, 1
  end
```

- [ ] **Step 2: Run, expect failure.**

- [ ] **Step 3: Wire logging into `try_fold_triple`**:

```ruby
def try_fold_triple(a, b, op, function, log)
  sym = FOLDABLE_OPS[op.opcode]
  return nil unless sym
  av = LiteralValue.read(a)
  bv = LiteralValue.read(b)

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
  LiteralValue.emit(result, line: a.line)
rescue StandardError
  log.skip(pass: :const_fold, reason: :would_raise,
           file: function.path, line: (op.line || a.line || function.first_lineno))
  nil
end
```

Note: `Log#skip` is the one interface we have — we reuse it for `:folded` too. If the pipeline spec later grows a distinct `Log#fold` method, this pass migrates. For now, `:folded` is just a reason tag alongside the skip reasons.

- [ ] **Step 4: Run new tests via MCP, expect pass.**

- [ ] **Step 5: Full-suite regression via MCP.** Expected: 96 runs, 0 failures.

- [ ] **Step 6: Commit**

```
jj commit -m "ConstFoldPass: log :folded, :would_raise, :non_integer_literal"
```

(Files: `optimizer/lib/ruby_opt/passes/const_fold_pass.rb`, `optimizer/test/passes/const_fold_pass_test.rb`.)

---

### Task 6: Wire into default pipeline + corpus regression

**Context:** The pipeline currently runs `NoopPass` by default (or tests construct a pipeline explicitly). This task adds a `Pipeline.default` factory, makes `ConstFoldPass` the only default pass, and runs the full codec corpus through it to confirm no regression.

**Files:**
- Modify: `optimizer/lib/ruby_opt/pipeline.rb`
- Modify: `optimizer/test/pipeline_test.rb`
- Create: `optimizer/test/passes/const_fold_pass_corpus_test.rb`

- [ ] **Step 1: Read current pipeline wiring**

Read `optimizer/lib/ruby_opt/pipeline.rb` and `optimizer/test/pipeline_test.rb`. Confirm there is no existing `Pipeline.default`; this task adds it.

- [ ] **Step 2: Add a failing default-pipeline test** — `optimizer/test/pipeline_test.rb`

Append:

```ruby
  def test_default_pipeline_folds_integer_literals_in_every_function
    require "ruby_opt/pipeline"
    require "ruby_opt/passes/literal_value"
    ir = RubyOpt::Codec.decode(
      RubyVM::InstructionSequence.compile("def f; 2 + 3; end; f").to_binary
    )
    pipeline = RubyOpt::Pipeline.default
    pipeline.run(ir, type_env: nil)
    f = ir.children.flat_map { |c| [c, *(c.children || [])] }.find { |x| x.name == "f" }
    assert(f.instructions.any? { |i| RubyOpt::Passes::LiteralValue.read(i) == 5 })
  end
```

- [ ] **Step 3: Add `Pipeline.default`** — `optimizer/lib/ruby_opt/pipeline.rb`:

Add at the top of the file, inside the class body:

```ruby
require "ruby_opt/passes/const_fold_pass"

# ... inside class Pipeline:

def self.default
  new([Passes::ConstFoldPass.new])
end
```

- [ ] **Step 4: Write the corpus regression test** — `optimizer/test/passes/const_fold_pass_corpus_test.rb`

```ruby
# frozen_string_literal: true
require "test_helper"
require "ruby_opt/codec"
require "ruby_opt/pipeline"

class ConstFoldPassCorpusTest < Minitest::Test
  def test_every_corpus_fixture_loads_and_runs_through_default_pipeline
    corpus = Dir[File.expand_path("../codec/corpus/*.rb", __dir__)]
    skip "no codec corpus" if corpus.empty?
    corpus.each do |path|
      src = File.read(path)
      ir = RubyOpt::Codec.decode(
        RubyVM::InstructionSequence.compile(src, path).to_binary
      )
      RubyOpt::Pipeline.default.run(ir, type_env: nil)
      bin = RubyOpt::Codec.encode(ir)
      loaded = RubyVM::InstructionSequence.load_from_binary(bin)
      assert_kind_of RubyVM::InstructionSequence, loaded,
        "#{File.basename(path)} did not re-load after the default pipeline"
    end
  end
end
```

- [ ] **Step 5: Run both tests via MCP, expect pass.**

Run: `mcp__ruby-bytecode__run_optimizer_tests` with `test_filter: "test/pipeline_test.rb test/passes/const_fold_pass_corpus_test.rb"`.

- [ ] **Step 6: Full-suite regression via MCP.** Expected: 98 runs, 0 failures.

If any corpus fixture fails: the fold is producing a shape the codec can't re-emit. Bisect by disabling the pass on that fixture and see whether the raw codec path still works; if so, the bug is in `LiteralValue.emit`'s operand form.

- [ ] **Step 7: Commit**

```
jj commit -m "Wire ConstFoldPass into default pipeline + corpus regression test"
```

(Files: `optimizer/lib/ruby_opt/pipeline.rb`, `optimizer/test/pipeline_test.rb`, `optimizer/test/passes/const_fold_pass_corpus_test.rb`.)

---

### Task 7: Benchmark demo + README update

**Context:** One benchmark case via `mcp__ruby-bytecode__benchmark_ips` that documents the win (folded vs. unfolded), and a README line noting that `ConstFoldPass` (tier 1) is available.

**Files:**
- Modify: `optimizer/README.md`

- [ ] **Step 1: Read current README.**

- [ ] **Step 2: Add a "Passes" section** (or update an existing one). One paragraph:

```
## Passes

- `RubyOpt::Passes::ConstFoldPass` — tier 1 constant folding. Folds
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
- Line annotation inheritance from first removed instruction — Task 2 (`LiteralValue.emit(result, line: a.line)`).
- Pipeline placement as last/only default pass — Task 6.
- Codec interaction (dangling refs, stack_max, iseq_size handled by codec) — no pass-side work required.
- Corpus regression — Task 6.
- Benchmark demo — Task 7.

Gaps: none.

**Placeholder scan:** one explicit spike — the operand-encoding investigation in Task 1, Step 3. Resolution is scripted (read the failing test output, inspect the operand, write the right code). The "If the investigation reveals [...]" escalation condition names the exact observable (the `42` emit test) that would trigger it. No other TBDs survive.

**Type consistency:** `LiteralValue.read`/`.emit` signatures match across Tasks 1–4. `FOLDABLE_OPS` (Task 3) replaces `ARITH_OPS` (Task 2) in one place with matching call sites. `Log#skip` is the sole log interface used. `try_fold_triple` is named consistently from Task 3 onward.

**Known unknown:** the operand encoding for plain `putobject` with integers > 1. Surfaced and resolved in Task 1.

**Gaps for follow-up plans:** String / Array / Kernel tier 1 shapes, tier 2 (frozen constants), tier 3 (type-guided), tier 4 (ENV) — each its own plan. Cross-block constant propagation — out of scope.
