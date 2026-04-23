# Identity Elim Pass v1 — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Ship `IdentityElimPass`: strip `x * 1`, `x + 0`, `x - 0`, `x / 1` (and commutative siblings) when the non-literal side is a side-effect-free producer. Land the talk's "three passes, three tables" slide.

**Spec:** `docs/superpowers/specs/2026-04-21-pass-identity-elim-design.md`.

**Tech Stack:** Ruby 4.0.2, minitest, the `ruby-bytecode` MCP for all test runs.

**Baseline test count before this plan: 161 green.** Expected after: 161 + ~14 unit + 1 pipeline = ~176 green.

**Commit discipline:** Each task ends with `jj commit -m "<msg>"` — never `jj describe -m`. Parallel subagent commits use `jj split -m "<msg>" -- <files>` with the exact file list from the task. Tests via `mcp__ruby-bytecode__run_optimizer_tests` only. Ruby evaluation via `mcp__ruby-bytecode__run_ruby`. Never host shell.

---

## File structure

```
optimizer/
  lib/optimize/
    passes/
      identity_elim_pass.rb               # NEW Task 1
    pipeline.rb                           # MODIFIED Task 2
  test/
    passes/
      identity_elim_pass_test.rb          # NEW Task 1
    codec/corpus/
      identity_elim.rb                    # NEW Task 2
optimizer/README.md                        # MODIFIED Task 3 (optional)
```

---

### Task 1: Pass + unit tests (TDD, no pipeline wiring)

**Context:** Implement `IdentityElimPass` in isolation — construct the pass, exercise it directly on `InstructionSequence.compile` → `Codec.decode` IR, assert transformations. Do NOT wire it into `Pipeline.default` yet; that's Task 2. This keeps the blast radius tiny if the pass has a bug — the existing 161 tests stay untouched until Task 2.

**Files:**
- Create: `optimizer/lib/optimize/passes/identity_elim_pass.rb`
- Create: `optimizer/test/passes/identity_elim_pass_test.rb`

- [ ] **Step 1: Write the failing baseline test for `x * 1 → x`**

Create `optimizer/test/passes/identity_elim_pass_test.rb`:

```ruby
# frozen_string_literal: true
require "test_helper"
require "optimize/codec"
require "optimize/passes/identity_elim_pass"
require "optimize/passes/literal_value"
require "optimize/log"

class IdentityElimPassTest < Minitest::Test
  def test_mult_right_identity_eliminated
    src = "def f(x); x * 1; end; f(7)"
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    log = Optimize::Log.new
    Optimize::Passes::IdentityElimPass.new.apply(f, type_env: nil, log: log, object_table: ot)

    assert_equal 0, f.instructions.count { |i| i.opcode == :opt_mult }
    assert_equal 0, f.instructions.count { |i|
      Optimize::Passes::LiteralValue.literal?(i) &&
        Optimize::Passes::LiteralValue.read(i, object_table: ot) == 1
    }
    assert(log.entries.any? { |e| e.reason == :identity_eliminated })

    loaded = RubyVM::InstructionSequence.load_from_binary(Optimize::Codec.encode(ir))
    assert_equal 7, loaded.eval
  end

  private

  def find_iseq(ir, name)
    return ir if ir.name == name
    ir.children.each do |child|
      found = find_iseq(child, name)
      return found if found
    end
    nil
  end
end
```

- [ ] **Step 2: Run the test, confirm it fails with LoadError**

Run via `mcp__ruby-bytecode__run_optimizer_tests` with filter `IdentityElimPassTest`. Expected: `LoadError` or `NameError` on `Optimize::Passes::IdentityElimPass` — the file does not exist yet.

- [ ] **Step 3: Create the pass**

Create `optimizer/lib/optimize/passes/identity_elim_pass.rb`:

```ruby
# frozen_string_literal: true
require "set"
require "optimize/pass"
require "optimize/passes/literal_value"
require "optimize/passes/arith_reassoc_pass"

module Optimize
  module Passes
    # Strip arithmetic identities: x * 1, 1 * x, x + 0, 0 + x, x - 0, x / 1.
    # See docs/superpowers/specs/2026-04-21-pass-identity-elim-design.md.
    class IdentityElimPass < Optimize::Pass
      IDENTITY_OPS = {
        opt_plus:  { identity: 0, sides: :either },
        opt_mult:  { identity: 1, sides: :either },
        opt_minus: { identity: 0, sides: :right  },
        opt_div:   { identity: 1, sides: :right  },
      }.freeze

      # Reuse the same whitelist ArithReassocPass uses for "safe to reorder
      # around." An identity fires only when the non-literal side of the
      # triple is in this set — rules out `send`, `invokesuper`, and any
      # opcode with side effects we'd be eliding.
      SAFE_PRODUCER_OPCODES = ArithReassocPass::SINGLE_PUSH_OPERAND_OPCODES

      def name = :identity_elim

      def apply(function, type_env:, log:, object_table: nil)
        _ = type_env
        return unless object_table
        insts = function.instructions
        return unless insts

        loop do
          eliminated_any = false
          i = 0
          while i <= insts.size - 3
            a  = insts[i]
            b  = insts[i + 1]
            op = insts[i + 2]
            entry = IDENTITY_OPS[op.opcode]
            if entry && SAFE_PRODUCER_OPCODES.include?(a.opcode) && SAFE_PRODUCER_OPCODES.include?(b.opcode)
              keep = try_eliminate(a, b, op, entry, object_table)
              if keep
                function.splice_instructions!(i..(i + 2), [keep])
                log.skip(pass: :identity_elim, reason: :identity_eliminated,
                         file: function.path, line: (op.line || a.line || function.first_lineno))
                eliminated_any = true
                i = i - 1 if i.positive?
                next
              end
            end
            i += 1
          end
          break unless eliminated_any
        end
      end

      private

      def try_eliminate(a, b, op, entry, object_table)
        id = entry[:identity]

        if LiteralValue.literal?(b)
          bv = LiteralValue.read(b, object_table: object_table)
          return a if bv.is_a?(Integer) && bv == id
        end

        if entry[:sides] == :either && LiteralValue.literal?(a)
          av = LiteralValue.read(a, object_table: object_table)
          return b if av.is_a?(Integer) && av == id
        end

        nil
      end
    end
  end
end
```

- [ ] **Step 4: Run the baseline test, confirm green**

Run via `mcp__ruby-bytecode__run_optimizer_tests` with filter `test_mult_right_identity_eliminated`. Expected: PASS.

- [ ] **Step 5: Append the full unit-test matrix**

Append to `identity_elim_pass_test.rb`, before the `private` section:

```ruby
  def test_mult_left_identity_eliminated
    assert_collapses_to_x("def f(x); 1 * x; end; f(7)", result: 7)
  end

  def test_plus_right_identity_eliminated
    assert_collapses_to_x("def f(x); x + 0; end; f(7)", result: 7)
  end

  def test_plus_left_identity_eliminated
    assert_collapses_to_x("def f(x); 0 + x; end; f(7)", result: 7)
  end

  def test_minus_right_identity_eliminated
    assert_collapses_to_x("def f(x); x - 0; end; f(7)", result: 7)
  end

  def test_minus_left_identity_not_eliminated
    # 0 - x = -x, NOT x.
    assert_unchanged("def f(x); 0 - x; end; f(7)", expected_eval: -7)
  end

  def test_div_right_identity_eliminated
    assert_collapses_to_x("def f(x); x / 1; end; f(7)", result: 7)
  end

  def test_div_left_identity_not_eliminated
    # 1 / x ≠ x.
    assert_unchanged("def f(x); 1 / x; end; f(7)", expected_eval: 0)
  end

  def test_fixpoint_cascade
    # x * 1 * 1 * 1 → x (three identities stripped in sequence)
    src = "def f(x); x * 1 * 1 * 1; end; f(42)"
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    log = Optimize::Log.new
    Optimize::Passes::IdentityElimPass.new.apply(f, type_env: nil, log: log, object_table: ot)

    assert_equal 0, f.instructions.count { |i| i.opcode == :opt_mult }
    assert_equal 3, log.entries.count { |e| e.reason == :identity_eliminated }

    loaded = RubyVM::InstructionSequence.load_from_binary(Optimize::Codec.encode(ir))
    assert_equal 42, loaded.eval
  end

  def test_float_identity_not_eliminated
    assert_unchanged("def f(x); x * 1.0; end; f(7)", expected_eval: 7.0)
  end

  def test_float_zero_not_eliminated
    assert_unchanged("def f(x); x + 0.0; end; f(7)", expected_eval: 7.0)
  end

  def test_absorbing_zero_not_eliminated
    # x * 0 is out of scope — would require side-effect analysis. Leave alone.
    src = "def f(x); x * 0; end; f(7)"
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    before = f.instructions.map(&:opcode)
    log = Optimize::Log.new
    Optimize::Passes::IdentityElimPass.new.apply(f, type_env: nil, log: log, object_table: ot)
    assert_equal before, f.instructions.map(&:opcode)
    assert(log.entries.none? { |e| e.reason == :identity_eliminated })
  end

  def test_send_producer_not_eliminated
    # Non-literal side is a method call (outside SAFE_PRODUCER_OPCODES) —
    # eliding the op would elide potential side effects in `foo`.
    src = "def f(x); x.succ * 1; end; f(6)"
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    before = f.instructions.map(&:opcode)
    Optimize::Passes::IdentityElimPass.new.apply(f, type_env: nil, log: Optimize::Log.new, object_table: ot)
    assert_equal before, f.instructions.map(&:opcode)
  end

  def test_idempotent_on_already_collapsed
    src = "def f(x); x * 1; end; f(7)"
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    pass = Optimize::Passes::IdentityElimPass.new
    pass.apply(f, type_env: nil, log: Optimize::Log.new, object_table: ot)
    first = f.instructions.map(&:opcode)
    pass.apply(f, type_env: nil, log: Optimize::Log.new, object_table: ot)
    second = f.instructions.map(&:opcode)
    assert_equal first, second
  end
```

Add shared helpers to the `private` section (above or below `find_iseq`):

```ruby
  def assert_collapses_to_x(src, result:)
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    log = Optimize::Log.new
    Optimize::Passes::IdentityElimPass.new.apply(f, type_env: nil, log: log, object_table: ot)

    remaining_arith = f.instructions.count { |i| IDENTITY_ARITH_OPCODES.include?(i.opcode) }
    assert_equal 0, remaining_arith, "expected all IDENTITY_OPS opcodes stripped from #{src}"
    assert(log.entries.any? { |e| e.reason == :identity_eliminated })

    loaded = RubyVM::InstructionSequence.load_from_binary(Optimize::Codec.encode(ir))
    assert_equal result, loaded.eval
  end

  def assert_unchanged(src, expected_eval:)
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    before = f.instructions.map(&:opcode)
    log = Optimize::Log.new
    Optimize::Passes::IdentityElimPass.new.apply(f, type_env: nil, log: log, object_table: ot)
    assert_equal before, f.instructions.map(&:opcode)
    assert(log.entries.none? { |e| e.reason == :identity_eliminated })
    loaded = RubyVM::InstructionSequence.load_from_binary(Optimize::Codec.encode(ir))
    assert_equal expected_eval, loaded.eval
  end

  IDENTITY_ARITH_OPCODES = %i[opt_plus opt_mult opt_minus opt_div].freeze
```

- [ ] **Step 6: Run the full suite, confirm green**

Run via `mcp__ruby-bytecode__run_optimizer_tests` (no filter). Expected: 161 baseline + 14 new = 175 green.

If any test fails, fix the pass until all pass.

- [ ] **Step 7: Commit**

```
jj commit -m "IdentityElimPass: strip x*1, x+0, x-0, x/1 with side-effect-free producers"
```

Files: `optimizer/lib/optimize/passes/identity_elim_pass.rb`, `optimizer/test/passes/identity_elim_pass_test.rb`.

---

### Task 2: Wire into pipeline + corpus fixture + pipeline-integration test

**Context:** Flip the pass into `Pipeline.default`, add a corpus fixture, and add the motivating pipeline-integration test (`2 * 3 / 6 * x → x`). This is the commit where the talk's three-pass narrative lands.

**Files:**
- Modify: `optimizer/lib/optimize/pipeline.rb`
- Create: `optimizer/test/codec/corpus/identity_elim.rb`
- Modify: `optimizer/test/passes/identity_elim_pass_test.rb`

- [ ] **Step 1: Wire into `Pipeline.default`**

Edit `optimizer/lib/optimize/pipeline.rb`:

```ruby
require "optimize/passes/arith_reassoc_pass"
require "optimize/passes/const_fold_pass"
require "optimize/passes/identity_elim_pass"

module Optimize
  class Pipeline
    def self.default
      new([Passes::ArithReassocPass.new, Passes::ConstFoldPass.new, Passes::IdentityElimPass.new])
    end
    # ... rest unchanged
```

- [ ] **Step 2: Add pipeline-integration test**

Append to `optimizer/test/passes/identity_elim_pass_test.rb`, before `private`:

```ruby
  def test_pipeline_collapses_v4_boundary_fully
    # The motivating case: ArithReassoc → ConstFold → IdentityElim must
    # collapse `2 * 3 / 6 * x` to just `getlocal x; leave`.
    src = "def f(x); 2 * 3 / 6 * x; end; f(42)"
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    Optimize::Pipeline.default.run(ir, type_env: nil)
    f = find_iseq(ir, "f")

    # No arithmetic opcodes should remain.
    remaining_arith = f.instructions.count { |i|
      %i[opt_plus opt_mult opt_minus opt_div].include?(i.opcode)
    }
    assert_equal 0, remaining_arith,
      "expected no arith opcodes after pipeline; got #{f.instructions.map(&:opcode).inspect}"

    loaded = RubyVM::InstructionSequence.load_from_binary(Optimize::Codec.encode(ir))
    assert_equal 42, loaded.eval
  end
```

- [ ] **Step 3: Create corpus fixture**

Create `optimizer/test/codec/corpus/identity_elim.rb`:

```ruby
def mult_right_identity(x)
  x * 1
end

def mult_left_identity(x)
  1 * x
end

def plus_right_identity(x)
  x + 0
end

def plus_left_identity(x)
  0 + x
end

def minus_right_identity(x)
  x - 0
end

def div_right_identity(x)
  x / 1
end

def cascade(x)
  x * 1 * 1 + 0 - 0
end

def pipeline_full_collapse(x)
  2 * 3 / 6 * x
end

def leave_alone_non_identity(x)
  x * 2 + 0 - 1
end

[1, 42, -7].each do |v|
  mult_right_identity(v)
  mult_left_identity(v)
  plus_right_identity(v)
  plus_left_identity(v)
  minus_right_identity(v)
  div_right_identity(v == 0 ? 1 : v)
  cascade(v)
  pipeline_full_collapse(v)
  leave_alone_non_identity(v)
end
```

- [ ] **Step 4: Run the full suite**

Run via `mcp__ruby-bytecode__run_optimizer_tests` (no filter). Expected: 175 + 1 pipeline test = 176 green. Every `arith_reassoc_pass_corpus_test.rb`-style corpus runner will pick up the new fixture automatically (check `optimizer/test/passes/arith_reassoc_pass_corpus_test.rb` to confirm it iterates `test/codec/corpus/*.rb`; if so, no new test method is needed).

If any existing test goes red because `Pipeline.default` now has three passes instead of two, inspect the failure. Most likely causes: a test asserted exact opcode shape after the pipeline for an expression that contains a stripped identity (e.g. a test that expected `opt_mult` to survive). Update the assertion to match the new three-pass shape — the runtime behavior is unchanged.

- [ ] **Step 5: Commit**

```
jj commit -m "IdentityElimPass: wire into Pipeline.default + corpus fixture + pipeline integration test"
```

Files: `optimizer/lib/optimize/pipeline.rb`, `optimizer/test/codec/corpus/identity_elim.rb`, `optimizer/test/passes/identity_elim_pass_test.rb`.

---

### Task 3 (optional): README + benchmark

**Context:** Cosmetic. Document the pass in `optimizer/README.md` and record one benchmark data point.

**Files:**
- Modify: `optimizer/README.md`

- [ ] **Step 1: Update README**

Append a new bullet to the passes list in `optimizer/README.md` (right after the `ConstFoldPass` bullet, since pipeline order is arith → fold → identity):

```
- `Optimize::Passes::IdentityElimPass` — strips arithmetic identities the
  upstream passes leave behind: `x * 1`, `1 * x`, `x + 0`, `0 + x`,
  `x - 0`, `x / 1`. Driven by the `IDENTITY_OPS` table, which encodes each
  operator's identity element and which sides are eligible (`:either` for
  commutative `+/*`, `:right` only for `-/` since `0 - x = -x` and
  `1 / x ≠ x`). Fires only when the non-literal side is in
  `SAFE_PRODUCER_OPCODES` (shared with `ArithReassocPass`), so no
  potentially-side-effecting producer (a `send`, `invokesuper`, etc.) is
  ever elided. Integer-literal-only: `x * 1.0` is left alone (float
  identities are their own essay, mostly because of `-0.0` and `NaN`).
  The pass is *sound in practice, not sound in principle*: for a receiver
  whose class does not treat the operator as an identity (e.g.
  `"abc" + 0` raises `TypeError`; `[1,2] * 1` returns a copy), eliding
  the op changes observable behavior. We take the same bet CRuby's
  `opt_*` fast paths take — numeric operands, specialized shape.
  Completes the three-pass collapse for `2 * 3 / 6 * x` → `x`.
```

- [ ] **Step 2: Run one benchmark**

Invoke `mcp__ruby-bytecode__benchmark_ips` comparing:

- Unoptimized: `def f(x); x * 1 * 1 * 1; end`
- Hand-optimized: `def f(x); x; end`

Both with a warmup loop. Record the ips ratio in the commit message. The optimized shape should be within noise of or faster than the unoptimized shape — the point of the benchmark is correctness-at-speed, not a blockbuster number (there's not much to gain from stripping three `opt_mult`s compared to the existing fast paths).

- [ ] **Step 3: Commit**

```
jj commit -m "Document IdentityElimPass; record v1 benchmark baseline"
```

---

## Success criteria

1. After Task 1: 175 tests green (161 baseline + 14 new unit). Pass is defined, exported, and works in isolation. Default pipeline is unchanged.
2. After Task 2: 176 tests green. `Pipeline.default` runs three passes. `2 * 3 / 6 * x` collapses to `getlocal`-only. Corpus fixture survives round-trip.
3. After Task 3: README documents the pass; one benchmark data point in the commit log.
4. Soundness invariant verifiable from the source: every fire site checks `IDENTITY_OPS[op]`, Integer-equal identity literal, `:sides` permission, and both operands in `SAFE_PRODUCER_OPCODES`. Nothing else fires.

---

## Notes for executors

- **Log accessor:** `log.entries` returns a frozen duplicate of `Log::Entry` structs. Fields are `.pass`, `.reason`, `.file`, `.line`. The tests above use `e.reason` on the struct, not `e[:reason]` — match existing test conventions.
- **`find_iseq`:** copy the helper from `arith_reassoc_pass_test.rb` or `const_fold_pass_test.rb`; signature is `find_iseq(ir, name)`.
- **`jj commit` vs `jj describe`:** always `jj commit -m`.
- **Parallel commits:** `jj split -m "<msg>" -- <files>` with the exact file list.
- **Test runs:** `mcp__ruby-bytecode__run_optimizer_tests` only. Never `rake test`.
- **Pipeline ordering:** IdentityElim runs *last*. Don't put it before ConstFold — it'd miss the identities that ConstFold produces (e.g., `6 / 6 → 1` in the v4 boundary case).
