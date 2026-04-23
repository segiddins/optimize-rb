# Arith Reassoc Pass v2 — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend `ArithReassocPass` to handle `opt_mult` chains. Collapse `x * 2 * 3 * 4` → `x * 24` the same way v1 collapses `x + 1 + 2 + 3` → `x + 6`, via a table-driven generalization of v1's existing logic.

**Architecture:** A `REASSOC_OPS` constant at the class level holds one entry per commutative-associative operator: `{ opcode:, identity:, reducer: }`. v1's chain detection and rewrite are parameterized by `op_spec`. `apply` iterates the table; each operator runs its own inner fixpoint. An outer any-rewrite fixpoint wraps the whole table iteration because a mult rewrite can remove an `opt_mult` from the middle of a sequence and thereby expose a previously-hidden `+` chain (concrete case: `x + 2 * 3 + 4`). A `fits_fixnum?` guard rejects Bignum results (e.g., products that exceed `2**62 - 1`) and logs `:would_overflow_fixnum` — v1's `ObjectTable#intern` stays scoped to special-const values.

**Tech Stack:** Ruby 4.0.2, minitest, the `ruby-bytecode` MCP for all test runs.

**Spec:** `docs/superpowers/specs/2026-04-20-pass-arith-reassoc-v2-design.md`.

**Commit discipline:** Each task ends with `jj commit -m "<msg>"`. Executors MUST translate that to `jj split -m "<msg>" -- <files>` using the exact file list from the task's Files section. Use `jj commit -m` (not `jj describe -m`) to finalize. Never commit via host bash wrappers. Tests via `mcp__ruby-bytecode__run_optimizer_tests` only, never host `rake test`.

**Baseline test count after v1: 125 green.**

---

## File structure

```
optimizer/
  lib/optimize/
    passes/
      arith_reassoc_pass.rb              # MODIFIED Task 1 (refactor) + Task 2 (opt_mult)
  test/
    passes/
      arith_reassoc_pass_test.rb         # MODIFIED Task 2 — new opt_mult + overflow + cross-op tests
  README.md                              # MODIFIED Task 3 (optional) — Passes entry mentions opt_mult
```

No new files. No pipeline wiring (v1 already added `ArithReassocPass` to `Pipeline.default`). No `Log` schema changes.

---

### Task 1: Refactor `ArithReassocPass` to a one-entry `REASSOC_OPS` table

**Context:** Pure refactor, zero behavior change. Introduce a class-level table of operator specs, parameterize `detect_chain` / `try_rewrite_chain` / `rewrite_once` by `op_spec:`, and have `apply` iterate the table. The table has exactly one entry (`opt_plus`) at the end of this task — the multiplicative row arrives in Task 2. All 125 existing tests must stay green.

The v1 file currently hard-codes `:opt_plus` in two places:
- `rewrite_once`'s forward scan: `if insts[i].opcode == :opt_plus`
- `detect_chain`'s backward walk: `break unless insts[op_j].opcode == :opt_plus`

And hard-codes `inject(0, :+)` for the reduction in `try_rewrite_chain`.

After this task, both opcode comparisons and the reduction read from `op_spec`.

**Files:**
- Modify: `optimizer/lib/optimize/passes/arith_reassoc_pass.rb`

- [ ] **Step 1: Baseline — run the full suite via MCP, confirm 125 green, 0 failures.**

Run: `mcp__ruby-bytecode__run_optimizer_tests` with no `test_filter`.

Expected: 125 runs, 0 failures.

If the baseline is not 125/0, STOP. The plan assumes v1 is fully green. Do not proceed with the refactor.

- [ ] **Step 2: Replace the pass file with the table-driven version.**

Overwrite `optimizer/lib/optimize/passes/arith_reassoc_pass.rb` with the following. Every behavior path remains identical to v1; the only change is where `:opt_plus`, `0`, and `:+` come from (now the table, previously inline).

```ruby
# frozen_string_literal: true
require "set"
require "optimize/pass"
require "optimize/passes/literal_value"
require "optimize/ir/cfg"

module Optimize
  module Passes
    # Arithmetic reassociation within a basic block, driven by REASSOC_OPS.
    # See docs/superpowers/specs/2026-04-20-pass-arith-reassoc-v2-design.md.
    class ArithReassocPass < Optimize::Pass
      # Each entry describes one commutative-associative operator:
      #   opcode:   the YARV opcode whose chains we fold
      #   identity: the neutral element for `reducer` (0 for +, 1 for *)
      #   reducer:  the Symbol method used to combine Integer literals
      REASSOC_OPS = [
        { opcode: :opt_plus, identity: 0, reducer: :+ },
      ].freeze

      # Opcodes that each push exactly one value, pop zero, and have no
      # side effects relevant to reordering literals past them. Shared across
      # all REASSOC_OPS entries.
      SINGLE_PUSH_OPERAND_OPCODES = (
        LiteralValue::LITERAL_OPCODES + %i[
          getlocal
          getlocal_WC_0
          getlocal_WC_1
          getinstancevariable
          getclassvariable
          getglobal
          putself
        ]
      ).freeze

      def name = :arith_reassoc

      def apply(function, type_env:, log:, object_table: nil)
        _ = type_env
        return unless object_table
        insts = function.instructions
        return unless insts

        REASSOC_OPS.each do |op_spec|
          loop do
            break unless rewrite_once(insts, function, log, object_table, op_spec: op_spec)
          end
        end
      end

      private

      def rewrite_once(insts, function, log, object_table, op_spec:)
        any = false
        leader_set = Set.new(IR::CFG.compute_leaders(insts))
        i = 0
        while i < insts.size
          if insts[i].opcode == op_spec[:opcode]
            chain = detect_chain(insts, i, leader_set, op_spec: op_spec)
            if chain && try_rewrite_chain(insts, chain, function, log, object_table, op_spec: op_spec)
              any = true
              i = chain[:first_idx]
              leader_set = Set.new(IR::CFG.compute_leaders(insts))
            else
              i += 1
            end
          else
            i += 1
          end
        end
        any
      end

      def detect_chain(insts, end_idx, leader_set, op_spec:)
        prod_indices = []
        op_indices = [end_idx]
        j = end_idx - 1
        return nil unless j >= 0 && single_push?(insts[j])
        prod_indices.unshift(j)

        loop do
          op_j = j - 1
          prod_j = j - 2
          break if op_j < 0 || prod_j < 0
          break unless insts[op_j].opcode == op_spec[:opcode]
          break unless single_push?(insts[prod_j])
          op_indices.unshift(op_j)
          prod_indices.unshift(prod_j)
          j = prod_j
        end

        first_candidate = prod_indices.first - 1
        return nil if first_candidate < 0
        return nil unless single_push?(insts[first_candidate])
        prod_indices.unshift(first_candidate)

        chain_start = prod_indices.first
        breaker = nil
        (chain_start + 1..end_idx).each do |k|
          if leader_set.include?(k)
            breaker = k
            break
          end
        end
        if breaker
          new_first = prod_indices.find { |p| p >= breaker }
          return nil unless new_first
          keep_from = prod_indices.index(new_first)
          prod_indices = prod_indices[keep_from..]
          op_indices = op_indices.last(prod_indices.size - 1) if prod_indices.size >= 1
        end

        return nil if prod_indices.size < 2
        {
          first_idx: prod_indices.first,
          producer_indices: prod_indices,
          op_indices: op_indices,
          end_idx: end_idx,
        }
      end

      def single_push?(inst)
        SINGLE_PUSH_OPERAND_OPCODES.include?(inst.opcode)
      end

      def try_rewrite_chain(insts, chain, function, log, object_table, op_spec:)
        producer_insts = chain[:producer_indices].map { |k| insts[k] }
        classified = producer_insts.map do |p|
          v = LiteralValue.read(p, object_table: object_table)
          is_lit = LiteralValue.literal?(p)
          [p, v, is_lit]
        end

        literal_values = classified.filter_map { |_, v, is_lit| v if is_lit }
        integer_literals = literal_values.select { |v| v.is_a?(Integer) }
        non_integer_literals = literal_values.reject { |v| v.is_a?(Integer) }
        non_literals = classified.reject { |_, _, is_lit| is_lit }.map(&:first)

        chain_line = insts[chain[:op_indices].first].line || function.first_lineno

        unless non_integer_literals.empty?
          log.skip(pass: :arith_reassoc, reason: :mixed_literal_types,
                   file: function.path, line: chain_line)
          return false
        end
        if integer_literals.size < 2
          log.skip(pass: :arith_reassoc, reason: :chain_too_short,
                   file: function.path, line: chain_line)
          return false
        end

        reduced = integer_literals.inject(op_spec[:identity], op_spec[:reducer])
        first_op_inst = insts[chain[:op_indices].first]
        literal_inst = LiteralValue.emit(reduced, line: first_op_inst.line, object_table: object_table)

        replacement = non_literals.dup
        replacement << literal_inst
        op_count_out = replacement.size - 1
        original_ops = chain[:op_indices].map { |k| insts[k] }
        op_count_out.times do |k|
          replacement << original_ops[k]
        end

        range = chain[:first_idx]..chain[:end_idx]
        function.splice_instructions!(range, replacement)
        log.skip(pass: :arith_reassoc, reason: :reassociated,
                 file: function.path, line: chain_line)
        true
      end
    end
  end
end
```

Notes on what changed from v1, strictly:

1. Added `REASSOC_OPS` constant (one entry).
2. `apply` wraps the fixpoint in `REASSOC_OPS.each do |op_spec| ... end`.
3. `rewrite_once`, `detect_chain`, `try_rewrite_chain` take `op_spec:` kwarg.
4. `insts[i].opcode == :opt_plus` → `insts[i].opcode == op_spec[:opcode]` (two sites).
5. Hash key renamed: `:opt_plus_indices` → `:op_indices`. This is a private-implementation rename; no external caller.
6. `inject(0, :+)` → `inject(op_spec[:identity], op_spec[:reducer])`.
7. Local variable renamed: `first_opt_plus` → `first_op_inst`, `original_opt_pluses` → `original_ops`, `opt_plus_count_out` → `op_count_out`. All local-scope only.

No test changes. No other file changes.

- [ ] **Step 3: Run the full suite via MCP, expect 125 green still.**

Run: `mcp__ruby-bytecode__run_optimizer_tests` with no `test_filter`.

Expected: 125 runs, 0 failures.

If any test fails: the refactor has drifted from v1 behavior. Diff-check against v1 — the most likely culprit is the `:op_indices` rename (a stale `chain[:opt_plus_indices]` reference left in `try_rewrite_chain` would `NoMethodError` on the nil access). Fix and rerun.

- [ ] **Step 4: Commit.**

```
jj commit -m "ArithReassocPass: refactor to REASSOC_OPS table (no behavior change)"
```

(Files: `optimizer/lib/optimize/passes/arith_reassoc_pass.rb`.)

---

### Task 2: Add `opt_mult` row + outer table fixpoint + fixnum-overflow guard + tests

**Context:** Now that the pass is table-driven, adding `opt_mult` is one row in `REASSOC_OPS`. The multiplicative row needs:

1. The row itself: `{ opcode: :opt_mult, identity: 1, reducer: :* }`.
2. An **outer any-rewrite fixpoint** wrapping the per-operator inner fixpoints. A mult rewrite can turn `... putobject 2; putobject 3; opt_mult ...` into `... putobject 6 ...`, which is a single-push producer. That change can expose a `+` chain plus's inner fixpoint already missed. Without the outer loop, `x + 2 * 3 + 4` collapses only to `x + 6 + 4`, not `x + 10`. Plus cannot expose a new mult chain (it never removes `opt_mult`), so the interaction is one-way, but the outer loop is the cleanest guarantee.
3. A **fixnum-overflow guard**. Ruby 4.0.2 on 64-bit CRuby has fixnum range `-(2**62) .. (2**62 - 1)`. `ObjectTable#intern` is scoped to special-const; Bignums would blow up. If the reduced result doesn't fit, skip with `:would_overflow_fixnum`.

The v1 additive path does not need the overflow guard in practice (you'd need ~2**62 distinct integer literals summed, which doesn't occur in real source), but the guard runs for both operators uniformly because it's correctness, not optimization — cheaper to just always check.

**Files:**
- Modify: `optimizer/lib/optimize/passes/arith_reassoc_pass.rb`
- Modify: `optimizer/test/passes/arith_reassoc_pass_test.rb`

- [ ] **Step 1: Append the failing tests to `arith_reassoc_pass_test.rb`.**

Add these methods to the existing `ArithReassocPassTest` class (after `test_reassoc_inside_then_branch_does_not_break_else_branch_targets`, before the `private` section). They cover: opt_mult basic fold, opt_mult with mid-chain non-literal, opt_mult with multiple non-literals, opt_mult all-literal, opt_mult chain_too_short, opt_mult mixed_literal_types, fixnum-boundary round-trip, bignum overflow skip, cross-operator exposure, and a deep-chain end-to-end.

```ruby
  # ---- opt_mult ----

  def test_opt_mult_collapses_leading_non_literal_chain
    src = "def f(x); x * 2 * 3 * 4; end; f(10)"
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    Optimize::Passes::ArithReassocPass.new.apply(f, type_env: nil, log: Optimize::Log.new, object_table: ot)

    assert_equal 1, f.instructions.count { |i| i.opcode == :opt_mult }
    refute_nil f.instructions.find { |i| Optimize::Passes::LiteralValue.read(i, object_table: ot) == 24 }
    loaded = RubyVM::InstructionSequence.load_from_binary(Optimize::Codec.encode(ir))
    assert_equal 240, loaded.eval
  end

  def test_opt_mult_reorders_around_mid_chain_non_literal
    src = "def f(x); 2 * x * 3; end; f(5)"
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    Optimize::Passes::ArithReassocPass.new.apply(f, type_env: nil, log: Optimize::Log.new, object_table: ot)

    assert_equal 1, f.instructions.count { |i| i.opcode == :opt_mult }
    refute_nil f.instructions.find { |i| Optimize::Passes::LiteralValue.read(i, object_table: ot) == 6 }
    loaded = RubyVM::InstructionSequence.load_from_binary(Optimize::Codec.encode(ir))
    assert_equal 30, loaded.eval
  end

  def test_opt_mult_multiple_non_literals_preserved_in_order
    src = "def f(x, y); 2 * x * 3 * y * 4; end; f(10, 5)"
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    Optimize::Passes::ArithReassocPass.new.apply(f, type_env: nil, log: Optimize::Log.new, object_table: ot)

    assert_equal 2, f.instructions.count { |i| i.opcode == :opt_mult }
    refute_nil f.instructions.find { |i| Optimize::Passes::LiteralValue.read(i, object_table: ot) == 24 }
    loaded = RubyVM::InstructionSequence.load_from_binary(Optimize::Codec.encode(ir))
    assert_equal 1200, loaded.eval
  end

  def test_opt_mult_all_literal_chain_folds
    src = "def f; 2 * 3 * 4; end; f"
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    Optimize::Passes::ArithReassocPass.new.apply(f, type_env: nil, log: Optimize::Log.new, object_table: ot)

    assert_equal 0, f.instructions.count { |i| i.opcode == :opt_mult }
    refute_nil f.instructions.find { |i| Optimize::Passes::LiteralValue.read(i, object_table: ot) == 24 }
    loaded = RubyVM::InstructionSequence.load_from_binary(Optimize::Codec.encode(ir))
    assert_equal 24, loaded.eval
  end

  def test_opt_mult_single_literal_chain_is_left_alone
    src = "def f(x); x * 2; end; f(10)"
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    before = f.instructions.map(&:opcode)
    Optimize::Passes::ArithReassocPass.new.apply(f, type_env: nil, log: Optimize::Log.new, object_table: ot)
    assert_equal before, f.instructions.map(&:opcode)
  end

  def test_opt_mult_mixed_literal_types_leaves_chain_alone
    src = "def f(x); x * 1.5 * 2; end; f(4)"
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    before = f.instructions.map(&:opcode)
    log = Optimize::Log.new
    Optimize::Passes::ArithReassocPass.new.apply(f, type_env: nil, log: log, object_table: ot)
    assert_equal before, f.instructions.map(&:opcode)
    entries = log.for_pass(:arith_reassoc).select { |e| e.reason == :mixed_literal_types }
    assert_operator entries.size, :>=, 1
  end

  # ---- fixnum-overflow guard ----

  def test_product_at_fixnum_boundary_folds
    # (2**31) * (2**31) == 2**62, which is FIXNUM_MAX + 1 → overflow, skipped.
    # Use (2**31) * (2**31 - 1) == 2**62 - 2**31, which fits in fixnum.
    src = "def f(x); x * #{2**31} * #{2**31 - 1}; end; f(1)"
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    log = Optimize::Log.new
    Optimize::Passes::ArithReassocPass.new.apply(f, type_env: nil, log: log, object_table: ot)

    expected_product = (2**31) * (2**31 - 1)
    refute_nil f.instructions.find { |i| Optimize::Passes::LiteralValue.read(i, object_table: ot) == expected_product },
      "expected the literal #{expected_product} after folding"
    loaded = RubyVM::InstructionSequence.load_from_binary(Optimize::Codec.encode(ir))
    assert_equal expected_product, loaded.eval
  end

  def test_product_just_overflows_fixnum_is_skipped
    # (1 << 30) * (1 << 30) * (1 << 10) == 2**70 → bignum, chain left alone,
    # :would_overflow_fixnum logged, eval still correct via VM bignum promo.
    src = "def f(x); x * #{1 << 30} * #{1 << 30} * #{1 << 10}; end; f(1)"
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    before_opcodes = f.instructions.map(&:opcode)
    log = Optimize::Log.new
    Optimize::Passes::ArithReassocPass.new.apply(f, type_env: nil, log: log, object_table: ot)

    assert_equal before_opcodes, f.instructions.map(&:opcode),
      "overflow-guard should leave the chain untouched"
    entries = log.for_pass(:arith_reassoc).select { |e| e.reason == :would_overflow_fixnum }
    assert_operator entries.size, :>=, 1
    loaded = RubyVM::InstructionSequence.load_from_binary(Optimize::Codec.encode(ir))
    assert_equal 1 << 70, loaded.eval
  end

  # ---- cross-operator interaction (outer fixpoint) ----

  def test_mult_rewrite_exposes_plus_chain_across_outer_fixpoint
    # Without the outer table fixpoint:
    #   - plus's inner scan bails at the middle opt_mult (not single_push)
    #   - mult's inner scan folds 2*3 → 6
    #   - plus never runs again; residual shape is `x + 6 + 4`, two opt_pluses
    # With the outer fixpoint: plus re-runs and collapses to `x + 10`, one opt_plus.
    src = "def f(x); x + 2 * 3 + 4; end; f(10)"
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    Optimize::Passes::ArithReassocPass.new.apply(f, type_env: nil, log: Optimize::Log.new, object_table: ot)

    assert_equal 0, f.instructions.count { |i| i.opcode == :opt_mult },
      "mult should have folded 2*3 to a literal"
    assert_equal 1, f.instructions.count { |i| i.opcode == :opt_plus },
      "plus should have collapsed x + 6 + 4 to one opt_plus after outer fixpoint re-ran it"
    refute_nil f.instructions.find { |i| Optimize::Passes::LiteralValue.read(i, object_table: ot) == 10 }
    loaded = RubyVM::InstructionSequence.load_from_binary(Optimize::Codec.encode(ir))
    assert_equal 20, loaded.eval
  end

  def test_opt_mult_deep_chain_end_to_end
    src = "def f(x); x * 2 * 3 * 4 * 5 * 6; end; f(1)"
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    Optimize::Passes::ArithReassocPass.new.apply(find_iseq(ir, "f"), type_env: nil, log: Optimize::Log.new, object_table: ot)
    loaded = RubyVM::InstructionSequence.load_from_binary(Optimize::Codec.encode(ir))
    assert_equal 720, loaded.eval  # 1 * 2 * 3 * 4 * 5 * 6 = 720
  end
```

- [ ] **Step 2: Run the arith-reassoc test file via MCP, expect the new tests to fail.**

Run: `mcp__ruby-bytecode__run_optimizer_tests` with `test_filter: "test/passes/arith_reassoc_pass_test.rb"`.

Expected failures (10 new tests, all failing):
- `test_opt_mult_*` (6 tests): the current table only has `opt_plus`, so mult chains aren't touched. `assert_equal 1, f.instructions.count { |i| i.opcode == :opt_mult }` etc. fail.
- `test_product_at_fixnum_boundary_folds`: fails for the same reason (mult not in table).
- `test_product_just_overflows_fixnum_is_skipped`: fails — no `:would_overflow_fixnum` logging because mult isn't in the table.
- `test_mult_rewrite_exposes_plus_chain_across_outer_fixpoint`: fails — mult doesn't run, so the first collapse doesn't happen, plus sees `x + 2 * 3 + 4` and bails.
- `test_opt_mult_deep_chain_end_to_end`: passes its `.eval` assertion by coincidence (unoptimized also equals 720), but doesn't meaningfully exercise the new code. Let it stay as a redundancy check.

If any pre-existing test (of the original 125) fails here, STOP — Task 1's refactor regressed something. Revert and re-run Task 1.

- [ ] **Step 3: Add the `opt_mult` row, the outer fixpoint, and the overflow guard to `arith_reassoc_pass.rb`.**

Make three edits to the file from Task 1.

**Edit 3a: Add the multiplicative entry + fixnum constants to the class body.** Replace the `REASSOC_OPS` constant block with:

```ruby
      # Each entry describes one commutative-associative operator:
      #   opcode:   the YARV opcode whose chains we fold
      #   identity: the neutral element for `reducer` (0 for +, 1 for *)
      #   reducer:  the Symbol method used to combine Integer literals
      REASSOC_OPS = [
        { opcode: :opt_plus, identity: 0, reducer: :+ },
        { opcode: :opt_mult, identity: 1, reducer: :* },
      ].freeze

      # 64-bit CRuby fixnum range. ObjectTable#intern is scoped to
      # special-const values; Bignum results must be skipped.
      FIXNUM_MAX =  (1 << 62) - 1
      FIXNUM_MIN = -(1 << 62)
```

**Edit 3b: Wrap the per-operator iteration in an outer any-rewrite fixpoint.** Replace the body of `apply` with:

```ruby
      def apply(function, type_env:, log:, object_table: nil)
        _ = type_env
        return unless object_table
        insts = function.instructions
        return unless insts

        # Outer any-rewrite fixpoint: a mult rewrite can replace
        # `... opt_mult ...` with a single-push literal, which may expose
        # a `+` chain that plus's inner fixpoint missed on its first visit.
        # See spec "Two-level fixpoint" section.
        loop do
          any_outer = false
          REASSOC_OPS.each do |op_spec|
            loop do
              break unless rewrite_once(insts, function, log, object_table, op_spec: op_spec)
              any_outer = true
            end
          end
          break unless any_outer
        end
      end
```

**Edit 3c: Add the overflow guard inside `try_rewrite_chain`.** Replace the block that starts with `reduced = integer_literals.inject(...)` and ends at `function.splice_instructions!(...)` + `log.skip(... :reassociated ...)` with:

```ruby
        reduced = integer_literals.inject(op_spec[:identity], op_spec[:reducer])
        unless fits_fixnum?(reduced)
          log.skip(pass: :arith_reassoc, reason: :would_overflow_fixnum,
                   file: function.path, line: chain_line)
          return false
        end

        first_op_inst = insts[chain[:op_indices].first]
        literal_inst = LiteralValue.emit(reduced, line: first_op_inst.line, object_table: object_table)

        replacement = non_literals.dup
        replacement << literal_inst
        op_count_out = replacement.size - 1
        original_ops = chain[:op_indices].map { |k| insts[k] }
        op_count_out.times do |k|
          replacement << original_ops[k]
        end

        range = chain[:first_idx]..chain[:end_idx]
        function.splice_instructions!(range, replacement)
        log.skip(pass: :arith_reassoc, reason: :reassociated,
                 file: function.path, line: chain_line)
        true
      end

      def fits_fixnum?(n)
        n.is_a?(Integer) && n >= FIXNUM_MIN && n <= FIXNUM_MAX
      end
    end
  end
end
```

Note: `fits_fixnum?` is a new private instance method. Place it between `try_rewrite_chain` and the closing `end`s of the class / module / module. The closing `end`s shown above are the final three lines of the file.

- [ ] **Step 4: Run the arith-reassoc test file via MCP, expect all tests (old + new) to pass.**

Run: `mcp__ruby-bytecode__run_optimizer_tests` with `test_filter: "test/passes/arith_reassoc_pass_test.rb"`.

Expected: old 14 arith-reassoc tests + 10 new = 24 runs, 0 failures.

If `test_mult_rewrite_exposes_plus_chain_across_outer_fixpoint` fails with `assert_equal 1, f.instructions.count { |i| i.opcode == :opt_plus }` showing 2 opt_pluses: the outer fixpoint is not firing. Confirm the `any_outer = true` assignment is inside the inner `loop do` block and that `rewrite_once` returns true on a successful rewrite.

If `test_product_just_overflows_fixnum_is_skipped` fails with a test-side exception mentioning `ObjectTable#intern` / bignum: the overflow guard is either in the wrong place (after `LiteralValue.emit`) or has the wrong predicate. `fits_fixnum?` must run BEFORE `LiteralValue.emit`.

- [ ] **Step 5: Full-suite regression via MCP.** Expected: 125 + 10 new = 135 runs, 0 failures.

Run: `mcp__ruby-bytecode__run_optimizer_tests` with no `test_filter`.

If a corpus test regresses: the new mult path is producing a shape the codec can't re-emit. Temporarily drop the `opt_mult` entry from `REASSOC_OPS` (leaving only `opt_plus`) and rerun corpus — if it passes, the bug is in the mult output. Most likely culprit: reused `opt_mult` instruction instances whose operands (BOP_MULT inline-cache state) drift after splicing. Compare with v1's treatment of `opt_plus` — the instructions are reused verbatim, which works.

- [ ] **Step 6: Commit.**

```
jj commit -m "ArithReassocPass: add opt_mult row + fixnum-overflow guard + cross-op fixpoint"
```

(Files: `optimizer/lib/optimize/passes/arith_reassoc_pass.rb`, `optimizer/test/passes/arith_reassoc_pass_test.rb`.)

---

### Task 3 (optional): README + benchmark

**Context:** Quick housekeeping — update the v1 Passes entry to mention opt_mult, and record one benchmark for the talk slide. Skip this task entirely if you don't want the README drift; the functionality is complete after Task 2.

**Files:**
- Modify: `optimizer/README.md`

- [ ] **Step 1: Read the current Passes entry for `ArithReassocPass` in `optimizer/README.md`.**

Use the Read tool on the file; locate the `ArithReassocPass` bullet (it will mention `opt_plus`, `:mixed_literal_types`, `:chain_too_short`, and list `opt_mult` as a future plan).

- [ ] **Step 2: Replace the bullet.**

Swap the existing bullet with:

```
- `Optimize::Passes::ArithReassocPass` — arithmetic reassociation driven by
  the `REASSOC_OPS` table. Two rows today: `opt_plus` (identity 0, reducer `:+`)
  and `opt_mult` (identity 1, reducer `:*`). Collapses chains of one operator
  within a basic block where ≥2 operands are Integer literals, keeping non-literal
  operands in original order and emitting a single combined-literal tail. Reaches
  shapes const-fold cannot: `x + 1 + 2 + 3` → `x + 6`, `x * 2 * 3 * 4` → `x * 24`.
  Non-Integer literals, chains with <2 integer literals, and results that would
  overflow fixnum range are left alone (`:mixed_literal_types`, `:chain_too_short`,
  `:would_overflow_fixnum`). An outer any-rewrite fixpoint wraps the per-operator
  inner fixpoints so a mult rewrite can expose a `+` chain (e.g., `x + 2 * 3 + 4`
  → `x + 10`). Mixed same-precedence chains (`+`/`-`, `*`/`/`) and `**` are out
  of scope; see follow-up plans.
```

- [ ] **Step 3: Run one benchmark to quantify the mult win.**

Run `mcp__ruby-bytecode__benchmark_ips` with:

```ruby
def unreassoc_mult(x); x * 2 * 3 * 4 * 5; end
def reassoc_mult(x);   x * 120; end

Benchmark.ips do |x|
  x.report("unreassoc_mult") { unreassoc_mult(100) }
  x.report("reassoc_mult")   { reassoc_mult(100) }
  x.compare!
end
```

Record the winner and ratio in the commit message body.

- [ ] **Step 4: Full-suite regression via MCP.** Sanity: 135 runs, 0 failures (no code change).

- [ ] **Step 5: Commit.**

```
jj commit -m "Document ArithReassocPass opt_mult; record opt_mult benchmark baseline"
```

(Files: `optimizer/README.md`.)

---

## Self-review

**Spec coverage** (from `2026-04-20-pass-arith-reassoc-v2-design.md`):

- `REASSOC_OPS` table with `{opcode:, identity:, reducer:}` — Task 1 Step 2 (constant definition), Task 2 Edit 3a (second row added).
- `apply` iterates the table, each entry has its own inner fixpoint — Task 1 Step 2 (single-entry iteration), Task 2 Edit 3b (adds outer loop wrapping the per-entry inner fixpoints).
- Chain detection parameterized by `op_spec[:opcode]` — Task 1 Step 2 (two `insts[...].opcode == op_spec[:opcode]` comparisons).
- Shared `SINGLE_PUSH_OPERAND_OPCODES` allowlist — Task 1 Step 2 (unchanged from v1, deliberately shared).
- Integer-literal classification + `:mixed_literal_types` / `:chain_too_short` skips — Task 1 Step 2 (carried over from v1; logic unchanged).
- Reduction via `inject(op_spec[:identity], op_spec[:reducer])` — Task 1 Step 2.
- `fits_fixnum?` overflow guard + `:would_overflow_fixnum` log reason — Task 2 Edit 3c.
- Two-level (inner per-op, outer across table) fixpoint — Task 2 Edit 3b.
- Line-inheritance for the literal tail and kept ops — Task 1 Step 2 (unchanged from v1).
- Pipeline ordering — unchanged (no edit needed; v1 wired arith in).
- Corpus regression — run as part of the full suite in Task 2 Step 5.
- `REASSOC_OPS` is a public-enough constant — Task 1 Step 2 defines it with a doc comment; tests can reference it if a future task wants to (none do in this plan).
- Cross-operator interaction test (`x + 2 * 3 + 4 → x + 10`) — Task 2 Step 1 `test_mult_rewrite_exposes_plus_chain_across_outer_fixpoint`.
- Opt_mult unit tests covering leading/mid/multi non-literals, all-literal, chain-too-short, mixed-literal — Task 2 Step 1.
- Overflow sanity pair (just-fits / just-overflows) — Task 2 Step 1.
- README + benchmark — Task 3 (optional).

Gaps: none.

**Placeholder scan:** No TBDs, no "add appropriate error handling," no "similar to Task N." All code is inline. All commands are exact MCP tool names with explicit `test_filter` where applicable.

**Type consistency:**
- Hash key `:op_indices` introduced in Task 1 Step 2, used identically in Task 2 Edit 3c (`chain[:op_indices].first`). Renamed from v1's `:opt_plus_indices`.
- `op_spec` kwarg signature `{ opcode:, identity:, reducer: }` used consistently across `rewrite_once`, `detect_chain`, `try_rewrite_chain` (Task 1 Step 2 and Task 2 Edit 3c).
- `FIXNUM_MAX` / `FIXNUM_MIN` defined once (Task 2 Edit 3a), referenced once (`fits_fixnum?` in Edit 3c).
- Pass name `:arith_reassoc` consistent with v1 (unchanged in any task).
- Log skip-reason `:would_overflow_fixnum` spelled identically in Edit 3c (`log.skip`) and in Task 2 Step 1 test (`e.reason == :would_overflow_fixnum`).

**Test-count arithmetic:**
- Baseline: 125.
- Task 1: no test changes. After Task 1: 125.
- Task 2: +10 tests. After Task 2: 135.
- Task 3: no test changes. After Task 3: 135.

All counts match what Steps 4 and 5 of Task 2 assert.
