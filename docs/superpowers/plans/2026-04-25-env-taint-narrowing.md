# ConstFoldEnvPass taint-classifier narrowing — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Narrow `ConstFoldEnvPass`'s taint classifier so read-only sends on `ENV` (`fetch`, `to_h`, `key?`, …) no longer taint the whole IR tree. Bare `ENV[LIT]` folds in files that also call `ENV.fetch` elsewhere.

**Architecture:** One surgical change in `ConstFoldEnvPass#classify` plus a new `SAFE_ENV_READ_METHODS` frozen `Set`. Test file gets one test flipped (`ENV.fetch` no longer taints) and several new tests for adjacent safe-method cases and still-tainted write cases.

**Design doc:** `docs/superpowers/specs/2026-04-25-env-taint-narrowing-design.md`.

**Tech Stack:** Ruby (4.0.2), Minitest. All Ruby/test execution via the `ruby-bytecode` MCP server — never host shell. VCS via `jj` (`jj commit -m`, never `jj describe`).

---

## File map

- Modify: `optimizer/lib/optimize/passes/const_fold_env_pass.rb`
  - Require `set` (for `Set`).
  - Require `optimize/ir/call_data`.
  - Add `SAFE_ENV_READ_METHODS` constant.
  - Rewrite `classify` to dispatch to a `consumer_safe?` helper.
  - Add `consumer_safe?(insts, i, object_table)` returning `[safe?, consumer_line]`.
- Modify: `optimizer/test/passes/const_fold_env_pass_test.rb`
  - Flip `test_env_fetch_taints_tree` → `test_env_fetch_does_not_taint_tree`.
  - Add tests per design doc's test plan table.
- Modify: `docs/TODO.md`
  - Strike the ConstFoldEnvPass narrowing bullet from "Refinements".
  - Update the Tier 4 shipped cell in the status table.

---

## Task 1: Red — ENV.fetch should not taint the tree

**Files:**
- Modify: `optimizer/test/passes/const_fold_env_pass_test.rb`

- [ ] **Step 1: Flip the existing `test_env_fetch_taints_tree` test.**

  Replace the test body so it asserts the *opposite*: `r` folds and no `:env_write_observed` entry is emitted. Rename the method to `test_env_fetch_does_not_taint_tree`.

  ```ruby
  def test_env_fetch_does_not_taint_tree
    src = 'def r; ENV["A"]; end; def g; ENV.fetch("B"); end'
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    snap = { "A" => "1", "B" => "2" }.freeze
    log = Optimize::Log.new
    r = find_iseq(ir, "r")

    pass = Optimize::Passes::ConstFoldEnvPass.new
    each_function(ir) do |fn|
      pass.apply(fn, type_env: nil, log: log, object_table: ot, env_snapshot: snap)
    end

    opcodes = r.instructions.map(&:opcode)
    refute_includes opcodes, :opt_aref, "r should fold — ENV.fetch sibling must not taint"
    refute(log.for_pass(:const_fold_env).any? { |e| e.reason == :env_write_observed },
           "read-only ENV.fetch should not taint the tree")
  end
  ```

- [ ] **Step 2: Run the full suite; expect this one test RED.**

  Use `mcp__ruby-bytecode__run_optimizer_tests` with the filter narrowed to the env-pass test file. Confirm only the flipped test fails, with a message indicating `opt_aref` is still present (classifier still taints on fetch).

- [ ] **Step 3: Commit the red test.**

  ```
  jj commit -m "test: red — ENV.fetch sibling should not taint Tier 4 fold tree"
  ```

---

## Task 2: Green — narrow the classifier

**Files:**
- Modify: `optimizer/lib/optimize/passes/const_fold_env_pass.rb`

- [ ] **Step 1: Add requires and the safe-method constant.**

  At the top of the file (after existing requires), add:

  ```ruby
  require "set"
  require "optimize/ir/call_data"
  ```

  Inside `class ConstFoldEnvPass < Optimize::Pass`, near the other constant (`TAINT_FLAG_KEY`), add:

  ```ruby
  # Read-only ENV methods that cannot mutate ENV. A send on ENV with one
  # of these mids does NOT taint the tree. v1: argc 0 and 1 only.
  # Expanding this set is safe iff the method is guaranteed non-mutating.
  SAFE_ENV_READ_METHODS = %i[
    fetch to_h to_hash key? has_key? include? member?
    values_at assoc size length empty? keys values
    inspect to_s hash ==
  ].to_set.freeze
  ```

- [ ] **Step 2: Rewrite `classify` to consult `consumer_safe?`.**

  Replace the existing `classify` method with:

  ```ruby
  # Walk `insts`. For every ENV producer, ask consumer_safe? whether the
  # consumer pattern at that producer site is an allowed read-only shape.
  # Returns [tainted?, first_taint_line].
  def classify(insts, object_table)
    i = 0
    while i < insts.size
      inst = insts[i]
      if env_producer?(inst, object_table)
        safe, line = consumer_safe?(insts, i, object_table)
        unless safe
          return [true, line || inst.line]
        end
      end
      i += 1
    end
    [false, nil]
  end
  ```

- [ ] **Step 3: Add `consumer_safe?` helper.**

  Below `classify` (above `env_producer?`):

  ```ruby
  # For an ENV producer at `insts[i]`, return [safe?, consumer_line].
  # Safe if the consumer is:
  #   - opt_aref at i+2 (bare ENV[KEY]; consumes ENV+key), OR
  #   - opt_send_without_block at i+1 with argc=0 and a safe read-only mid, OR
  #   - opt_send_without_block at i+2 with argc=1 and a safe read-only mid.
  # All other consumer shapes taint.
  def consumer_safe?(insts, i, object_table)
    at_i_plus_1 = insts[i + 1]
    at_i_plus_2 = insts[i + 2]

    if at_i_plus_2 && at_i_plus_2.opcode == :opt_aref
      return [true, at_i_plus_2.line]
    end

    if at_i_plus_1 && at_i_plus_1.opcode == :opt_send_without_block &&
       safe_zero_arg_send?(at_i_plus_1, object_table)
      return [true, at_i_plus_1.line]
    end

    if at_i_plus_2 && at_i_plus_2.opcode == :opt_send_without_block &&
       safe_one_arg_send?(at_i_plus_2, object_table)
      return [true, at_i_plus_2.line]
    end

    [false, (at_i_plus_2 && at_i_plus_2.line) || (at_i_plus_1 && at_i_plus_1.line)]
  end

  def safe_zero_arg_send?(inst, object_table)
    cd = inst.operands[0]
    return false unless cd.is_a?(IR::CallData)
    return false unless cd.argc == 0
    return false if cd.has_kwargs? || cd.has_splat? || cd.blockarg?
    SAFE_ENV_READ_METHODS.include?(cd.mid_symbol(object_table))
  end

  def safe_one_arg_send?(inst, object_table)
    cd = inst.operands[0]
    return false unless cd.is_a?(IR::CallData)
    return false unless cd.argc == 1
    return false if cd.has_kwargs? || cd.has_splat? || cd.blockarg?
    SAFE_ENV_READ_METHODS.include?(cd.mid_symbol(object_table))
  end
  ```

- [ ] **Step 4: Re-run the ConstFoldEnvPass test suite.**

  Via `mcp__ruby-bytecode__run_optimizer_tests`. Expect the flipped test to pass. All previously-passing tests stay green.

- [ ] **Step 5: Commit.**

  ```
  jj commit -m "const_fold_env: narrow taint classifier — whitelist read-only ENV sends"
  ```

---

## Task 3: Expand test coverage for the new safe shapes

**Files:**
- Modify: `optimizer/test/passes/const_fold_env_pass_test.rb`

- [ ] **Step 1: Add `test_env_to_h_does_not_taint_tree`.**

  ```ruby
  def test_env_to_h_does_not_taint_tree
    src = 'def r; ENV["A"]; end; def g; ENV.to_h; end'
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    snap = { "A" => "1" }.freeze
    log = Optimize::Log.new
    r = find_iseq(ir, "r")

    pass = Optimize::Passes::ConstFoldEnvPass.new
    each_function(ir) do |fn|
      pass.apply(fn, type_env: nil, log: log, object_table: ot, env_snapshot: snap)
    end

    refute_includes r.instructions.map(&:opcode), :opt_aref
    refute(log.for_pass(:const_fold_env).any? { |e| e.reason == :env_write_observed })
  end
  ```

- [ ] **Step 2: Add `test_env_key_question_does_not_taint_tree`.**

  ```ruby
  def test_env_key_question_does_not_taint_tree
    src = 'def r; ENV["A"]; end; def g; ENV.key?("B"); end'
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    snap = { "A" => "1" }.freeze
    log = Optimize::Log.new
    r = find_iseq(ir, "r")

    pass = Optimize::Passes::ConstFoldEnvPass.new
    each_function(ir) do |fn|
      pass.apply(fn, type_env: nil, log: log, object_table: ot, env_snapshot: snap)
    end

    refute_includes r.instructions.map(&:opcode), :opt_aref
    refute(log.for_pass(:const_fold_env).any? { |e| e.reason == :env_write_observed })
  end
  ```

- [ ] **Step 3: Add `test_env_values_at_two_args_still_taints_v1`.**

  Documents the v1 scope limit: argc≥2 safe methods stay tainted.

  ```ruby
  def test_env_values_at_two_args_still_taints_v1
    # v1 scope: argc>=2 safe methods are NOT narrowed; still taint.
    src = 'def r; ENV["A"]; end; def g; ENV.values_at("A", "B"); end'
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    snap = { "A" => "1", "B" => "2" }.freeze
    log = Optimize::Log.new
    r = find_iseq(ir, "r")
    before_r = r.instructions.map(&:opcode)

    pass = Optimize::Passes::ConstFoldEnvPass.new
    each_function(ir) do |fn|
      pass.apply(fn, type_env: nil, log: log, object_table: ot, env_snapshot: snap)
    end

    assert_equal before_r, r.instructions.map(&:opcode),
      "v1 does not narrow argc>=2 safe sends — r should NOT fold"
    assert_operator log.for_pass(:const_fold_env).count { |e| e.reason == :env_write_observed }, :>=, 1
  end
  ```

- [ ] **Step 4: Add `test_env_aset_still_taints_tree`.**

  Verifies explicit-write path (`ENV["X"] = "y"` → `opt_aset`) still taints.

  ```ruby
  def test_env_aset_still_taints_tree
    # opt_aset is not on the safe list — still taints.
    # Wrap in a def so the taint classifier has a function to scan.
    src = 'def r; ENV["A"]; end; def w; ENV["B"] = "x"; end'
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    snap = { "A" => "1" }.freeze
    log = Optimize::Log.new
    r = find_iseq(ir, "r")
    before_r = r.instructions.map(&:opcode)

    pass = Optimize::Passes::ConstFoldEnvPass.new
    each_function(ir) do |fn|
      pass.apply(fn, type_env: nil, log: log, object_table: ot, env_snapshot: snap)
    end

    assert_equal before_r, r.instructions.map(&:opcode)
    assert_operator log.for_pass(:const_fold_env).count { |e| e.reason == :env_write_observed }, :>=, 1
  end
  ```

  Note: `opt_aset` may hit a codec limitation per the existing file's preamble — if this test exposes a decode error, drop it and rely on `test_env_write_in_tree_taints_and_disables_folds` (which uses `ENV.store`) as the mutation sentinel.

- [ ] **Step 5: Run full env-pass suite. Green.**

- [ ] **Step 6: Commit.**

  ```
  jj commit -m "test: const_fold_env — sibling read-only sends don't taint; writes and argc>=2 still taint"
  ```

---

## Task 4: Update TODO.md

**Files:**
- Modify: `docs/TODO.md`

- [ ] **Step 1: Strike the `ConstFoldEnvPass` narrowing bullet from the "Refinements of shipped work" section.**

  Remove the bullet starting "**`ConstFoldEnvPass` narrowing of taint classifier.**".

- [ ] **Step 2: Update the Tier 4 shipped-column cell** in the "Three-pass plan: status" table. Append: "Read-only sends (`fetch`, `to_h`, `key?`, …) no longer taint the tree; argc≤1 only."

- [ ] **Step 3: Bump the "Last updated" line to 2026-04-25.**

- [ ] **Step 4: Commit.**

  ```
  jj commit -m "docs: TODO.md — ConstFoldEnv taint classifier narrowing shipped"
  ```

---

## Verification checklist

- [ ] `mcp__ruby-bytecode__run_optimizer_tests` green on the full optimizer suite.
- [ ] `docs/TODO.md` no longer lists the narrowing bullet.
- [ ] No other pass's behavior changed (fold log surface unchanged).
- [ ] Commit graph: 3–4 commits (red test; classifier change; expanded coverage; TODO update). Merge-ok if some are squashed, but keep red-before-green for the first pair.
