# Arith Reassoc Pass v4 — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend `ArithReassocPass` to fold the multiplicative group including `opt_div`, via a new `:ordered` algorithm kind. `x / 2 / 3` collapses to `x / 6`; `x * 2 * 3 / 4 / 5` collapses to `x * 6 / 20`; `x * 2 / 3 * 4` is left alone (would require exact-divisibility reasoning). `x / 0` and `x / -3` are left alone — preserves the runtime trap and avoids floor-div sign edge cases.

**Architecture:** Each `REASSOC_GROUPS` entry gains a `kind:` field (`:abelian` or `:ordered`). `:abelian` runs v3's existing algorithm (partition by combiner, inject-reduce). `:ordered` walks the chain left-to-right with a single literal accumulator, coalescing contiguous same-op literal runs (`*·*` or `/·/`) but refusing to fold across a `*`/`/` boundary. The multiplicative entry is replaced with `{ops: {opt_mult: :*, opt_div: :/}, identity: 1, primary_op: :opt_mult, kind: :ordered}`. `try_rewrite_chain` dispatches on `group[:kind]`. Chain detection (`detect_chain`, `SINGLE_PUSH_OPERAND_OPCODES`, leader-set logic) is reused unchanged.

**Tech Stack:** Ruby 4.0.2, minitest, the `ruby-bytecode` MCP for all test runs.

**Spec:** `docs/superpowers/specs/2026-04-21-pass-arith-reassoc-v4-design.md`.

**Commit discipline:** Each task ends with `jj commit -m "<msg>"`. Executors MUST translate that to `jj split -m "<msg>" -- <files>` using the exact file list from the task's Files section when running in parallel. Use `jj commit -m` (not `jj describe -m`) to finalize. Never commit via host bash wrappers. Tests via `mcp__ruby-bytecode__run_optimizer_tests` only, never host `rake test`. Ruby evaluation via `mcp__ruby-bytecode__run_ruby`. Never host shell.

**Baseline test count after v3: 148 green.**

---

## File structure

```
optimizer/
  lib/optimize/
    passes/
      arith_reassoc_pass.rb              # MODIFIED Task 1 (kind: dispatch) + Task 2 (:ordered walker)
  test/
    passes/
      arith_reassoc_pass_test.rb         # MODIFIED Task 2 — v4 unit tests
      arith_reassoc_pass_corpus_test.rb  # UNCHANGED (new corpus fixture below is picked up automatically)
    codec/corpus/
      arith_multdiv.rb                   # NEW Task 2 — corpus fixture for * and / chains
optimizer/README.md                      # MODIFIED Task 3 (optional)
```

No new source files. No pipeline wiring changes (`Pipeline.default` already carries `ArithReassocPass`). No `Log` schema changes (`Log#skip` accepts arbitrary symbols).

---

### Task 1: Add `kind:` field to `REASSOC_GROUPS` and dispatch in `try_rewrite_chain`

**Context:** Pure structural refactor, zero behavior change. Each `REASSOC_GROUPS` entry gains a `kind:` key. Both entries are tagged `:abelian` — identical to today's behavior. `try_rewrite_chain`'s body is renamed to `try_rewrite_chain_abelian`, and a new `try_rewrite_chain` method does a `case group[:kind]` dispatch with only the `:abelian` branch populated (the `:ordered` branch raises `NotImplementedError` so Task 2's landing is a small, targeted change). The multiplicative entry remains single-op (`{opt_mult: :*}`) — `opt_div` is not added in this task.

All 148 existing tests must stay green after this task.

**Files:**
- Modify: `optimizer/lib/optimize/passes/arith_reassoc_pass.rb`

- [ ] **Step 1: Add `kind:` to both `REASSOC_GROUPS` entries**

Edit `optimizer/lib/optimize/passes/arith_reassoc_pass.rb`, replacing the `REASSOC_GROUPS` constant (currently lines 19–22) with:

```ruby
      REASSOC_GROUPS = [
        { ops: { opt_plus: :+, opt_minus: :- }, identity: 0, primary_op: :opt_plus, kind: :abelian },
        { ops: { opt_mult: :*                 }, identity: 1, primary_op: :opt_mult, kind: :abelian },
      ].freeze
```

Also update the doc comment above (lines 13–18) by inserting a new bullet documenting `kind:`:

```ruby
      # Each entry describes one commutative-associative group of operators:
      #   ops:        opcode => Symbol method used to combine that op's RHS
      #               literal into the running accumulator. Insertion-ordered.
      #   identity:   neutral element for the group (0 for +, 1 for *).
      #   primary_op: opcode used to emit the single literal-carrying trailing
      #               op after a rewrite. Must be a key in `ops`.
      #   kind:       selects the rewrite algorithm. :abelian uses v3's
      #               partition-by-combiner + inject-reduce (valid when all
      #               ops in the group commute and associate, e.g. +/-).
      #               :ordered walks the chain left-to-right with a single
      #               literal accumulator, used when the group contains a
      #               non-commutative op like opt_div.
      REASSOC_GROUPS = [
```

- [ ] **Step 2: Run the full suite and confirm 148 green**

Run via `mcp__ruby-bytecode__run_optimizer_tests` with no filter. Expected: 148 passes, 0 failures, 0 errors. No output shape change from the `kind:` addition alone — consumer code has not yet been added.

- [ ] **Step 3: Rename `try_rewrite_chain` to `try_rewrite_chain_abelian`**

In `optimizer/lib/optimize/passes/arith_reassoc_pass.rb`, rename the existing private method `try_rewrite_chain` (currently starting at line 144) to `try_rewrite_chain_abelian`. The method body is unchanged. Its one caller is inside `rewrite_once` (line 78).

- [ ] **Step 4: Add a new `try_rewrite_chain` dispatcher**

Immediately above `try_rewrite_chain_abelian` (the newly renamed method), add:

```ruby
      def try_rewrite_chain(insts, chain, function, log, object_table, group:)
        case group[:kind]
        when :abelian
          try_rewrite_chain_abelian(insts, chain, function, log, object_table, group: group)
        when :ordered
          try_rewrite_chain_ordered(insts, chain, function, log, object_table, group: group)
        else
          raise "unknown REASSOC_GROUPS kind: #{group[:kind].inspect}"
        end
      end
```

And add a stub `try_rewrite_chain_ordered` that raises, so any accidental routing to it is loud:

```ruby
      def try_rewrite_chain_ordered(_insts, _chain, _function, _log, _object_table, group:)
        raise NotImplementedError, ":ordered kind not yet implemented (group: #{group.inspect})"
      end
```

Place both methods inside the `private` section, with `try_rewrite_chain` first, then `try_rewrite_chain_ordered`, then the existing `try_rewrite_chain_abelian`.

- [ ] **Step 5: Run the full suite and confirm 148 green**

Run via `mcp__ruby-bytecode__run_optimizer_tests`. Expected: 148 passes. Both existing groups are `:abelian`, so `try_rewrite_chain_ordered` is never called and the stub's `NotImplementedError` never fires.

- [ ] **Step 6: Commit**

```
jj commit -m "ArithReassocPass: add kind: field + dispatch (no behavior change)"
```

(If running in parallel with other subagents, substitute `jj split -m "ArithReassocPass: add kind: field + dispatch (no behavior change)" -- optimizer/lib/optimize/passes/arith_reassoc_pass.rb`.)

---

### Task 2: Flip multiplicative entry to `:ordered` + implement `:ordered` walker + tests

**Context:** The real work. Append `opt_div: :/` to the multiplicative entry's `ops` map and flip `kind:` to `:ordered`. Implement `try_rewrite_chain_ordered` per the spec's algorithm: pre-scan for `:unsafe_divisor` / `:mixed_literal_types` / `:chain_too_short`; build an op-tagged stream; walk with a single literal accumulator coalescing same-op runs and committing at `*`/`/` boundaries and non-literal operands; per-commit `fits_intern_range?` check; `:no_change` bail; emission as interleaved `push; op; push; op; …`.

Test-driven: write one unit test, run it (fails), implement just enough to pass, repeat. Commit at natural checkpoints inside this task (the plan marks three — baseline fold, boundary bail, guards — after which the remaining tests should pass without further implementation changes).

**Files:**
- Modify: `optimizer/lib/optimize/passes/arith_reassoc_pass.rb`
- Modify: `optimizer/test/passes/arith_reassoc_pass_test.rb`
- Create: `optimizer/test/codec/corpus/arith_multdiv.rb`

#### Part 2a — Baseline `/`-only fold

- [ ] **Step 1: Write the failing test for `x / 2 / 3 → x / 6`**

Append to `optimizer/test/passes/arith_reassoc_pass_test.rb`, inside the `ArithReassocPassTest` class, before the closing `end` and before the `private`/`find_iseq` section:

```ruby
  # --- v4: multiplicative :ordered group ---

  def test_mult_div_same_op_div_chain_folds
    src = "def f(x); x / 2 / 3; end; f(60)"
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    Optimize::Passes::ArithReassocPass.new.apply(f, type_env: nil, log: Optimize::Log.new, object_table: ot)

    assert_equal 1, f.instructions.count { |i| i.opcode == :opt_div }
    assert_equal 0, f.instructions.count { |i| i.opcode == :opt_mult }
    refute_nil f.instructions.find { |i| Optimize::Passes::LiteralValue.read(i, object_table: ot) == 6 }

    loaded = RubyVM::InstructionSequence.load_from_binary(Optimize::Codec.encode(ir))
    assert_equal 10, loaded.eval
  end
```

- [ ] **Step 2: Run the test and confirm it fails**

Run via `mcp__ruby-bytecode__run_optimizer_tests` with filter `test_mult_div_same_op_div_chain_folds`. Expected: `NotImplementedError: :ordered kind not yet implemented` — because once we flip the multiplicative entry to `:ordered` (next step) the stub will fire. (If run before flipping, the test will fail with "expected 1 opt_div, got 2" or similar — both are valid "not yet implemented" signals.)

- [ ] **Step 3: Flip the multiplicative entry to `:ordered` with `opt_div` in its ops**

Edit `optimizer/lib/optimize/passes/arith_reassoc_pass.rb`. Replace the multiplicative `REASSOC_GROUPS` entry (the second entry added in Task 1) with:

```ruby
        { ops: { opt_mult: :*, opt_div: :/ }, identity: 1, primary_op: :opt_mult, kind: :ordered },
```

At this point running the full suite will route multiplicative chains into `try_rewrite_chain_ordered`, which raises. Several pre-existing v2 tests (e.g. `x * 2 * 3 → x * 6`) will go red. That's expected — they'll go green once the walker is implemented below.

- [ ] **Step 4: Implement `try_rewrite_chain_ordered`**

Replace the stub `try_rewrite_chain_ordered` in `optimizer/lib/optimize/passes/arith_reassoc_pass.rb` with the full implementation:

```ruby
      def try_rewrite_chain_ordered(insts, chain, function, log, object_table, group:)
        producer_insts = chain[:producer_indices].map { |k| insts[k] }

        # Build the op-tagged stream. The leading producer has no preceding op
        # in source, so we tag it with the group's primary op.
        stream = producer_insts.each_with_index.map do |p, k|
          op =
            if k == 0
              group[:primary_op]
            else
              chain[:op_positions][k - 1][:opcode]
            end
          v = LiteralValue.read(p, object_table: object_table)
          { op: op, value: v, is_literal: LiteralValue.literal?(p), inst: p }
        end

        chain_line = insts[chain[:op_positions].first[:idx]].line || function.first_lineno

        # Pre-scan 1: unsafe divisor (0, negative, or non-Integer literal on a /).
        if stream.any? { |e| e[:op] == :opt_div && e[:is_literal] && !(e[:value].is_a?(Integer) && e[:value] > 0) }
          log.skip(pass: :arith_reassoc, reason: :unsafe_divisor,
                   file: function.path, line: chain_line)
          return false
        end

        # Pre-scan 2: non-Integer literal anywhere else (e.g. Float/String on a *).
        if stream.any? { |e| e[:is_literal] && !e[:value].is_a?(Integer) }
          log.skip(pass: :arith_reassoc, reason: :mixed_literal_types,
                   file: function.path, line: chain_line)
          return false
        end

        # Pre-scan 3: coarse chain-too-short filter.
        if stream.count { |e| e[:is_literal] && e[:value].is_a?(Integer) } < 2
          log.skip(pass: :arith_reassoc, reason: :chain_too_short,
                   file: function.path, line: chain_line)
          return false
        end

        # Walk. Maintain an `emitted` list of entries and a pending literal
        # accumulator (acc: Integer or nil). Committed-literal entries carry
        # `inst: nil`; non-literal passthrough entries carry their source inst.
        # That single shape difference (`inst.nil?`) is what downstream checks
        # read — no separate `committed:` flag is needed.
        emitted = []
        acc = nil
        acc_op = nil

        commit = lambda do
          next if acc.nil?
          emitted << { op: acc_op, value: acc, inst: nil }
          acc = nil
          acc_op = nil
        end

        stream.each do |e|
          if e[:is_literal]
            if acc.nil?
              acc = e[:value]
              acc_op = e[:op]
            elsif acc_op == e[:op]
              # Same-op literal run: multiply into the accumulator.
              # For *-run this is true product; for /-run divisors coalesce via *.
              acc = acc * e[:value]
            else
              # *<->/ boundary between literals: commit and start fresh.
              commit.call
              acc = e[:value]
              acc_op = e[:op]
            end
          else
            # Non-literal. If the op matches the current accumulator's op,
            # we can keep accumulating after this non-literal (within the same
            # op-run — literals commute past the non-literal by *-abelian or
            # positive-/-right-associative algebra). If the op differs, we've
            # crossed a *<->/ boundary — commit the pending accumulator first.
            if !acc.nil? && acc_op != e[:op]
              commit.call
            end
            emitted << e
          end
        end
        commit.call

        # Fits-intern check on every committed literal (inst: nil entries).
        if emitted.any? { |e| e[:inst].nil? && !fits_intern_range?(e[:value]) }
          log.skip(pass: :arith_reassoc, reason: :would_exceed_intern_range,
                   file: function.path, line: chain_line)
          return false
        end

        # No-change check: if we emitted the same number of literals as we
        # started with, nothing folded — preserve idempotence.
        input_literal_count  = stream.count  { |e| e[:is_literal] }
        output_literal_count = emitted.count { |e| e[:inst].nil? }
        if input_literal_count == output_literal_count
          log.skip(pass: :arith_reassoc, reason: :no_change,
                   file: function.path, line: chain_line)
          return false
        end

        first_op_inst = insts[chain[:op_positions].first[:idx]]

        # Emit. The leading entry's op is implicit (just the push). Every
        # subsequent entry emits `push; op`. Committed literals have inst: nil
        # and are reconstructed via LiteralValue.emit; non-literals carry the
        # original inst.
        replacement = []
        emitted.each_with_index do |e, idx|
          push_inst =
            if e[:inst].nil?
              LiteralValue.emit(e[:value], line: first_op_inst.line, object_table: object_table)
            else
              e[:inst]
            end
          replacement << push_inst

          next if idx == 0
          replacement << IR::Instruction.new(
            opcode: e[:op],
            operands: first_op_inst.operands,
            line: first_op_inst.line,
          )
        end

        range = chain[:first_idx]..chain[:end_idx]
        function.splice_instructions!(range, replacement)
        log.skip(pass: :arith_reassoc, reason: :reassociated,
                 file: function.path, line: chain_line)
        true
      end
```

- [ ] **Step 5: Run the full suite**

Run via `mcp__ruby-bytecode__run_optimizer_tests` (no filter). Expected:
- `test_mult_div_same_op_div_chain_folds` passes.
- All pre-existing v2 multiplicative tests pass (pure `*`-chains fold as before — the `:ordered` walker handles the degenerate no-`/` case identically to v2, by coalescing all literals into a single committed value).
- All v3 additive tests pass (additive is still `:abelian`).
- Test count: 149 green (148 baseline + 1 new).

If anything is red, the walker has a bug. Fix before proceeding.

- [ ] **Step 6: Commit baseline fold**

```
jj commit -m "ArithReassocPass: :ordered walker + opt_div fold"
```

#### Part 2b — Mixed runs and the `*`/`/` boundary

- [ ] **Step 7: Write the mixed `*`/`/` run test**

Append to `arith_reassoc_pass_test.rb`:

```ruby
  def test_mult_div_trailing_divisor_run_folds
    src = "def f(x); x * 2 * 3 / 4 / 5; end; f(100)"
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    Optimize::Passes::ArithReassocPass.new.apply(f, type_env: nil, log: Optimize::Log.new, object_table: ot)

    assert_equal 1, f.instructions.count { |i| i.opcode == :opt_mult }
    assert_equal 1, f.instructions.count { |i| i.opcode == :opt_div }
    refute_nil f.instructions.find { |i| Optimize::Passes::LiteralValue.read(i, object_table: ot) == 6 }
    refute_nil f.instructions.find { |i| Optimize::Passes::LiteralValue.read(i, object_table: ot) == 20 }

    loaded = RubyVM::InstructionSequence.load_from_binary(Optimize::Codec.encode(ir))
    assert_equal 30, loaded.eval
  end
```

- [ ] **Step 8: Run and confirm pass**

Run via `mcp__ruby-bytecode__run_optimizer_tests` with filter `test_mult_div_trailing_divisor_run_folds`. Expected: PASS. The walker already handles this case — two same-op runs (`* 2 * 3` and `/ 4 / 5`) with a boundary between them.

- [ ] **Step 9: Write the boundary-bail test**

Append:

```ruby
  def test_mult_div_crossing_boundary_bails_no_change
    src = "def f(x); x * 2 / 3 * 4; end; f(6)"
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    before = f.instructions.map(&:opcode)
    log = Optimize::Log.new
    Optimize::Passes::ArithReassocPass.new.apply(f, type_env: nil, log: log, object_table: ot)

    assert_equal before, f.instructions.map(&:opcode)
    assert(log.entries.any? { |e| e[:reason] == :no_change },
      "expected :no_change log entry, got reasons: #{log.entries.map { |e| e[:reason] }.inspect}")

    loaded = RubyVM::InstructionSequence.load_from_binary(Optimize::Codec.encode(ir))
    assert_equal 16, loaded.eval
  end
```

Note: this test reads `log.entries`. If `Optimize::Log` does not expose an `entries` accessor, substitute the existing accessor used elsewhere in the file (search the test file for `log.entries` or similar patterns used by v3 tests). If none exists, the test can instead assert the shape stayed identical via `assert_equal before, f.instructions.map(&:opcode)` alone and skip the log-reason assertion. Prefer the log assertion when possible.

- [ ] **Step 10: Run and confirm pass**

Run via `mcp__ruby-bytecode__run_optimizer_tests` with filter `test_mult_div_crossing_boundary_bails_no_change`. Expected: PASS. The walker emits the stream unchanged (literal count in == literal count out) and bails with `:no_change`.

- [ ] **Step 11: Write the three-run boundary test**

Append:

```ruby
  def test_mult_div_literal_run_with_mixed_ops_folds
    # 2 * 3 / 6 * x: two runs of length 2, one singleton. The *->/ boundary
    # does not allow 6/6 to further reduce within this pass (const-fold will
    # mop that up in the default pipeline, exercised by a separate test).
    src = "def f(x); 2 * 3 / 6 * x; end; f(5)"
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    Optimize::Passes::ArithReassocPass.new.apply(f, type_env: nil, log: Optimize::Log.new, object_table: ot)

    # After arith_reassoc alone: 6 / 6 * x. Two committed literals (both 6).
    sixes = f.instructions.count { |i| Optimize::Passes::LiteralValue.read(i, object_table: ot) == 6 }
    assert_equal 2, sixes
    assert_equal 1, f.instructions.count { |i| i.opcode == :opt_mult }
    assert_equal 1, f.instructions.count { |i| i.opcode == :opt_div }

    loaded = RubyVM::InstructionSequence.load_from_binary(Optimize::Codec.encode(ir))
    assert_equal 5, loaded.eval
  end
```

- [ ] **Step 12: Run and confirm pass**

Run via `mcp__ruby-bytecode__run_optimizer_tests` with filter `test_mult_div_literal_run_with_mixed_ops_folds`. Expected: PASS.

- [ ] **Step 13: Commit the boundary cases**

```
jj commit -m "ArithReassocPass: tests for :ordered mixed-op and boundary bail"
```

#### Part 2c — Guards (/0, negative divisor, overflow, mixed types, idempotence)

- [ ] **Step 14: Write the zero-divisor bail test**

Append:

```ruby
  def test_mult_div_zero_divisor_bails
    # / 0 must not be folded away. Chain left alone; CRuby's opt_div still
    # traps at runtime at the original site (unchanged by the pass).
    src = "def f(x); x / 2 / 0; end"
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    before = f.instructions.map(&:opcode)
    log = Optimize::Log.new
    Optimize::Passes::ArithReassocPass.new.apply(f, type_env: nil, log: log, object_table: ot)

    assert_equal before, f.instructions.map(&:opcode)
    assert(log.entries.any? { |e| e[:reason] == :unsafe_divisor },
      "expected :unsafe_divisor log entry, got: #{log.entries.map { |e| e[:reason] }.inspect}")

    # Confirm the two opt_div instructions are still present (trap preserved).
    assert_equal 2, f.instructions.count { |i| i.opcode == :opt_div }
  end
```

- [ ] **Step 15: Run and confirm pass**

Run with filter `test_mult_div_zero_divisor_bails`. Expected: PASS.

- [ ] **Step 16: Write the negative-divisor bail test**

Append:

```ruby
  def test_mult_div_negative_divisor_bails
    src = "def f(x); x / -3 / -2; end; f(12)"
    ir_unopt = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ir_opt   = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot_opt   = ir_opt.misc[:object_table]
    f_opt    = find_iseq(ir_opt, "f")
    before = f_opt.instructions.map(&:opcode)
    log = Optimize::Log.new
    Optimize::Passes::ArithReassocPass.new.apply(f_opt, type_env: nil, log: log, object_table: ot_opt)

    assert_equal before, f_opt.instructions.map(&:opcode)
    assert(log.entries.any? { |e| e[:reason] == :unsafe_divisor })

    # Runtime equivalence.
    loaded_unopt = RubyVM::InstructionSequence.load_from_binary(Optimize::Codec.encode(ir_unopt))
    loaded_opt   = RubyVM::InstructionSequence.load_from_binary(Optimize::Codec.encode(ir_opt))
    assert_equal loaded_unopt.eval, loaded_opt.eval
  end
```

- [ ] **Step 17: Write the non-Integer-divisor test**

Append:

```ruby
  def test_mult_div_non_integer_divisor_bails
    # String divisor is caught by the unsafe_divisor pre-scan (it fires
    # before the generic mixed_literal_types scan).
    src = 'def f(x); x / 2 / "foo"; end'
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    before = f.instructions.map(&:opcode)
    log = Optimize::Log.new
    Optimize::Passes::ArithReassocPass.new.apply(f, type_env: nil, log: log, object_table: ot)

    assert_equal before, f.instructions.map(&:opcode)
    assert(log.entries.any? { |e| e[:reason] == :unsafe_divisor })
  end
```

- [ ] **Step 18: Write the mixed-literal-types test**

Append:

```ruby
  def test_mult_div_mixed_literal_types_bails
    # Float multiplier (not a divisor) → :mixed_literal_types.
    src = "def f(x); x * 2 * 1.5; end"
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    before = f.instructions.map(&:opcode)
    log = Optimize::Log.new
    Optimize::Passes::ArithReassocPass.new.apply(f, type_env: nil, log: log, object_table: ot)

    assert_equal before, f.instructions.map(&:opcode)
    assert(log.entries.any? { |e| e[:reason] == :mixed_literal_types })
  end
```

- [ ] **Step 19: Write the overflow-guard test**

Append:

```ruby
  def test_mult_div_would_exceed_intern_range_bails
    # (1 << 31) * (1 << 31) = 2^62, bit_length is 63, fails < 62.
    src = "def f(x); x * (1 << 31) * (1 << 31); end"
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    before = f.instructions.map(&:opcode)
    log = Optimize::Log.new
    Optimize::Passes::ArithReassocPass.new.apply(f, type_env: nil, log: log, object_table: ot)

    assert_equal before, f.instructions.map(&:opcode)
    assert(log.entries.any? { |e| e[:reason] == :would_exceed_intern_range })
  end
```

- [ ] **Step 20: Write the non-literal preservation test**

Append:

```ruby
  def test_mult_div_non_literals_preserved_in_position
    # :ordered does not reorder non-literals. 2*3 coalesces at the tail.
    src = "def f(x, y); x * y * 2 * 3; end; f(5, 4)"
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    Optimize::Passes::ArithReassocPass.new.apply(f, type_env: nil, log: Optimize::Log.new, object_table: ot)

    assert_equal 2, f.instructions.count { |i| i.opcode == :opt_mult }
    assert_equal 0, f.instructions.count { |i| i.opcode == :opt_div }
    refute_nil f.instructions.find { |i| Optimize::Passes::LiteralValue.read(i, object_table: ot) == 6 }

    loaded = RubyVM::InstructionSequence.load_from_binary(Optimize::Codec.encode(ir))
    assert_equal 120, loaded.eval
  end
```

- [ ] **Step 21: Write the idempotence test**

Append:

```ruby
  def test_mult_div_idempotent
    src = "def f(x); x * 2 * 3 / 4 / 5; end; f(100)"
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")

    pass = Optimize::Passes::ArithReassocPass.new
    pass.apply(f, type_env: nil, log: Optimize::Log.new, object_table: ot)
    after_first = f.instructions.map(&:opcode)
    pass.apply(f, type_env: nil, log: Optimize::Log.new, object_table: ot)
    after_second = f.instructions.map(&:opcode)

    assert_equal after_first, after_second, "pass must be idempotent on a folded chain"
  end
```

- [ ] **Step 22: Write the cross-group interaction test**

Append:

```ruby
  def test_mult_div_cross_group_with_additive_via_pipeline
    # Runtime-equivalence check: the default pipeline (arith_reassoc then
    # const_fold) applied to `x + 6 / 2 + 1` must produce a loaded iseq
    # whose .eval matches unoptimized semantics. We don't assert an exact
    # post-pipeline instruction shape here — that depends on how arith's
    # outer fixpoint interacts with const-fold's one-pass run. We only
    # assert soundness: same answer as CRuby.
    src = "def f(x); x + 6 / 2 + 1; end; f(10)"
    ir_unopt = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ir_opt   = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    Optimize::Pipeline.default.run(ir_opt, type_env: nil)

    loaded_unopt = RubyVM::InstructionSequence.load_from_binary(Optimize::Codec.encode(ir_unopt))
    loaded_opt   = RubyVM::InstructionSequence.load_from_binary(Optimize::Codec.encode(ir_opt))
    assert_equal loaded_unopt.eval, loaded_opt.eval
    assert_equal 14, loaded_opt.eval  # 10 + (6/2) + 1 = 14
  end
```

- [ ] **Step 23: Run the full suite**

Run via `mcp__ruby-bytecode__run_optimizer_tests` with no filter. Expected: 148 baseline + 11 new = 159 green.

If any test in Steps 14–22 fails, the walker or the pre-scan has a bug specific to that case. Fix in `try_rewrite_chain_ordered` until all pass.

- [ ] **Step 24: Commit guards and idempotence**

```
jj commit -m "ArithReassocPass: :ordered kind guards (/0, negative, overflow, types) + idempotence"
```

#### Part 2d — Corpus fixture

- [ ] **Step 25: Create the corpus fixture**

Create `optimizer/test/codec/corpus/arith_multdiv.rb`:

```ruby
def same_op_mult(x)
  x * 2 * 3
end

def same_op_div(x)
  x / 2 / 3
end

def mixed_trailing_div(x)
  x * 2 * 3 / 4 / 5
end

def boundary_no_fold(x)
  x * 2 / 3 * 4
end

def literal_prefix(x)
  2 * 3 / 6 * x
end

def with_two_non_literals(x, y)
  x * y * 2 * 3
end

def divisor_zero_runtime_trap(x)
  x / 2 / 0
end

def divisor_negative(x)
  x / -3 / -2
end

# Exercise every method across positive, zero, and negative inputs where
# safe, and make the corpus runner's load-from-binary check non-trivial.
[1, 42, -7].each do |v|
  same_op_mult(v)
  same_op_div(60)
  mixed_trailing_div(100)
  boundary_no_fold(v)
  literal_prefix(v)
  with_two_non_literals(v, v + 1)
  divisor_negative(12)
end
```

This fixture exercises every `:ordered` code path (fold, boundary bail, guard). The existing `arith_reassoc_pass_corpus_test.rb` iterates `test/codec/corpus/*.rb` and runs each through `Pipeline.default` followed by `Codec.encode` + `load_from_binary` — it will pick up this new file automatically, verifying (a) the optimized iseq survives round-trip and (b) `load_from_binary` doesn't reject the output.

Note: `divisor_zero_runtime_trap` is *defined* in the corpus file but not called, because calling it would raise `ZeroDivisionError` at load time. The corpus runner only checks that the iseq compiles, loads, and re-loads — it does not execute top-level code that would trap. This verifies the `/0` chain survives the full pipeline without being folded away.

- [ ] **Step 26: Run the corpus test**

Run via `mcp__ruby-bytecode__run_optimizer_tests` with filter `ArithReassocPassCorpusTest`. Expected: PASS for `test_every_corpus_fixture_survives_default_pipeline_with_arith` (the new fixture round-trips cleanly) and all other corpus tests.

- [ ] **Step 27: Run the full suite**

Run via `mcp__ruby-bytecode__run_optimizer_tests` with no filter. Expected: 159 green.

- [ ] **Step 28: Commit the corpus fixture**

```
jj commit -m "ArithReassocPass: corpus fixture for opt_mult + opt_div"
```

---

### Task 3 (optional): README + benchmark

**Context:** Cosmetic. Update the `optimizer/README.md` passes entry to mention `opt_div` and the `:ordered` kind, and record one `benchmark_ips` run as the v4 baseline for the talk slide. Skip this task if pressed for time — it does not affect correctness.

**Files:**
- Modify: `optimizer/README.md`
- (No source or test changes.)

- [ ] **Step 1: Update `optimizer/README.md`**

Edit the `ArithReassocPass` bullet (currently lines 29–46 of `optimizer/README.md`) to add a new sentence before `` `**` and mixed-precedence chains with `opt_div` are out of scope `` and remove the "out of scope" reference to `opt_div`. Replace the bullet with:

```
- `Optimize::Passes::ArithReassocPass` — arithmetic reassociation driven by
  the `REASSOC_GROUPS` table. Two groups today: the additive group
  (`opt_plus` identity 0, `opt_minus` with sign `-`, primary `opt_plus`,
  kind `:abelian`) and the multiplicative group (`opt_mult` identity 1,
  `opt_div` secondary, primary `opt_mult`, kind `:ordered`). The
  `:abelian` algorithm partitions non-literal operands by effective sign
  and injects literals through a single combiner. The `:ordered`
  algorithm walks the chain left-to-right with a single literal
  accumulator, coalescing contiguous same-op literal runs (`* L1 * L2`
  or `/ L1 / L2`) but refusing to fold across a `*`/`/` boundary —
  required because Ruby integer `/` is floor-division, so
  `(a * L1) / L2 ≠ a * (L1 / L2)` in general. Reaches shapes
  const-fold cannot: `x + 1 + 2 + 3` → `x + 6`, `x + 1 - 2 + 3` → `x + 2`,
  `x * 2 * 3 * 4` → `x * 24`, `x + 1 - y + 2` → `x - y + 3`,
  `x / 2 / 3` → `x / 6`, `x * 2 * 3 / 4 / 5` → `x * 6 / 20`. Non-Integer
  literals, chains with <2 integer literals, results that would exceed
  the `ObjectTable#intern` range, additive chains where all non-literals
  have effective sign `-`, multiplicative chains with any `≤0` literal
  divisor, and multiplicative chains whose walk produces no fold are
  left alone (`:mixed_literal_types`, `:chain_too_short`,
  `:would_exceed_intern_range`, `:no_positive_nonliteral`,
  `:unsafe_divisor`, `:no_change`). An outer any-rewrite fixpoint wraps
  the per-group inner fixpoints so mult rewrites expose additive chains
  (e.g., `x + 2 * 3 - 4` → `x + 2`). `**` and exact-divisibility folds
  (e.g. `x * 6 / 2 → x * 3`) are out of scope; see follow-up plans.
```

- [ ] **Step 2: Run one benchmark for the talk baseline**

Invoke `mcp__ruby-bytecode__benchmark_ips` with two scripts comparing the unoptimized and optimized shapes. Use:

- Unoptimized: `def f(x); x * 2 * 3 / 4 / 5; end`
- Optimized:   `def f(x); x * 6 / 20; end`

Both with a warmup loop calling `f(100)` one million times. Record the ips ratio in the plan's "Success criteria" section of the v4 spec, or in a `docs/superpowers/benchmarks/` note if that directory exists; otherwise save the two ips numbers and their ratio in the commit message. The benchmark is a single data point for the talk slide — absolute numbers are less important than the direction (optimized should be faster or within noise of unoptimized, since the optimized form has strictly fewer ops).

- [ ] **Step 3: Commit**

```
jj commit -m "Document ArithReassocPass opt_div + :ordered kind; record v4 baseline"
```

---

## Success criteria

1. After Task 1: 148 existing tests green. The `kind:` field is the only structural difference in the pass file. `try_rewrite_chain` dispatches on `kind:`; both existing entries are `:abelian`; the `:ordered` branch is a stub that raises.
2. After Task 2: 159 tests green (148 baseline + 11 new v4 unit + corpus fixture picked up by existing corpus test with no new test method). `run_ruby` / `.eval` on optimized iseqs matches unoptimized across all new fixtures.
3. After Task 3: `optimizer/README.md` mentions `:ordered`, `opt_div`, and the new skip reasons. One benchmark_ips data point recorded.
4. `REASSOC_GROUPS` remains the design. Reading the constant, one can predict: (a) which ops reassociate together, (b) which algorithm applies to each group via `kind:`, (c) that `**` is deliberately absent and that `opt_div` joins only under `:ordered`.
5. The v2 follow-up 1 (bignum-codec segfault at bit_length ≳ 30) remains open. v4 does not depend on it and does not make it worse. If any new corpus case happens to hit it, bail in the spec's `:would_exceed_intern_range` path rather than widen the guard.

---

## Notes for executors

- **`jj commit` vs `jj describe`:** always finalize with `jj commit -m "..."`. Never `jj describe -m`.
- **Parallel commits:** if dispatched as a subagent working in parallel with siblings, use `jj split -m "<msg>" -- <files>` with the exact file list from the task's `Files:` block. Never `jj commit` in parallel mode.
- **Test runs:** always via `mcp__ruby-bytecode__run_optimizer_tests`. Never host `rake test`, `bundle exec rake`, or shell-out.
- **Ruby evaluation for ad-hoc checks:** via `mcp__ruby-bytecode__run_ruby`. Never host `ruby -e`.
- **Log accessor:** the tests above use `log.entries`. If `Optimize::Log` exposes a different API for inspection (e.g. `log.skips` or `log.events`), substitute it consistently across all new tests. Check `optimizer/lib/optimize/log.rb` before starting Task 2.
- **Instruction layout:** v3 changed the emission shape from "all pushes first, all ops last" to interleaved "push, op, push, op, …". The `:ordered` walker follows the v3 interleaved shape. If any pre-existing v2 test asserted on the old shape and was updated in v3, that update still stands — do not revert.
- **`putobject` with negative or large integers:** `LiteralValue.emit` handles interning and special-const boundaries. The `fits_intern_range?(bit_length < 62)` guard gates every committed literal; do not widen without verifying the bignum-codec follow-up first.
