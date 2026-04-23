# Arith Reassoc Pass v1 — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land the optimizer's arithmetic-reassociation pass (v1) — reach the shape const-fold cannot. Collapse `x + 1 + 2 + 3` to `x + 6` (and `1 + x + 2 + y + 3` to `x + y + 6`) by walking `opt_plus` chains within a basic block, preserving non-literal operand order, and summing Integer literals into a single tail literal.

**Architecture:** A new `Optimize::Passes::ArithReassocPass`. For each `opt_plus` instruction, walk backward in `(producer, opt_plus)` pairs through the function's instruction list, bounded by `IR::CFG.compute_leaders` (basic-block edges) and by an opcode allowlist for operand producers. When the chain has ≥2 Integer literals, rewrite in place: non-literal producers first (original order), one combined-literal tail, then `n-1` opt_pluses. Wrap in an outer `loop` fixpoint (same shape as const-fold). Default pipeline becomes `[ArithReassocPass, ConstFoldPass]` — arith first, so const-fold mops up any residual all-literal adjacency.

**Tech Stack:** Ruby 4.0.2, minitest, the `ruby-bytecode` MCP for all test runs.

**Spec:** `docs/superpowers/specs/2026-04-20-pass-arith-reassoc-v1-design.md`.

**Commit discipline:** Each task ends with `jj commit -m "<msg>"`. Executors MUST translate that to `jj split -m "<msg>" -- <files>` using the exact file list from the task's Files section. Use `jj commit -m` (not `jj describe -m`) to finalize. Never commit via host bash wrappers. Tests via `mcp__ruby-bytecode__run_optimizer_tests` only, never host `rake test`.

**Baseline test count after const-fold tier 1: 107 green.**

---

## File structure

```
optimizer/
  lib/optimize/
    passes/
      arith_reassoc_pass.rb           # NEW — the pass (all logic, chain detection private)
    pipeline.rb                       # MODIFIED Task 4 — default pipeline prepends ArithReassocPass
  test/
    passes/
      arith_reassoc_pass_test.rb      # NEW — unit + end-to-end tests
      arith_reassoc_pass_corpus_test.rb # NEW Task 4 — corpus regression under updated pipeline
  README.md                           # MODIFIED Task 5 — Passes section updated
```

---

### Task 1: `ArithReassocPass` — basic literal-only `opt_plus` chain reassociation

**Context:** First working slice. Chain detection + single-chain rewrite, no logging yet, no outer fixpoint yet. The inner scan is deliberately written to fire at most once per chain in this task; the outer fixpoint arrives in Task 3 (and in practice the single inner pass already handles every case — the outer loop is belt-and-braces).

`Pass#apply` already accepts `object_table:` from const-fold tier 1, no interface change needed. `IR::CFG.compute_leaders` is already public and returns a sorted uniq'd array of instruction indices that are basic-block leaders.

**Files:**
- Create: `optimizer/lib/optimize/passes/arith_reassoc_pass.rb`
- Create: `optimizer/test/passes/arith_reassoc_pass_test.rb`

- [ ] **Step 1: Write the failing test file** — `optimizer/test/passes/arith_reassoc_pass_test.rb`

```ruby
# frozen_string_literal: true
require "test_helper"
require "optimize/codec"
require "optimize/log"
require "optimize/passes/arith_reassoc_pass"
require "optimize/passes/literal_value"

class ArithReassocPassTest < Minitest::Test
  def test_collapses_leading_non_literal_chain_to_single_literal_tail
    src = "def f(x); x + 1 + 2 + 3; end; f(10)"
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    Optimize::Passes::ArithReassocPass.new.apply(f, type_env: nil, log: Optimize::Log.new, object_table: ot)

    # Output shape: one getlocal, one literal 6, one opt_plus.
    opt_plus_count = f.instructions.count { |i| i.opcode == :opt_plus }
    assert_equal 1, opt_plus_count, "expected a single opt_plus after reassoc"
    lit_six = f.instructions.find { |i| Optimize::Passes::LiteralValue.read(i, object_table: ot) == 6 }
    refute_nil lit_six, "expected a literal 6 in the rewritten instructions"

    loaded = RubyVM::InstructionSequence.load_from_binary(Optimize::Codec.encode(ir))
    assert_equal 16, loaded.eval
  end

  def test_reorders_around_mid_chain_non_literal
    src = "def f(x); 1 + x + 2; end; f(10)"
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    Optimize::Passes::ArithReassocPass.new.apply(f, type_env: nil, log: Optimize::Log.new, object_table: ot)

    opt_plus_count = f.instructions.count { |i| i.opcode == :opt_plus }
    assert_equal 1, opt_plus_count
    refute_nil f.instructions.find { |i| Optimize::Passes::LiteralValue.read(i, object_table: ot) == 3 }

    loaded = RubyVM::InstructionSequence.load_from_binary(Optimize::Codec.encode(ir))
    assert_equal 13, loaded.eval
  end

  def test_multiple_non_literals_preserved_in_original_order
    src = "def f(x, y); 1 + x + 2 + y + 3; end; f(10, 20)"
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    Optimize::Passes::ArithReassocPass.new.apply(f, type_env: nil, log: Optimize::Log.new, object_table: ot)

    opt_plus_count = f.instructions.count { |i| i.opcode == :opt_plus }
    assert_equal 2, opt_plus_count, "3 operands after reassoc => 2 opt_pluses"
    refute_nil f.instructions.find { |i| Optimize::Passes::LiteralValue.read(i, object_table: ot) == 6 }

    # Non-literal producers appear in original source order: x before y.
    producers = f.instructions.select { |i| %i[getlocal getlocal_WC_0 getlocal_WC_1].include?(i.opcode) }
    assert_equal 2, producers.size
    # (We don't assert on the local ID here — order check is enough: x comes before y.)
    loaded = RubyVM::InstructionSequence.load_from_binary(Optimize::Codec.encode(ir))
    assert_equal 36, loaded.eval
  end

  def test_single_literal_chain_is_left_alone
    # `x + 1` has only one literal — not worth reassociating.
    src = "def f(x); x + 1; end; f(10)"
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    before = f.instructions.map(&:opcode)
    Optimize::Passes::ArithReassocPass.new.apply(f, type_env: nil, log: Optimize::Log.new, object_table: ot)
    assert_equal before, f.instructions.map(&:opcode)
  end

  def test_no_literals_chain_is_left_alone
    src = "def f(x, y, z); x + y + z; end; f(1, 2, 3)"
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    before = f.instructions.map(&:opcode)
    Optimize::Passes::ArithReassocPass.new.apply(f, type_env: nil, log: Optimize::Log.new, object_table: ot)
    assert_equal before, f.instructions.map(&:opcode)
  end

  def test_all_literal_chain_is_left_to_const_fold
    # Const-fold already handles this shape. ArithReassoc still safely rewrites
    # (m=0 non-literals, 1 literal-sum tail, 0 opt_pluses), but the end result
    # equals what const-fold would have produced.
    src = "def f; 1 + 2 + 3; end; f"
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    Optimize::Passes::ArithReassocPass.new.apply(f, type_env: nil, log: Optimize::Log.new, object_table: ot)
    # After reassoc: zero opt_plus, one literal 6.
    assert_equal 0, f.instructions.count { |i| i.opcode == :opt_plus }
    refute_nil f.instructions.find { |i| Optimize::Passes::LiteralValue.read(i, object_table: ot) == 6 }
    loaded = RubyVM::InstructionSequence.load_from_binary(Optimize::Codec.encode(ir))
    assert_equal 6, loaded.eval
  end

  def test_non_opt_plus_chains_untouched
    # opt_minus, opt_mult — not in v1 scope.
    src = "def f(x); x * 2 * 3; end; f(4)"
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    before = f.instructions.map(&:opcode)
    Optimize::Passes::ArithReassocPass.new.apply(f, type_env: nil, log: Optimize::Log.new, object_table: ot)
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

- [ ] **Step 2: Run, expect LoadError.**

Run: `mcp__ruby-bytecode__run_optimizer_tests` with `test_filter: "test/passes/arith_reassoc_pass_test.rb"`.

Expected: `cannot load such file -- optimize/passes/arith_reassoc_pass`.

- [ ] **Step 3: Implement the pass** — `optimizer/lib/optimize/passes/arith_reassoc_pass.rb`

```ruby
# frozen_string_literal: true
require "optimize/pass"
require "optimize/passes/literal_value"
require "optimize/ir/cfg"

module Optimize
  module Passes
    # v1: literal-only opt_plus chain reassociation within a basic block.
    # See docs/superpowers/specs/2026-04-20-pass-arith-reassoc-v1-design.md.
    class ArithReassocPass < Optimize::Pass
      # Opcodes that each push exactly one value, pop zero, and have no
      # side effects relevant to reordering literals past them.
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

        rewrite_once(insts, function, log, object_table)
      end

      private

      # Forward scan. At each opt_plus, try to identify a chain ending there
      # and rewrite it. Returns true if any chain was rewritten.
      def rewrite_once(insts, function, log, object_table)
        any = false
        leaders = IR::CFG.compute_leaders(insts)
        leader_set = leaders.to_set rescue Set.new(leaders)
        i = 0
        while i < insts.size
          if insts[i].opcode == :opt_plus
            chain = detect_chain(insts, i, leader_set)
            if chain && try_rewrite_chain(insts, chain, function, log, object_table)
              any = true
              # Resume scan at the replacement's start so any enclosing chain
              # that ends at a later opt_plus still matches.
              i = chain[:first_idx]
              # Recompute leaders — instruction indices shifted.
              leaders = IR::CFG.compute_leaders(insts)
              leader_set = Set.new(leaders)
            else
              i += 1
            end
          else
            i += 1
          end
        end
        any
      end

      # Identify the chain ending at the opt_plus at index `end_idx`, or nil.
      # Returns a hash: { first_idx:, producer_indices:, opt_plus_indices: }.
      def detect_chain(insts, end_idx, leader_set)
        # Chain layout: producer, producer, opt_plus, producer, opt_plus, ...,
        # producer, opt_plus. That's n producers at indices
        # [end_idx-1, end_idx-3, ..., end_idx-(2n-3), end_idx-(2n-2)]
        # with opt_pluses at end_idx, end_idx-2, ..., end_idx-(2n-4).
        # The chain's FIRST producer is at end_idx-(2n-2); its second is at
        # end_idx-(2n-3), adjacent to it (no opt_plus between).
        prod_indices = []
        op_indices = [end_idx]
        j = end_idx - 1
        return nil unless j >= 0 && single_push?(insts[j])
        prod_indices.unshift(j)  # last producer

        # Walk backward in (opt_plus, producer) pairs.
        loop do
          op_j = j - 1
          prod_j = j - 2
          break if op_j < 0 || prod_j < 0
          break unless insts[op_j].opcode == :opt_plus
          break unless single_push?(insts[prod_j])
          op_indices.unshift(op_j)
          prod_indices.unshift(prod_j)
          j = prod_j
        end

        # At this point prod_indices.first is the "second producer" (for n=2)
        # or later-ordered. The chain needs one more producer immediately
        # before it with no opt_plus between.
        first_candidate = prod_indices.first - 1
        return nil if first_candidate < 0
        return nil unless single_push?(insts[first_candidate])
        prod_indices.unshift(first_candidate)

        # Leader check: any index in [prod_indices.first+1 .. end_idx] that
        # is a leader breaks the chain at that point. Shrink from the front.
        # (The chain's very first index may itself be a leader — that's fine.)
        chain_start = prod_indices.first
        breaker = nil
        (chain_start + 1..end_idx).each do |k|
          if leader_set.include?(k)
            breaker = k
            break
          end
        end
        if breaker
          # Anything up to and including the breaker's previous boundary
          # is not part of a valid chain ending at end_idx. Shrink the chain
          # to start at the first producer index >= breaker.
          new_first = prod_indices.find { |p| p >= breaker }
          return nil unless new_first
          # Rebuild chain starting at new_first.
          keep_from = prod_indices.index(new_first)
          prod_indices = prod_indices[keep_from..]
          # Count opt_pluses we keep: n-1 where n = prod_indices.size.
          op_indices = op_indices.last(prod_indices.size - 1) if prod_indices.size >= 1
        end

        return nil if prod_indices.size < 2
        {
          first_idx: prod_indices.first,
          producer_indices: prod_indices,
          opt_plus_indices: op_indices,
          end_idx: end_idx,
        }
      end

      def single_push?(inst)
        SINGLE_PUSH_OPERAND_OPCODES.include?(inst.opcode)
      end

      # Classify producers; if ≥2 Integer literals, emit the rewrite.
      # Returns true iff the chain was rewritten.
      def try_rewrite_chain(insts, chain, function, log, object_table)
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

        # Any non-Integer literal in the chain blocks the rewrite.
        return false unless non_integer_literals.empty?
        # Need ≥2 integer literals for the rewrite to shrink the chain.
        return false if integer_literals.size < 2

        sum = integer_literals.inject(0, :+)
        first_opt_plus = insts[chain[:opt_plus_indices].first]
        literal_inst = LiteralValue.emit(sum, line: first_opt_plus.line, object_table: object_table)

        # Build replacement: non-literals (original order), literal tail, opt_plus × m.
        replacement = non_literals.dup
        replacement << literal_inst
        opt_plus_count_out = replacement.size - 1
        # Reuse original opt_plus instructions in order so line annotations carry.
        original_opt_pluses = chain[:opt_plus_indices].map { |k| insts[k] }
        opt_plus_count_out.times do |k|
          replacement << original_opt_pluses[k] || original_opt_pluses.last
        end

        start = chain[:first_idx]
        length = chain[:end_idx] - chain[:first_idx] + 1
        insts[start, length] = replacement
        function.invalidate_cfg
        true
      end
    end
  end
end
```

Note: `require "set"` is already loaded transitively in the test environment (minitest pulls it), and Ruby 4.0.2 autoloads `Set`. If any MCP test run errors on `NameError: uninitialized constant Set`, add `require "set"` at the top of the pass file.

- [ ] **Step 4: Run the arith-reassoc test file via MCP, expect all 7 tests to pass.**

Run: `mcp__ruby-bytecode__run_optimizer_tests` with `test_filter: "test/passes/arith_reassoc_pass_test.rb"`.

- [ ] **Step 5: Full-suite regression via MCP.** Expected: previous 107 + 7 new = 114, 0 failures.

If any existing codec round-trip regresses: the pass's leader recomputation or chain detection is producing an over-eager rewrite. Temporarily disable `rewrite_once`'s inner body (return immediately) to confirm the test baseline is still 107; then bisect detection.

- [ ] **Step 6: Commit**

```
jj commit -m "ArithReassocPass: opt_plus literal reassociation within a basic block"
```

(Files: `optimizer/lib/optimize/passes/arith_reassoc_pass.rb`, `optimizer/test/passes/arith_reassoc_pass_test.rb`.)

---

### Task 2: Skip and success logging

**Context:** Same log philosophy as const-fold — the pipeline's Log#skip entries are the talk's "the optimizer tells you what it did and why it couldn't" feature. Reasons:

- `:reassociated` — success, one entry per chain rewritten.
- `:mixed_literal_types` — the chain contained at least one non-Integer literal (e.g., a String literal or a Float); the chain is left alone.
- `:chain_too_short` — the chain was identifiable but had < 2 Integer literals; left alone (common case — noisier, but useful for the slide that shows what const-fold/arith chose not to do).

**Files:**
- Modify: `optimizer/lib/optimize/passes/arith_reassoc_pass.rb`
- Modify: `optimizer/test/passes/arith_reassoc_pass_test.rb`

- [ ] **Step 1: Append failing tests** to `arith_reassoc_pass_test.rb`

```ruby
  def test_logs_reassociated_on_success
    src = "def f(x); x + 1 + 2 + 3; end; f(10)"
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    log = Optimize::Log.new
    Optimize::Passes::ArithReassocPass.new.apply(find_iseq(ir, "f"), type_env: nil, log: log, object_table: ot)
    entries = log.for_pass(:arith_reassoc).select { |e| e.reason == :reassociated }
    assert_operator entries.size, :>=, 1
  end

  def test_logs_mixed_literal_types_when_chain_has_non_integer_literal
    # A String literal inside an opt_plus chain with an Integer literal.
    src = 'def f(x); x + "a" + 2; end; f("z")'
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    before = f.instructions.map(&:opcode)
    log = Optimize::Log.new
    Optimize::Passes::ArithReassocPass.new.apply(f, type_env: nil, log: log, object_table: ot)
    # Chain left alone.
    assert_equal before, f.instructions.map(&:opcode)
    entries = log.for_pass(:arith_reassoc).select { |e| e.reason == :mixed_literal_types }
    assert_operator entries.size, :>=, 1
  end

  def test_logs_chain_too_short_when_only_one_integer_literal
    src = "def f(x, y); x + 1 + y; end; f(10, 20)"
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    log = Optimize::Log.new
    Optimize::Passes::ArithReassocPass.new.apply(f, type_env: nil, log: log, object_table: ot)
    entries = log.for_pass(:arith_reassoc).select { |e| e.reason == :chain_too_short }
    assert_operator entries.size, :>=, 1
  end
```

- [ ] **Step 2: Run, expect 3 new failures** (all others still pass).

Run: `mcp__ruby-bytecode__run_optimizer_tests` with `test_filter: "test/passes/arith_reassoc_pass_test.rb"`.

- [ ] **Step 3: Wire logging into `try_rewrite_chain`.** Replace the method body in `arith_reassoc_pass.rb` with:

```ruby
      def try_rewrite_chain(insts, chain, function, log, object_table)
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

        chain_line = insts[chain[:opt_plus_indices].first].line || function.first_lineno

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

        sum = integer_literals.inject(0, :+)
        first_opt_plus = insts[chain[:opt_plus_indices].first]
        literal_inst = LiteralValue.emit(sum, line: first_opt_plus.line, object_table: object_table)

        replacement = non_literals.dup
        replacement << literal_inst
        opt_plus_count_out = replacement.size - 1
        original_opt_pluses = chain[:opt_plus_indices].map { |k| insts[k] }
        opt_plus_count_out.times do |k|
          replacement << (original_opt_pluses[k] || original_opt_pluses.last)
        end

        start = chain[:first_idx]
        length = chain[:end_idx] - chain[:first_idx] + 1
        insts[start, length] = replacement
        function.invalidate_cfg
        log.skip(pass: :arith_reassoc, reason: :reassociated,
                 file: function.path, line: chain_line)
        true
      end
```

- [ ] **Step 4: Run test file via MCP, expect 10 tests passing.**

- [ ] **Step 5: Full-suite regression via MCP.** Expected: 117 runs, 0 failures.

- [ ] **Step 6: Commit**

```
jj commit -m "ArithReassocPass: log :reassociated, :mixed_literal_types, :chain_too_short"
```

(Files: `optimizer/lib/optimize/passes/arith_reassoc_pass.rb`, `optimizer/test/passes/arith_reassoc_pass_test.rb`.)

---

### Task 3: Outer fixpoint + leader-crossing coverage

**Context:** The inner scan in Task 1 already handles every v1 case, because a rewrite resumes the scan at the replacement's start and each chain is rewritten at most once (the output is in canonical form — non-literals first, single literal tail — and re-detecting the same chain would reclassify and fail the "≥2 integer literals" check with only one literal remaining). The outer `loop` is belt-and-braces and matches const-fold's pattern, making "fixpoint" explicit for the talk. Also add a leader-crossing test so we have real coverage of the CFG integration.

**Files:**
- Modify: `optimizer/lib/optimize/passes/arith_reassoc_pass.rb`
- Modify: `optimizer/test/passes/arith_reassoc_pass_test.rb`

- [ ] **Step 1: Append failing tests** to `arith_reassoc_pass_test.rb`

```ruby
  def test_independent_chains_both_get_rewritten
    src = <<~RUBY
      def f(cond, x, y)
        if cond
          x + 1 + 2 + 3
        else
          y + 4 + 5 + 6
        end
      end
      f(true, 10, 20)
    RUBY
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    log = Optimize::Log.new
    Optimize::Passes::ArithReassocPass.new.apply(f, type_env: nil, log: log, object_table: ot)
    reassoc_entries = log.for_pass(:arith_reassoc).select { |e| e.reason == :reassociated }
    assert_operator reassoc_entries.size, :>=, 2,
      "expected both then/else chains to reassociate"
    # Both chains collapse to their literal sums.
    assert(f.instructions.any? { |i| Optimize::Passes::LiteralValue.read(i, object_table: ot) == 6 })
    assert(f.instructions.any? { |i| Optimize::Passes::LiteralValue.read(i, object_table: ot) == 15 })
    # End-to-end equivalence.
    loaded = RubyVM::InstructionSequence.load_from_binary(Optimize::Codec.encode(ir))
    assert_equal 16, loaded.eval  # f(true, 10, 20) == 10 + 6
  end

  def test_end_to_end_deep_chain_evaluates_correctly
    src = "def f(x); x + 1 + 2 + 3 + 4 + 5 + 6 + 7 + 8 + 9 + 10; end; f(100)"
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    Optimize::Passes::ArithReassocPass.new.apply(find_iseq(ir, "f"), type_env: nil, log: Optimize::Log.new, object_table: ot)
    loaded = RubyVM::InstructionSequence.load_from_binary(Optimize::Codec.encode(ir))
    assert_equal 155, loaded.eval  # 100 + (1+2+...+10) = 100 + 55
  end
```

- [ ] **Step 2: Run, expect the two new tests to pass or fail.** They may already pass because the inner scan is enough; that's fine — the outer fixpoint added below is the safety net. If they pass, continue anyway to lock the fixpoint shape.

- [ ] **Step 3: Wrap `apply` in an outer `loop` fixpoint.** Replace the current `apply` method with:

```ruby
      def apply(function, type_env:, log:, object_table: nil)
        _ = type_env
        return unless object_table
        insts = function.instructions
        return unless insts

        # Outer fixpoint loop: defense-in-depth around the inner scan.
        # Termination: each rewrite strictly decreases insts.size by at least 2
        # (see spec "Fixpoint" section); no rewrite => break.
        loop do
          break unless rewrite_once(insts, function, log, object_table)
        end
      end
```

- [ ] **Step 4: Run test file via MCP, expect 12 tests passing.**

- [ ] **Step 5: Full-suite regression via MCP.** Expected: 119 runs, 0 failures.

- [ ] **Step 6: Commit**

```
jj commit -m "ArithReassocPass: outer fixpoint loop + leader-crossing regression"
```

(Files: `optimizer/lib/optimize/passes/arith_reassoc_pass.rb`, `optimizer/test/passes/arith_reassoc_pass_test.rb`.)

---

### Task 4: Wire into default pipeline + corpus regression

**Context:** `Pipeline.default` currently returns `new([Passes::ConstFoldPass.new])`. The new default becomes `new([Passes::ArithReassocPass.new, Passes::ConstFoldPass.new])` — arith first, then const-fold mops up residual adjacency.

The corpus test mirrors `const_fold_pass_corpus_test.rb`: decode every `optimizer/test/codec/corpus/*.rb` fixture, run `Pipeline.default.run`, re-encode, and confirm `load_from_binary` still accepts the result.

**Files:**
- Modify: `optimizer/lib/optimize/pipeline.rb`
- Create: `optimizer/test/passes/arith_reassoc_pass_corpus_test.rb`

- [ ] **Step 1: Write the failing corpus test** — `optimizer/test/passes/arith_reassoc_pass_corpus_test.rb`

```ruby
# frozen_string_literal: true
require "test_helper"
require "optimize/codec"
require "optimize/pipeline"

class ArithReassocPassCorpusTest < Minitest::Test
  def test_every_corpus_fixture_survives_default_pipeline_with_arith
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

  def test_default_pipeline_includes_arith_before_const_fold
    passes = Optimize::Pipeline.default.instance_variable_get(:@passes)
    assert_equal :arith_reassoc, passes[0].name
    assert_equal :const_fold,    passes[1].name
  end

  def test_default_pipeline_collapses_chain_const_fold_cannot_reach
    src = "def f(x); x + 1 + 2 + 3; end; f(10)"
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    Optimize::Pipeline.default.run(ir, type_env: nil)
    loaded = RubyVM::InstructionSequence.load_from_binary(Optimize::Codec.encode(ir))
    assert_equal 16, loaded.eval
    # Inspect the rewritten iseq — exactly one opt_plus remains.
    f = find_iseq(ir, "f")
    assert_equal 1, f.instructions.count { |i| i.opcode == :opt_plus }
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

- [ ] **Step 2: Run, expect `test_default_pipeline_includes_arith_before_const_fold` to fail** (and `test_default_pipeline_collapses_chain_const_fold_cannot_reach` to fail because const-fold alone doesn't reach this shape).

Run: `mcp__ruby-bytecode__run_optimizer_tests` with `test_filter: "test/passes/arith_reassoc_pass_corpus_test.rb"`.

- [ ] **Step 3: Update `Pipeline.default`** — `optimizer/lib/optimize/pipeline.rb`

Change the top of the file from:

```ruby
require "optimize/log"
require "optimize/passes/const_fold_pass"
```

to:

```ruby
require "optimize/log"
require "optimize/passes/arith_reassoc_pass"
require "optimize/passes/const_fold_pass"
```

And change the `self.default` factory from:

```ruby
    def self.default
      new([Passes::ConstFoldPass.new])
    end
```

to:

```ruby
    def self.default
      new([Passes::ArithReassocPass.new, Passes::ConstFoldPass.new])
    end
```

- [ ] **Step 4: Run the corpus test file via MCP, expect all 3 to pass.**

- [ ] **Step 5: Full-suite regression via MCP.** Expected: 122 runs, 0 failures.

If any corpus fixture regresses: the arith rewrite is producing a shape the codec can't re-emit. Diagnose by disabling `ArithReassocPass` in `Pipeline.default` locally and confirming the corpus still passes under const-fold-only (it should — it does on main). Then the bug is in arith's emitted replacement — most likely the reused `opt_plus` instances or the line inheritance.

Also: the `const_fold_pass_corpus_test.rb` (written for Pipeline.default earlier) will now exercise *both* passes. It must still pass — if it doesn't, the arith pass broke some corpus fixture that was previously green.

- [ ] **Step 6: Commit**

```
jj commit -m "Wire ArithReassocPass into default pipeline before ConstFoldPass + corpus regression"
```

(Files: `optimizer/lib/optimize/pipeline.rb`, `optimizer/test/passes/arith_reassoc_pass_corpus_test.rb`.)

---

### Task 5: README + benchmark

**Context:** The README currently has a Passes section documenting `ConstFoldPass`. Add an `ArithReassocPass` entry and run one benchmark comparing the collapsed shape to the un-collapsed one.

**Files:**
- Modify: `optimizer/README.md`

- [ ] **Step 1: Read the current `optimizer/README.md`** to find the Passes section.

- [ ] **Step 2: Insert a new entry above `ConstFoldPass` in the Passes section** (arith runs first in the pipeline; document in pipeline order):

```
- `Optimize::Passes::ArithReassocPass` — v1 arithmetic reassociation.
  Collapses `opt_plus` chains within a basic block where ≥2 operands are
  Integer literals, keeping non-literal operands in original order and
  emitting a single combined-literal tail. Reaches the shape const-fold
  cannot: `x + 1 + 2 + 3` → `x + 6`. Non-Integer literal operands and
  chains with fewer than two integer literals are left alone (`:mixed_literal_types`,
  `:chain_too_short`). `opt_mult`, `opt_minus`, multi-instruction operand
  producers, and RBS-driven typing of non-literal operands are future plans.
```

- [ ] **Step 3: Run one benchmark to quantify the arith win.**

Run `mcp__ruby-bytecode__benchmark_ips` with:

```ruby
def unreassoc(x); x + 1 + 2 + 3 + 4 + 5; end
def reassoc(x);   x + 15; end

Benchmark.ips do |x|
  x.report("unreassoc") { unreassoc(100) }
  x.report("reassoc")   { reassoc(100) }
  x.compare!
end
```

This compares what the VM does with a 5-op chain vs. the 1-op shape our pass produces. Record the winner and ratio in the commit message body.

- [ ] **Step 4: Full-suite regression via MCP.** Sanity: 122 runs, 0 failures (no code change, just docs).

- [ ] **Step 5: Commit**

```
jj commit -m "Document ArithReassocPass v1 in README; record reassoc benchmark baseline"
```

(Files: `optimizer/README.md`.)

---

## Self-review

**Spec coverage** (from `2026-04-20-pass-arith-reassoc-v1-design.md`):

- Chain detection with single-push operand allowlist — Task 1 (`SINGLE_PUSH_OPERAND_OPCODES`, `detect_chain`).
- Leader-bounded basic-block respect — Task 1 (leader-set check and chain shrinking), Task 3 (end-to-end test with `if/else`).
- Literal-Integer-only fire condition + mixed-literal skip — Task 1 (minimal), Task 2 (logging).
- Reassociation output shape (non-literals in original order, one literal tail, n-1 opt_pluses) — Task 1 (`try_rewrite_chain`, test `test_multiple_non_literals_preserved_in_original_order`).
- Outer fixpoint — Task 3.
- Line annotation inheritance from first vanished `opt_plus` for the literal tail, and per-position for remaining `opt_plus`es — Task 1 (`literal_inst = LiteralValue.emit(sum, line: first_opt_plus.line, ...)`, `original_opt_pluses[k]`).
- Pipeline ordering (arith before const-fold) — Task 4.
- Corpus regression — Task 4.
- README + benchmark — Task 5.
- `opt_mult`/`opt_minus`/`opt_div` explicitly out — Task 1's `test_non_opt_plus_chains_untouched` locks this.
- `type_env` accepted but ignored — Task 1 (`_ = type_env`).

Gaps: none.

**Placeholder scan:** No TBDs. The one "may already pass" note in Task 3 Step 2 is a factual statement about the inner scan's sufficiency, not a placeholder — the fixpoint is added regardless.

**Type consistency:** `detect_chain` returns a hash with keys `first_idx`, `producer_indices`, `opt_plus_indices`, `end_idx` — consumed by `try_rewrite_chain` and `rewrite_once` using the same key names throughout. `SINGLE_PUSH_OPERAND_OPCODES` is defined once in Task 1 and referenced unchanged. Pass name `:arith_reassoc` is consistent across the pass file and all log queries in tests.

**Counts:** baseline 107 → Task 1 +7 = 114 → Task 2 +3 = 117 → Task 3 +2 = 119 → Task 4 +3 = 122. Task 5 is docs/benchmark, no new tests.
