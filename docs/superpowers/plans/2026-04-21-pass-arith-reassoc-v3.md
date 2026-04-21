# Arith Reassoc Pass v3 — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend `ArithReassocPass` to fold the full additive group — chains mixing `opt_plus` and `opt_minus` — so that `x + 1 - 2 + 3` collapses to `x + 2` (and `x + 1 - y + 2` to `x - y + 3`). Restructure the pass's operator table to carry per-group op maps so v4 (multiplicative with `opt_div`) slots in cleanly later.

**Architecture:** `REASSOC_OPS` is renamed to `REASSOC_GROUPS`. Each entry becomes `{ops: {opcode => combiner_method}, identity:, primary_op:}`, where `ops` is an insertion-ordered map of every opcode in the group paired with the Symbol method used to fold that op's RHS literal into the running accumulator. `primary_op` is the opcode used to emit the single literal-carrying trailing op after a rewrite. The v3 additive entry is `{ops: {opt_plus: :+, opt_minus: :-}, identity: 0, primary_op: :opt_plus}`. `detect_chain` returns op positions as `[{idx:, opcode:}, ...]` so the rewriter can fold each literal with the right combiner and tag each non-literal with its effective sign. Non-literals partition into `pos`/`neg` by effective sign, emit as `pos ++ neg` with adjacent-sign-driven intermediate ops, tail `push <reduced>; opt_plus`. Chains whose non-literals are all negative-signed are left alone (`:no_positive_nonliteral`).

**Tech Stack:** Ruby 4.0.2, minitest, the `ruby-bytecode` MCP for all test runs.

**Spec:** `docs/superpowers/specs/2026-04-21-pass-arith-reassoc-v3-design.md`.

**Commit discipline:** Each task ends with `jj commit -m "<msg>"`. Executors MUST translate that to `jj split -m "<msg>" -- <files>` using the exact file list from the task's Files section. Use `jj commit -m` (not `jj describe -m`) to finalize. Never commit via host bash wrappers. Tests via `mcp__ruby-bytecode__run_optimizer_tests` only, never host `rake test`.

**Baseline test count after v2: 134 green.**

---

## File structure

```
optimizer/
  lib/ruby_opt/
    passes/
      arith_reassoc_pass.rb              # MODIFIED Task 1 (rename + shape) + Task 2 (opt_minus)
  test/
    passes/
      arith_reassoc_pass_test.rb         # MODIFIED Task 2 — v3 unit tests + v2 loose-end
  README.md                              # MODIFIED Task 3 (optional)
```

No new files. No pipeline wiring changes (`Pipeline.default` already carries `ArithReassocPass`). No `Log` schema changes (`Log#skip` accepts arbitrary symbols).

---

### Task 1: Rename `REASSOC_OPS` → `REASSOC_GROUPS` and reshape entries

**Context:** Pure structural refactor, zero behavior change. `REASSOC_OPS` is renamed to `REASSOC_GROUPS`. Each entry's `{opcode:, identity:, reducer:}` becomes `{ops:, identity:, primary_op:}` where `ops` is an `opcode → combiner_method` map. In this task every group has exactly one op (the additive group is `{opt_plus: :+}` and the multiplicative group is `{opt_mult: :*}`), which is semantically identical to v2.

`detect_chain` now returns its op positions as `[{idx:, opcode:}, ...]` instead of a bare `[idx, ...]`. This is a shape change, not a behavior change — with one op per group today, the opcode field is redundant (it equals `insts[idx].opcode`), but it's populated here so Task 2's sign-tracking code has no data-shape work to do.

The v2 file currently hard-codes `op_spec[:opcode]` in two sites (the forward scan in `rewrite_once` and the backward walk in `detect_chain`) and `op_spec[:reducer]` in one site (the `inject` in `try_rewrite_chain`). After this task:

- Both opcode comparisons become `group[:ops].key?(insts[...].opcode)`.
- The reduction becomes `inject(group[:identity]) { |acc, (val, combiner)| acc.send(combiner, val) }` where `combiner` is looked up per-producer from `group[:ops]`.
- The tail op uses `group[:primary_op]` as an opcode (via `IR::Instruction.new`), not the reused original op.

All 134 existing tests must stay green.

**Files:**
- Modify: `optimizer/lib/ruby_opt/passes/arith_reassoc_pass.rb`

- [ ] **Step 1: Baseline — run the full suite via MCP, confirm 134 green, 0 failures.**

Run: `mcp__ruby-bytecode__run_optimizer_tests` with no `test_filter`.

Expected: 134 runs, 0 failures.

If the baseline is not 134/0, STOP. The plan assumes v2 is fully green. Do not proceed with the refactor.

- [ ] **Step 2: Replace the pass file with the refactored version.**

Overwrite `optimizer/lib/ruby_opt/passes/arith_reassoc_pass.rb` with the following. Behavior is identical to v2 for both the additive and multiplicative paths.

```ruby
# frozen_string_literal: true
require "set"
require "ruby_opt/pass"
require "ruby_opt/passes/literal_value"
require "ruby_opt/ir/cfg"
require "ruby_opt/ir/instruction"

module RubyOpt
  module Passes
    # Arithmetic reassociation within a basic block, driven by REASSOC_GROUPS.
    # See docs/superpowers/specs/2026-04-21-pass-arith-reassoc-v3-design.md.
    class ArithReassocPass < RubyOpt::Pass
      # Each entry describes one commutative-associative group of operators:
      #   ops:        opcode => Symbol method used to combine that op's RHS
      #               literal into the running accumulator. Insertion-ordered.
      #   identity:   neutral element for the group (0 for +, 1 for *).
      #   primary_op: opcode used to emit the single literal-carrying trailing
      #               op after a rewrite. Must be a key in `ops`.
      REASSOC_GROUPS = [
        { ops: { opt_plus: :+ }, identity: 0, primary_op: :opt_plus },
        { ops: { opt_mult: :* }, identity: 1, primary_op: :opt_mult },
      ].freeze

      # ObjectTable#intern accepts integers with bit_length < 62
      # (i.e. values in -(2^61)..(2^61)-1). Results outside this range
      # cannot be interned and must be skipped.
      INTERN_BIT_LENGTH_LIMIT = 62

      # Opcodes that each push exactly one value, pop zero, and have no
      # side effects relevant to reordering literals past them. Shared across
      # all REASSOC_GROUPS entries. Widening this list without re-examining the
      # "all entries are side-effect-free w.r.t. each other" invariant would
      # break the non-literal reordering rule used by the additive group.
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

        # Outer any-rewrite fixpoint: a rewrite in one group can expose chains
        # in another group (e.g. mult folding `2 * 3 → 6` exposes a + chain
        # that plus missed on its first visit). See spec "Two-level fixpoint".
        loop do
          any_outer = false
          REASSOC_GROUPS.each do |group|
            loop do
              break unless rewrite_once(insts, function, log, object_table, group: group)
              any_outer = true
            end
          end
          break unless any_outer
        end
      end

      private

      def rewrite_once(insts, function, log, object_table, group:)
        any = false
        leader_set = Set.new(IR::CFG.compute_leaders(insts))
        i = 0
        while i < insts.size
          if group[:ops].key?(insts[i].opcode)
            chain = detect_chain(insts, i, leader_set, group: group)
            if chain && try_rewrite_chain(insts, chain, function, log, object_table, group: group)
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

      def detect_chain(insts, end_idx, leader_set, group:)
        prod_indices = []
        op_positions = [{ idx: end_idx, opcode: insts[end_idx].opcode }]
        j = end_idx - 1
        return nil unless j >= 0 && single_push?(insts[j])
        prod_indices.unshift(j)

        loop do
          op_j = j - 1
          prod_j = j - 2
          break if op_j < 0 || prod_j < 0
          break unless group[:ops].key?(insts[op_j].opcode)
          break unless single_push?(insts[prod_j])
          op_positions.unshift({ idx: op_j, opcode: insts[op_j].opcode })
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
          op_positions = op_positions.last(prod_indices.size - 1) if prod_indices.size >= 1
        end

        return nil if prod_indices.size < 2
        {
          first_idx: prod_indices.first,
          producer_indices: prod_indices,
          op_positions: op_positions,
          end_idx: end_idx,
        }
      end

      def single_push?(inst)
        SINGLE_PUSH_OPERAND_OPCODES.include?(inst.opcode)
      end

      def try_rewrite_chain(insts, chain, function, log, object_table, group:)
        producer_insts = chain[:producer_indices].map { |k| insts[k] }

        # Combiner for each producer is the combiner of the op immediately to
        # its left in the chain. The leftmost producer uses the primary op's
        # combiner (equivalent to being preceded by an identity-friendly op).
        primary_combiner = group[:ops].fetch(group[:primary_op])
        producer_combiners = producer_insts.each_with_index.map do |_p, k|
          if k == 0
            primary_combiner
          else
            op_opcode = chain[:op_positions][k - 1][:opcode]
            group[:ops].fetch(op_opcode)
          end
        end

        classified = producer_insts.each_with_index.map do |p, k|
          v = LiteralValue.read(p, object_table: object_table)
          is_lit = LiteralValue.literal?(p)
          { inst: p, value: v, is_literal: is_lit, combiner: producer_combiners[k] }
        end

        integer_literals = classified.select { |c| c[:is_literal] && c[:value].is_a?(Integer) }
        non_integer_literals = classified.select { |c| c[:is_literal] && !c[:value].is_a?(Integer) }
        non_literals = classified.reject { |c| c[:is_literal] }

        chain_line = insts[chain[:op_positions].first[:idx]].line || function.first_lineno

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

        reduced = integer_literals.inject(group[:identity]) do |acc, c|
          acc.send(c[:combiner], c[:value])
        end
        unless fits_intern_range?(reduced)
          log.skip(pass: :arith_reassoc, reason: :would_exceed_intern_range,
                   file: function.path, line: chain_line)
          return false
        end

        first_op_inst = insts[chain[:op_positions].first[:idx]]
        literal_inst = LiteralValue.emit(reduced, line: first_op_inst.line, object_table: object_table)

        replacement = build_replacement(non_literals, literal_inst, first_op_inst, group)

        range = chain[:first_idx]..chain[:end_idx]
        function.splice_instructions!(range, replacement)
        log.skip(pass: :arith_reassoc, reason: :reassociated,
                 file: function.path, line: chain_line)
        true
      end

      # Task-1 behavior: every producer in the group uses the same combiner
      # (the primary op's), so non-literal order is preserved and every
      # intermediate op is the primary op. Task 2 overrides this logic for
      # the additive group (sign-aware partition + reorder).
      def build_replacement(non_literals, literal_inst, first_op_inst, group)
        replacement = non_literals.map { |c| c[:inst] }
        replacement << literal_inst
        op_count_out = replacement.size - 1
        op_count_out.times do
          replacement << IR::Instruction.new(
            opcode: group[:primary_op],
            operands: first_op_inst.operands,
            line: first_op_inst.line,
          )
        end
        replacement
      end

      def fits_intern_range?(n)
        n.is_a?(Integer) && n.bit_length < INTERN_BIT_LENGTH_LIMIT
      end
    end
  end
end
```

Notes on what changed from v2, strictly:

1. Constant `REASSOC_OPS` → `REASSOC_GROUPS`.
2. Entry shape: `{opcode:, identity:, reducer:}` → `{ops:, identity:, primary_op:}`. Each entry has one op today.
3. Kwarg `op_spec:` → `group:` everywhere (`rewrite_once`, `detect_chain`, `try_rewrite_chain`).
4. Opcode comparison in two sites: `insts[i].opcode == op_spec[:opcode]` → `group[:ops].key?(insts[i].opcode)`.
5. Chain hash key `:op_indices` (list of ints) → `:op_positions` (list of `{idx:, opcode:}`). `detect_chain` populates the `:opcode` field at each shift.
6. Reduction: `inject(op_spec[:identity], op_spec[:reducer])` → `inject(group[:identity]) { |acc, c| acc.send(c[:combiner], c[:value]) }` using a per-producer combiner lookup. For a single-op group this is identical to v2.
7. `classified` switched from a 3-tuple to a hash. This gives each producer a `combiner` field that Task 2 will exploit; in Task 1 the combiner is always the primary op's (same for every producer in a single-op group).
8. Tail ops: replaced `original_ops = chain[:op_indices].map { |k| insts[k] }` reuse with `IR::Instruction.new(opcode: group[:primary_op], operands: first_op_inst.operands, line: first_op_inst.line)` construction. For a single-op group these instructions are semantically equivalent to the originals (same opcode, same operands shape — `opt_plus` / `opt_mult` inline-cache operands are reconstituted identically by the codec on re-encode). Extracted to a `build_replacement` helper so Task 2 can override it for the additive group.
9. Added `require "ruby_opt/ir/instruction"` since we now construct `IR::Instruction` directly.

No test changes. No other file changes.

- [ ] **Step 3: Run the full suite via MCP, expect 134 green still.**

Run: `mcp__ruby-bytecode__run_optimizer_tests` with no `test_filter`.

Expected: 134 runs, 0 failures.

If any test fails: the refactor has drifted from v2 behavior. Most likely culprit: the tail-op reconstruction in `build_replacement` is building an instruction shape that differs from the original op in some non-obvious way (e.g., missing inline-cache operand slots). Confirm by diffing the instruction record for an `opt_mult` before and after the pass on any of the v2 opt_mult tests. Second likely culprit: a stale `chain[:op_indices]` reference somewhere (grep the file for `op_indices` — there should be zero occurrences after the refactor).

- [ ] **Step 4: Commit.**

```
jj commit -m "ArithReassocPass: refactor REASSOC_OPS → REASSOC_GROUPS (no behavior change)"
```

(Files: `optimizer/lib/ruby_opt/passes/arith_reassoc_pass.rb`.)

---

### Task 2: Add `opt_minus` to the additive group + sign-aware rewrite + reordering + tests

**Context:** With the table reshaped in Task 1, adding `opt_minus` is one new entry in the additive group's `ops` map. But the rewrite also needs to:

1. **Track per-producer combiner correctly.** Task 1 already derives `combiner` per producer from the op to its left, but in a single-op group they're all the same. With `opt_plus: :+` and `opt_minus: :-` both present, combiners diverge: a literal to the right of `opt_plus` folds via `:+`, to the right of `opt_minus` via `:-`. Task 1's `acc.send(c[:combiner], c[:value])` reduction already handles this uniformly.

2. **Partition non-literals by effective sign and reorder.** Non-literals with effective sign `+` lead, non-literals with effective sign `−` follow. If all non-literals are `−`-signed, skip with `:no_positive_nonliteral` because the leading operand would need runtime negation.

3. **Emit intermediate ops based on adjacent signs.** `pos[i] → pos[i+1]` gets `opt_plus`; `pos[-1] → neg[0]` and `neg[i] → neg[i+1]` get `opt_minus`. Tail literal always uses `primary_op` (`opt_plus`), even when the literal is negative.

4. **Emit `:no_positive_nonliteral` skip log.**

The multiplicative group's rewrite path is unchanged — its one op is also its primary op, so `build_replacement`'s Task-1 logic is already correct for it. Task 2's sign-aware replacement path is guarded by "group has >1 op" or equivalently "any producer's combiner differs from the primary op's combiner."

Effective sign of a non-literal producer: `+` if its combiner is the primary op's combiner (`:+` for additive, `:*` for multiplicative), `−` otherwise. For the additive group with `primary_op: :opt_plus`, combiner `:+` → sign `+`, combiner `:-` → sign `−`. For any single-op group (today the multiplicative one), every combiner is the primary's, so every non-literal is `+`-signed and the partition is a no-op.

**Files:**
- Modify: `optimizer/lib/ruby_opt/passes/arith_reassoc_pass.rb`
- Modify: `optimizer/test/passes/arith_reassoc_pass_test.rb`

- [ ] **Step 1: Append the failing tests to `arith_reassoc_pass_test.rb`.**

Open `optimizer/test/passes/arith_reassoc_pass_test.rb`. Insert the following block **immediately before** the `private` line (which currently sits just after `test_opt_mult_deep_chain_end_to_end`).

```ruby
  # ---- opt_minus / additive group ----

  def test_opt_plus_minus_collapses_leading_non_literal_chain
    src = "def f(x); x + 1 - 2 + 3; end; f(10)"
    ir = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    RubyOpt::Passes::ArithReassocPass.new.apply(f, type_env: nil, log: RubyOpt::Log.new, object_table: ot)

    assert_equal 1, f.instructions.count { |i| i.opcode == :opt_plus }
    assert_equal 0, f.instructions.count { |i| i.opcode == :opt_minus }
    refute_nil f.instructions.find { |i| RubyOpt::Passes::LiteralValue.read(i, object_table: ot) == 2 }
    loaded = RubyVM::InstructionSequence.load_from_binary(RubyOpt::Codec.encode(ir))
    assert_equal 12, loaded.eval
  end

  def test_opt_minus_only_chain_emits_negative_literal
    src = "def f(x); x - 1 - 2 - 3; end; f(10)"
    ir = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    RubyOpt::Passes::ArithReassocPass.new.apply(f, type_env: nil, log: RubyOpt::Log.new, object_table: ot)

    assert_equal 1, f.instructions.count { |i| i.opcode == :opt_plus }
    assert_equal 0, f.instructions.count { |i| i.opcode == :opt_minus }
    refute_nil f.instructions.find { |i| RubyOpt::Passes::LiteralValue.read(i, object_table: ot) == -6 }
    loaded = RubyVM::InstructionSequence.load_from_binary(RubyOpt::Codec.encode(ir))
    assert_equal 4, loaded.eval
  end

  def test_opt_plus_minus_folds_to_negative_literal
    src = "def f(x); x - 5 + 3; end; f(10)"
    ir = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    RubyOpt::Passes::ArithReassocPass.new.apply(f, type_env: nil, log: RubyOpt::Log.new, object_table: ot)

    assert_equal 1, f.instructions.count { |i| i.opcode == :opt_plus }
    assert_equal 0, f.instructions.count { |i| i.opcode == :opt_minus }
    refute_nil f.instructions.find { |i| RubyOpt::Passes::LiteralValue.read(i, object_table: ot) == -2 }
    loaded = RubyVM::InstructionSequence.load_from_binary(RubyOpt::Codec.encode(ir))
    assert_equal 8, loaded.eval
  end

  def test_opt_plus_minus_with_pos_and_neg_non_literals
    # x + 1 - y + 2: pos=[x], neg=[y], literal=3 → emit "x - y + 3"
    src = "def f(x, y); x + 1 - y + 2; end; f(10, 4)"
    ir = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    RubyOpt::Passes::ArithReassocPass.new.apply(f, type_env: nil, log: RubyOpt::Log.new, object_table: ot)

    assert_equal 1, f.instructions.count { |i| i.opcode == :opt_plus },
      "one opt_plus for the literal tail"
    assert_equal 1, f.instructions.count { |i| i.opcode == :opt_minus },
      "one opt_minus between x and y"
    refute_nil f.instructions.find { |i| RubyOpt::Passes::LiteralValue.read(i, object_table: ot) == 3 }
    loaded = RubyVM::InstructionSequence.load_from_binary(RubyOpt::Codec.encode(ir))
    assert_equal 9, loaded.eval
  end

  def test_opt_plus_minus_all_negative_non_literals_is_skipped
    # 1 - x + 2 - y + 3: pos=[], neg=[x, y] → skip :no_positive_nonliteral.
    src = "def f(x, y); 1 - x + 2 - y + 3; end; f(10, 4)"
    ir = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    before_opcodes = f.instructions.map(&:opcode)
    log = RubyOpt::Log.new
    RubyOpt::Passes::ArithReassocPass.new.apply(f, type_env: nil, log: log, object_table: ot)

    assert_equal before_opcodes, f.instructions.map(&:opcode),
      ":no_positive_nonliteral should leave the chain untouched"
    entries = log.for_pass(:arith_reassoc).select { |e| e.reason == :no_positive_nonliteral }
    assert_operator entries.size, :>=, 1

    loaded = RubyVM::InstructionSequence.load_from_binary(RubyOpt::Codec.encode(ir))
    assert_equal (1 - 10 + 2 - 4 + 3), loaded.eval # -8
  end

  def test_opt_plus_minus_single_leading_negative_is_skipped
    # 1 - x + 2: pos=[], neg=[x] → skip.
    src = "def f(x); 1 - x + 2; end; f(4)"
    ir = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    before_opcodes = f.instructions.map(&:opcode)
    log = RubyOpt::Log.new
    RubyOpt::Passes::ArithReassocPass.new.apply(f, type_env: nil, log: log, object_table: ot)

    assert_equal before_opcodes, f.instructions.map(&:opcode)
    entries = log.for_pass(:arith_reassoc).select { |e| e.reason == :no_positive_nonliteral }
    assert_operator entries.size, :>=, 1

    loaded = RubyVM::InstructionSequence.load_from_binary(RubyOpt::Codec.encode(ir))
    assert_equal (1 - 4 + 2), loaded.eval # -1
  end

  def test_opt_plus_minus_mixed_literal_types_is_skipped
    src = "def f(x); x + 1 - 1.5; end; f(4)"
    ir = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    before_opcodes = f.instructions.map(&:opcode)
    log = RubyOpt::Log.new
    RubyOpt::Passes::ArithReassocPass.new.apply(f, type_env: nil, log: log, object_table: ot)

    assert_equal before_opcodes, f.instructions.map(&:opcode)
    entries = log.for_pass(:arith_reassoc).select { |e| e.reason == :mixed_literal_types }
    assert_operator entries.size, :>=, 1
  end

  def test_opt_minus_single_literal_chain_is_left_alone
    src = "def f(x); x - 1; end; f(10)"
    ir = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    before_opcodes = f.instructions.map(&:opcode)
    RubyOpt::Passes::ArithReassocPass.new.apply(f, type_env: nil, log: RubyOpt::Log.new, object_table: ot)
    assert_equal before_opcodes, f.instructions.map(&:opcode)
  end

  def test_opt_plus_minus_no_literals_chain_is_left_alone
    src = "def f(x, y, z); x - y + z; end; f(10, 4, 2)"
    ir = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    before_opcodes = f.instructions.map(&:opcode)
    RubyOpt::Passes::ArithReassocPass.new.apply(f, type_env: nil, log: RubyOpt::Log.new, object_table: ot)
    assert_equal before_opcodes, f.instructions.map(&:opcode)
  end

  def test_opt_plus_minus_all_literal_chain_folds
    src = "def f; 3 - 1 - 1; end; f"
    ir = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    RubyOpt::Passes::ArithReassocPass.new.apply(f, type_env: nil, log: RubyOpt::Log.new, object_table: ot)

    assert_equal 0, f.instructions.count { |i| i.opcode == :opt_plus }
    assert_equal 0, f.instructions.count { |i| i.opcode == :opt_minus }
    refute_nil f.instructions.find { |i| RubyOpt::Passes::LiteralValue.read(i, object_table: ot) == 1 }
    loaded = RubyVM::InstructionSequence.load_from_binary(RubyOpt::Codec.encode(ir))
    assert_equal 1, loaded.eval
  end

  # ---- cross-group interaction (outer fixpoint with opt_minus in the additive group) ----

  def test_mult_exposes_additive_chain_with_minus
    # x + 2 * 3 - 4 → x + 6 - 4 after mult folds → x + 2 after additive re-runs.
    src = "def f(x); x + 2 * 3 - 4; end; f(10)"
    ir = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    RubyOpt::Passes::ArithReassocPass.new.apply(f, type_env: nil, log: RubyOpt::Log.new, object_table: ot)

    assert_equal 0, f.instructions.count { |i| i.opcode == :opt_mult },
      "mult should have folded 2*3 to a literal"
    assert_equal 1, f.instructions.count { |i| i.opcode == :opt_plus },
      "additive re-run should have collapsed to one opt_plus"
    assert_equal 0, f.instructions.count { |i| i.opcode == :opt_minus },
      "additive re-run should have folded the minus into the literal"
    refute_nil f.instructions.find { |i| RubyOpt::Passes::LiteralValue.read(i, object_table: ot) == 2 }
    loaded = RubyVM::InstructionSequence.load_from_binary(RubyOpt::Codec.encode(ir))
    assert_equal 12, loaded.eval
  end

  # ---- v2 loose-end: opt_mult no-literal chain ----

  def test_opt_mult_no_literals_chain_is_left_alone
    src = "def f(x, y, z); x * y * z; end; f(2, 3, 4)"
    ir = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    before_opcodes = f.instructions.map(&:opcode)
    RubyOpt::Passes::ArithReassocPass.new.apply(f, type_env: nil, log: RubyOpt::Log.new, object_table: ot)
    assert_equal before_opcodes, f.instructions.map(&:opcode)
  end
```

- [ ] **Step 2: Run the arith-reassoc test file via MCP, expect the new tests to fail.**

Run: `mcp__ruby-bytecode__run_optimizer_tests` with `test_filter: "test/passes/arith_reassoc_pass_test.rb"`.

Expected: 134-from-baseline arith-reassoc subset + 12 new = failures on all 12 new tests (the additive group doesn't know about `opt_minus` yet; `opt_minus`-containing chains will pass through unchanged or hit the single-op path that produces wrong results).

Specific expected failures:
- `test_opt_plus_minus_collapses_leading_non_literal_chain`: no rewrite happens (plus's chain detection bails at the first `opt_minus` because it's not in the additive group's `ops` yet). Assertion `assert_equal 1, ...opt_plus` fails — count is 2.
- `test_opt_minus_only_chain_emits_negative_literal`: no rewrite happens. Opt_minus count stays 3.
- `test_opt_plus_minus_folds_to_negative_literal`: no rewrite happens.
- `test_opt_plus_minus_with_pos_and_neg_non_literals`: no rewrite.
- `test_opt_plus_minus_all_negative_non_literals_is_skipped`: the `:no_positive_nonliteral` log entry doesn't exist yet; `assert_operator entries.size, :>=, 1` fails with 0.
- `test_opt_plus_minus_single_leading_negative_is_skipped`: same.
- `test_opt_plus_minus_mixed_literal_types_is_skipped`: may pass by accident — the first `opt_plus` triggers the old additive chain, sees `1.5` in the chain (wait — it wouldn't, because the `opt_minus` breaks chain detection; so no rewrite, and no `:mixed_literal_types` log). Expected: fail on `assert_operator entries.size, :>=, 1`.
- `test_opt_minus_single_literal_chain_is_left_alone`: likely passes (no rewrite either way). Leave as-is.
- `test_opt_plus_minus_no_literals_chain_is_left_alone`: passes (no rewrite either way).
- `test_opt_plus_minus_all_literal_chain_folds`: fails — no rewrite.
- `test_mult_exposes_additive_chain_with_minus`: mult folds `2*3 → 6`, leaves `x + 6 - 4`. Additive chain detection now bails at `opt_minus` (still not in the group). Residual shape: `x + 6 - 4` with one `opt_plus` and one `opt_minus`. Test expects zero `opt_minus`; fails.
- `test_opt_mult_no_literals_chain_is_left_alone`: passes immediately (no literals → no rewrite under v2 semantics). Leave as-is.

Net: at least 9 new tests fail, 3 pass by accident. That's the TDD "red" for this task.

If any pre-existing test fails here, STOP — Task 1's refactor regressed something. Revert and re-run Task 1.

- [ ] **Step 3: Add `opt_minus` to the additive group in `arith_reassoc_pass.rb`.**

Replace the `REASSOC_GROUPS` constant block with:

```ruby
      REASSOC_GROUPS = [
        { ops: { opt_plus: :+, opt_minus: :- }, identity: 0, primary_op: :opt_plus },
        { ops: { opt_mult: :*                 }, identity: 1, primary_op: :opt_mult },
      ].freeze
```

- [ ] **Step 4: Run the arith-reassoc test file via MCP — many additive tests now fail in new ways.**

Run: `mcp__ruby-bytecode__run_optimizer_tests` with `test_filter: "test/passes/arith_reassoc_pass_test.rb"`.

Expected: the additive-chain unit tests now produce wrong outputs because Task 1's `build_replacement` doesn't know about sign-aware partitioning. Concretely:

- `test_opt_plus_minus_collapses_leading_non_literal_chain` (`x + 1 - 2 + 3 → x + 2`): chain is detected (4 producers, 3 ops). Reduction is `0 + 1 - 2 + 3 = 2`. `build_replacement` emits `[x, literal_2, opt_plus]` — by coincidence this is correct because there's only one non-literal (`x`), so no reorder is needed and the single tail op is `opt_plus` (primary). Expect PASS.
- `test_opt_minus_only_chain_emits_negative_literal` (`x - 1 - 2 - 3 → x + (-6)`): chain detected. Reduction `0 - 1 - 2 - 3 = -6`. `build_replacement` emits `[x, literal_-6, opt_plus]`. Single non-literal, no reorder. Expect PASS.
- `test_opt_plus_minus_folds_to_negative_literal` (`x - 5 + 3`): similar, single non-literal. PASS.
- `test_opt_plus_minus_with_pos_and_neg_non_literals` (`x + 1 - y + 2 → x - y + 3`): chain detected with producers `[x, 1, y, 2]`. Task-1 `build_replacement` emits `[x, y, literal_3, opt_plus, opt_plus]` — **WRONG**: it uses `opt_plus` for both intermediate ops, so the result is `x + y + 3`, not `x - y + 3`. Test fails: opt_minus count is 0 instead of 1, and `.eval == 17` instead of 9.
- `test_opt_plus_minus_all_negative_non_literals_is_skipped`: no skip reason emitted yet. Still fails.
- `test_opt_plus_minus_single_leading_negative_is_skipped` (`1 - x + 2 → should skip`): chain detected with producers `[1, x, 2]`. Task-1 reduction: `0 + 1 - x-wait`. Hmm — `x` is a non-literal, so reduction only touches `1` and `2`: `0 + 1 + 2 = 3` (both literals have combiner `:+` in the task-1 view because... wait, no, Task 1 already tags each producer with its combiner from the op to its left. For `1 - x + 2`, ops are `[opt_minus, opt_plus]`. Producer 0 (`1`) gets primary combiner (`:+`). Producer 1 (`x`) gets combiner of ops[0] = `:-`. Producer 2 (`2`) gets combiner of ops[1] = `:+`. Integer literal reduction: `0 + 1 + 2 = 3`. `build_replacement` emits `[x, literal_3, opt_plus]` — again wrong, this evaluates to `x + 3 = 7`, but correct answer is `-1`. Test-side assertion is `assert_equal before_opcodes, ...` and `:no_positive_nonliteral` logged — both fail.

So after Step 3, multiple additive tests regress. That's intentional — Step 5 fixes them by rewriting `build_replacement` to be sign-aware.

If `test_opt_plus_minus_with_pos_and_neg_non_literals` is somehow passing here, STOP — something about the test setup is masking the bug; re-examine the test.

- [ ] **Step 5: Replace `build_replacement` with sign-aware partitioning + reordering, and add the `:no_positive_nonliteral` skip.**

Replace the `build_replacement` method and the `try_rewrite_chain` literal-emission block with the sign-aware version. Make two edits:

**Edit 5a**: Inside `try_rewrite_chain`, insert the `:no_positive_nonliteral` skip check between the `fits_intern_range?` check and the `first_op_inst = insts[...]` line. Find this block:

```ruby
        unless fits_intern_range?(reduced)
          log.skip(pass: :arith_reassoc, reason: :would_exceed_intern_range,
                   file: function.path, line: chain_line)
          return false
        end

        first_op_inst = insts[chain[:op_positions].first[:idx]]
```

And replace it with:

```ruby
        unless fits_intern_range?(reduced)
          log.skip(pass: :arith_reassoc, reason: :would_exceed_intern_range,
                   file: function.path, line: chain_line)
          return false
        end

        primary_combiner = group[:ops].fetch(group[:primary_op])
        has_pos_non_literal = non_literals.any? { |c| c[:combiner] == primary_combiner }
        if !non_literals.empty? && !has_pos_non_literal
          log.skip(pass: :arith_reassoc, reason: :no_positive_nonliteral,
                   file: function.path, line: chain_line)
          return false
        end

        first_op_inst = insts[chain[:op_positions].first[:idx]]
```

**Edit 5b**: Replace the `build_replacement` method body with the sign-aware version:

```ruby
      # Emit the rewritten tail. For single-op groups (today: multiplicative),
      # this preserves non-literal order and fills intermediate ops with the
      # primary op. For multi-op groups (today: additive with opt_plus +
      # opt_minus), non-literals partition into pos/neg by combiner, emit as
      # pos ++ neg with intermediate ops driven by adjacent combiners, tail
      # literal via the primary op.
      def build_replacement(non_literals, literal_inst, first_op_inst, group)
        primary_combiner = group[:ops].fetch(group[:primary_op])

        pos = non_literals.select { |c| c[:combiner] == primary_combiner }
        neg = non_literals.reject { |c| c[:combiner] == primary_combiner }
        ordered = pos + neg

        replacement = []
        ordered.each_with_index do |c, idx|
          replacement << c[:inst]
          next if idx == 0
          # Intermediate op is driven by c's combiner: same as primary →
          # primary op; different → find the opcode in group[:ops] whose
          # combiner matches c's.
          intermediate_opcode = opcode_for_combiner(group, c[:combiner])
          replacement << IR::Instruction.new(
            opcode: intermediate_opcode,
            operands: first_op_inst.operands,
            line: first_op_inst.line,
          )
        end

        # Tail literal + primary op. Skipped entirely when the chain is all-literal.
        replacement << literal_inst
        if !ordered.empty?
          replacement << IR::Instruction.new(
            opcode: group[:primary_op],
            operands: first_op_inst.operands,
            line: first_op_inst.line,
          )
        end

        replacement
      end

      def opcode_for_combiner(group, combiner)
        group[:ops].each { |opcode, c| return opcode if c == combiner }
        raise "no opcode in group for combiner #{combiner.inspect}"
      end
```

Note: `opcode_for_combiner` is a linear scan over a 1-or-2-entry map — fine. The `raise` is a defensive assertion; if it ever fires the `combiner` came from a producer whose adjacent op isn't in the group, which is a chain-detection bug.

Also delete the `first_op_inst` assignment that was the *only* caller-side use of `original_ops` in v2 — there's none to delete here because Task 1 already moved to `IR::Instruction.new` construction.

- [ ] **Step 6: Run the arith-reassoc test file via MCP, expect all tests (old + new) to pass.**

Run: `mcp__ruby-bytecode__run_optimizer_tests` with `test_filter: "test/passes/arith_reassoc_pass_test.rb"`.

Expected: 24 old arith-reassoc tests + 12 new = 36 runs, 0 failures.

Troubleshooting:
- If `test_opt_plus_minus_with_pos_and_neg_non_literals` fails showing `opt_plus` count 2 and `opt_minus` count 0: the `opcode_for_combiner` lookup is returning `:opt_plus` for combiner `:-`. Confirm the additive group literal is `{opt_plus: :+, opt_minus: :-}` — if the values are wrong, combiner lookup maps `:-` to nothing and falls through.
- If `test_opt_plus_minus_all_negative_non_literals_is_skipped` fails with a spurious rewrite: the `:no_positive_nonliteral` guard is missing or placed *after* the splice. Confirm Edit 5a is applied and the guard is above `first_op_inst = ...`.
- If `test_opt_minus_only_chain_emits_negative_literal` fails with `InternError` / overflow: `fits_intern_range?` is rejecting `-6`. Verify `bit_length` is magnitude-based (`(-6).bit_length == 3`). This should work without change.
- If any **v2** multiplicative test regresses (`test_opt_mult_*`): the sign-aware `build_replacement` is mis-firing for single-op groups. The invariant for the mult path is: all non-literals have combiner `:*` (= primary), so `pos == non_literals`, `neg == []`, `ordered == non_literals` in original order, and every intermediate op is `:opt_mult`. If that invariant is broken, the combiner tagging in `try_rewrite_chain` is wrong.

- [ ] **Step 7: Full-suite regression via MCP.**

Run: `mcp__ruby-bytecode__run_optimizer_tests` with no `test_filter`.

Expected: 134 + 12 new = 146 runs, 0 failures.

If a corpus test regresses: the new additive path is producing a shape that `Codec.encode` / `load_from_binary` can't round-trip. Most likely culprit: an `opt_minus` instruction constructed via `IR::Instruction.new` with operands that differ from the original `opt_minus` shape (e.g., missing inline-cache slots). Compare a before/after `IR::Instruction` record for any corpus `opt_minus` and confirm `operands` are preserved. Second-most-likely: a negative `putobject` literal at the boundary of fixnum range triggering the v2-known codec segfault (follow-up 1). If so, reduce the corpus to a smaller negative integer and file a codec-bug-specific follow-up.

- [ ] **Step 8: Commit.**

```
jj commit -m "ArithReassocPass: add opt_minus to additive group + sign-aware reorder"
```

(Files: `optimizer/lib/ruby_opt/passes/arith_reassoc_pass.rb`, `optimizer/test/passes/arith_reassoc_pass_test.rb`.)

---

### Task 3 (optional): README + benchmark

**Context:** Housekeeping — update the v2 Passes entry to name the additive-group contents and the multiplicative-group contents, and record one benchmark for the talk slide. Skip this task entirely if README drift is unwanted; the functionality is complete after Task 2.

**Files:**
- Modify: `optimizer/README.md`

- [ ] **Step 1: Read the current Passes entry for `ArithReassocPass` in `optimizer/README.md`.**

Use the Read tool on `optimizer/README.md`. Locate the `ArithReassocPass` bullet (it will mention `REASSOC_OPS`, `opt_plus`, `opt_mult`, `:would_overflow_fixnum` or `:would_exceed_intern_range`).

- [ ] **Step 2: Replace the bullet.**

Swap the existing bullet with:

```
- `RubyOpt::Passes::ArithReassocPass` — arithmetic reassociation driven by
  the `REASSOC_GROUPS` table. Two groups today: the additive group
  (`opt_plus` identity 0, `opt_minus` with sign `-`, primary `opt_plus`) and
  the multiplicative group (`opt_mult` identity 1, primary `opt_mult`).
  Collapses chains within a single basic block where ≥2 operands are
  Integer literals, partitions non-literal operands into `+`/`-` effective
  signs (leading `+` first, trailing `-` second), and emits a single
  combined-literal tail via the group's primary op. Reaches shapes
  const-fold cannot: `x + 1 + 2 + 3 → x + 6`, `x + 1 - 2 + 3 → x + 2`,
  `x * 2 * 3 * 4 → x * 24`, `x + 1 - y + 2 → x - y + 3`. Non-Integer
  literals, chains with <2 integer literals, results that would exceed the
  `ObjectTable#intern` range, and additive chains where all non-literals
  have effective sign `-` are left alone (`:mixed_literal_types`,
  `:chain_too_short`, `:would_exceed_intern_range`,
  `:no_positive_nonliteral`). An outer any-rewrite fixpoint wraps the
  per-group inner fixpoints so mult rewrites expose additive chains
  (e.g., `x + 2 * 3 - 4 → x + 2`). `**` and mixed-precedence chains with
  `opt_div` are out of scope; see follow-up plans.
```

- [ ] **Step 3: Run one benchmark to quantify the additive-group win.**

Run `mcp__ruby-bytecode__benchmark_ips` with:

```ruby
def unreassoc_add_sub(x); x + 1 - 2 + 3; end
def reassoc_add_sub(x);   x + 2; end

Benchmark.ips do |x|
  x.report("unreassoc_add_sub") { unreassoc_add_sub(100) }
  x.report("reassoc_add_sub")   { reassoc_add_sub(100) }
  x.compare!
end
```

Record the winner and ratio in the commit message body.

- [ ] **Step 4: Full-suite regression via MCP.** Sanity: 146 runs, 0 failures (no code change).

Run: `mcp__ruby-bytecode__run_optimizer_tests` with no `test_filter`.

- [ ] **Step 5: Commit.**

```
jj commit -m "Document ArithReassocPass opt_minus; record additive-group benchmark baseline"
```

(Files: `optimizer/README.md`.)

---

## Self-review

**Spec coverage** (from `2026-04-21-pass-arith-reassoc-v3-design.md`):

- `REASSOC_OPS` → `REASSOC_GROUPS` rename + entry shape — Task 1 Step 2.
- `{ops:, identity:, primary_op:}` entry shape — Task 1 Step 2 (both entries) and Task 2 Step 3 (additive gets `opt_minus`).
- `opt_minus: :-` added to the additive group — Task 2 Step 3.
- Chain detection link predicate via `group[:ops].key?` — Task 1 Step 2 (forward scan and backward walk).
- `detect_chain` returns `:op_positions` as `[{idx:, opcode:}, ...]` — Task 1 Step 2.
- Per-producer combiner tagging — Task 1 Step 2 (`producer_combiners`, `c[:combiner]`).
- Literal reduction with per-combiner send — Task 1 Step 2.
- Overflow guard (`fits_intern_range?`) — Task 1 Step 2 (unchanged from v2 semantics).
- `:no_positive_nonliteral` skip reason — Task 2 Step 5 Edit 5a.
- Non-literal partition (pos / neg by combiner-matches-primary) — Task 2 Step 5 Edit 5b.
- Emit `pos ++ neg` with adjacent-combiner-driven intermediate ops — Task 2 Step 5 Edit 5b (`opcode_for_combiner`).
- Tail literal emitted via `primary_op` even when negative — Task 2 Step 5 Edit 5b (`group[:primary_op]` in tail-op construction).
- `SINGLE_PUSH_OPERAND_OPCODES` unchanged + reordering-invariant comment — Task 1 Step 2 (doc comment on the constant).
- Two-level fixpoint unchanged — Task 1 Step 2 (`apply` retains the outer loop from v2).
- Additive baseline test `x + 1 - 2 + 3 → x + 2` — Task 2 Step 1 (`test_opt_plus_minus_collapses_leading_non_literal_chain`).
- Negative-literal emission — Task 2 Step 1 (`test_opt_minus_only_chain_emits_negative_literal`, `test_opt_plus_minus_folds_to_negative_literal`).
- Pos + neg non-literals — Task 2 Step 1 (`test_opt_plus_minus_with_pos_and_neg_non_literals`).
- All-negative-non-literal skip — Task 2 Step 1 (two tests).
- Mixed literal types — Task 2 Step 1.
- Chain-too-short — Task 2 Step 1 (`test_opt_minus_single_literal_chain_is_left_alone`).
- No-literals — Task 2 Step 1 (`test_opt_plus_minus_no_literals_chain_is_left_alone`).
- All-literal additive fold — Task 2 Step 1 (`test_opt_plus_minus_all_literal_chain_folds`).
- Cross-group interaction — Task 2 Step 1 (`test_mult_exposes_additive_chain_with_minus`).
- v2 loose-end mult-no-literal — Task 2 Step 1 (`test_opt_mult_no_literals_chain_is_left_alone`).
- README + benchmark — Task 3 (optional).

Gaps: the spec mentions "Negative-side overflow sanity" with a frank disclosure that no new boundary test is added (gated by v2 follow-up 1). The plan carries that forward — no overflow-boundary test is written. This is a deliberate spec↔plan alignment, not a gap.

**Placeholder scan:** No TBDs, no "add appropriate error handling", no "similar to Task N" (Task 3 shares structure with v2's Task 3 but all code is inline). Every MCP invocation has an explicit `test_filter` or states "no filter."

**Type consistency:**
- Chain hash key `:op_positions` (Task 1 Step 2) is referenced in Task 1 Step 2 (`chain[:op_positions].first[:idx]`) and Task 2 uses the same key indirectly (combiner tagging uses `chain[:op_positions][k-1][:opcode]`). No stale `:op_indices` references.
- `group:` kwarg is used consistently across `rewrite_once`, `detect_chain`, `try_rewrite_chain`, and `build_replacement` after all edits.
- `primary_combiner` is computed the same way in `try_rewrite_chain` (Edit 5a) and `build_replacement` (Edit 5b): `group[:ops].fetch(group[:primary_op])`.
- Log skip-reason `:no_positive_nonliteral` spelled identically in Edit 5a and in Task 2 Step 1 tests (`e.reason == :no_positive_nonliteral`).
- Pass name `:arith_reassoc` unchanged.
- `classified` element shape (hash with `:inst`, `:value`, `:is_literal`, `:combiner`) is introduced in Task 1 Step 2 and consumed unchanged in Task 2 Edit 5a (`c[:combiner]`, `c[:inst]`).

**Test-count arithmetic:**
- Baseline: 134.
- Task 1: no test changes. After Task 1: 134.
- Task 2: +12 tests. After Task 2: 146.
- Task 3: no test changes. After Task 3: 146.

Step 4 of Task 2 and Step 4 of Task 3 assert counts consistent with this arithmetic.
