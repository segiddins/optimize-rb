# ConstFoldEnvPass taint-classifier v2 (argc-generic safe sends) — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend `ConstFoldEnvPass#consumer_safe?` so read-only sends on `ENV` with any argc (not just 0..1) no longer taint the IR tree. Unblocks `ENV.values_at("A", "B", "C")` sibling-doesn't-taint behavior.

**Architecture:** Replace the v1 two-branch consumer lookup (hardcoded positions i+1 for argc=0, i+2 for argc=1) with a forward scan: for `j = 0..`, inspect `insts[i + 1 + j]`; the first `opt_send_without_block` encountered is the consumer candidate. Safe iff `cd.argc == j`, mid ∈ `SAFE_ENV_READ_METHODS`, no kwargs/splat/block. Any other first-send-encountered → taint. `opt_aref` check at i+2 stays as-is (argc-free opcode).

**Design doc:** `docs/superpowers/specs/2026-04-28-env-taint-classifier-v2-design.md`.

**Tech Stack:** Ruby (4.0.2), Minitest. All Ruby/test execution via the `ruby-bytecode` MCP server (`mcp__ruby-bytecode__run_optimizer_tests`) — never host shell. VCS via `jj`: use `jj commit -m` to finalize commits, never `jj describe -m`.

---

## File map

- Modify: `optimizer/lib/optimize/passes/const_fold_env_pass.rb`
  - Rewrite `consumer_safe?` to forward-scan instead of branching on i+1/i+2 positions.
  - Update the method-header comment to reflect v2 semantics.
  - No changes to `safe_send?` (reused), `SAFE_ENV_READ_METHODS`, fold loop, or `scan_tree_for_taint`.
- Modify: `optimizer/test/passes/const_fold_env_pass_test.rb`
  - Replace `test_env_values_at_two_args_still_taints_v1` with `test_env_values_at_two_args_does_not_taint_tree`.
  - Add `test_env_values_at_three_args_does_not_taint_tree`.
  - Add `test_env_store_two_args_still_taints_tree`.
- Modify: `docs/TODO.md`
  - Strike item #6 from the ranked roadmap gap.
  - Update Tier 4 "Shipped" cell in the status table.
  - Bump "Last updated" to 2026-04-28.

---

## Task 1: Red — argc=2 and argc=3 safe sends should not taint; argc=2 write should still taint

**Files:**
- Modify: `optimizer/test/passes/const_fold_env_pass_test.rb`

- [ ] **Step 1: Find the existing `test_env_values_at_two_args_still_taints_v1` test.** It was added 2026-04-25. Its body asserts `r` does NOT fold and `:env_write_observed` count ≥ 1 for `def r; ENV["A"]; end; def g; ENV.values_at("A", "B"); end`.

- [ ] **Step 2: Replace that test with its inverse — argc=2 safe send should not taint.**

  Rename the method and flip the assertions:

  ```ruby
  def test_env_values_at_two_args_does_not_taint_tree
    src = 'def r; ENV["A"]; end; def g; ENV.values_at("A", "B"); end'
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    snap = { "A" => "1", "B" => "2" }.freeze
    log = Optimize::Log.new
    r = find_iseq(ir, "r")

    pass = Optimize::Passes::ConstFoldEnvPass.new
    each_function(ir) do |fn|
      pass.apply(fn, type_env: nil, log: log, object_table: ot, env_snapshot: snap)
    end

    refute_includes r.instructions.map(&:opcode), :opt_aref,
      "r should fold — ENV.values_at (argc=2) sibling must not taint in v2"
    refute(log.for_pass(:const_fold_env).any? { |e| e.reason == :env_write_observed },
           "argc=2 safe sends should not taint the tree in v2")
  end
  ```

- [ ] **Step 3: Add argc=3 companion.**

  ```ruby
  def test_env_values_at_three_args_does_not_taint_tree
    src = 'def r; ENV["A"]; end; def g; ENV.values_at("A", "B", "C"); end'
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    snap = { "A" => "1", "B" => "2", "C" => "3" }.freeze
    log = Optimize::Log.new
    r = find_iseq(ir, "r")

    pass = Optimize::Passes::ConstFoldEnvPass.new
    each_function(ir) do |fn|
      pass.apply(fn, type_env: nil, log: log, object_table: ot, env_snapshot: snap)
    end

    refute_includes r.instructions.map(&:opcode), :opt_aref,
      "r should fold — ENV.values_at (argc=3) sibling must not taint in v2"
    refute(log.for_pass(:const_fold_env).any? { |e| e.reason == :env_write_observed },
           "argc=3 safe sends should not taint the tree in v2")
  end
  ```

- [ ] **Step 4: Add argc=2 write still-taints guard.**

  This confirms the argc-generic scan doesn't accidentally whitelist mutating sends just because their argc is in the previously-tainted range.

  ```ruby
  def test_env_store_two_args_still_taints_tree
    # ENV.store is not in SAFE_ENV_READ_METHODS — v2's argc-generic scan
    # still taints on it (mid check is what gates safety).
    src = 'def r; ENV["A"]; end; def w; ENV.store("B", "x"); end'
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

    assert_equal before_r, r.instructions.map(&:opcode),
      "r should NOT fold — ENV.store sibling still taints in v2"
    assert_operator log.for_pass(:const_fold_env).count { |e| e.reason == :env_write_observed }, :>=, 1
  end
  ```

- [ ] **Step 5: Run the env-pass test file via MCP.**

  Use `mcp__ruby-bytecode__run_optimizer_tests` with a name filter narrowing to the three new tests (e.g. `test_env_values_at` and `test_env_store_two_args`). Expected RED:
  - `test_env_values_at_two_args_does_not_taint_tree` fails (classifier still taints on argc=2 — `opt_aref` still present in `r`).
  - `test_env_values_at_three_args_does_not_taint_tree` fails (same).
  - `test_env_store_two_args_still_taints_tree` passes (v1 already taints argc=2 sends of any mid).

  Record the failure messages — the first two should point to `opt_aref` still present.

- [ ] **Step 6: Commit red tests.**

  ```
  jj commit -m "test: red — ENV argc≥2 safe sends should not taint Tier 4 tree"
  ```

---

## Task 2: Green — forward-scan classifier + wire-up + docs

**Files:**
- Modify: `optimizer/lib/optimize/passes/const_fold_env_pass.rb`
- Modify: `docs/TODO.md`

Per the repo's TDD commit rhythm, green + wire-up + docs land in one commit.

- [ ] **Step 1: Rewrite `consumer_safe?` in `const_fold_env_pass.rb`.**

  Locate the existing method:

  ```ruby
  # For an ENV producer at `insts[i]`, return [safe?, consumer_line].
  # Safe if the consumer is:
  #   - opt_aref at i+2 (bare ENV[KEY]; consumes ENV+key), OR
  #   - opt_send_without_block at i+1 with argc=0 and a safe mid, OR
  #   - opt_send_without_block at i+2 with argc=1 and a safe mid.
  # All other consumer shapes taint.
  def consumer_safe?(insts, i, object_table)
    at_i_plus_1 = insts[i + 1]
    at_i_plus_2 = insts[i + 2]

    if at_i_plus_2 && at_i_plus_2.opcode == :opt_aref
      return [true, at_i_plus_2.line]
    end

    if at_i_plus_1 && at_i_plus_1.opcode == :opt_send_without_block &&
       safe_send?(at_i_plus_1, object_table, expected_argc: 0)
      return [true, at_i_plus_1.line]
    end

    if at_i_plus_2 && at_i_plus_2.opcode == :opt_send_without_block &&
       safe_send?(at_i_plus_2, object_table, expected_argc: 1)
      return [true, at_i_plus_2.line]
    end

    [false, (at_i_plus_2 && at_i_plus_2.line) || (at_i_plus_1 && at_i_plus_1.line)]
  end
  ```

  Replace it with the forward-scan v2 shape:

  ```ruby
  # For an ENV producer at `insts[i]`, return [safe?, consumer_line].
  # Safe if the consumer is:
  #   - opt_aref at i+2 (bare ENV[KEY]; consumes ENV+key), OR
  #   - the first opt_send_without_block encountered at insts[i + 1 + j]
  #     with cd.argc == j, mid ∈ SAFE_ENV_READ_METHODS, and no
  #     kwargs/splat/block.
  # Stops at the first send encountered: if that send doesn't match,
  # taints. Walking off the end without a send also taints.
  def consumer_safe?(insts, i, object_table)
    at_i_plus_2 = insts[i + 2]
    if at_i_plus_2 && at_i_plus_2.opcode == :opt_aref
      return [true, at_i_plus_2.line]
    end

    j = 0
    last_seen_line = nil
    loop do
      cand = insts[i + 1 + j]
      break unless cand
      last_seen_line = cand.line || last_seen_line
      if cand.opcode == :opt_send_without_block
        if safe_send?(cand, object_table, expected_argc: j)
          return [true, cand.line]
        else
          return [false, cand.line]
        end
      end
      j += 1
    end

    [false, last_seen_line]
  end
  ```

- [ ] **Step 2: Run the ConstFoldEnvPass test file via MCP.** All tests (including the three red ones from Task 1, and every v1 test) should be GREEN. If any v1 test regresses, stop — the forward-scan logic is the only variable; debug before proceeding.

- [ ] **Step 3: Run the full optimizer suite via MCP** (`mcp__ruby-bytecode__run_optimizer_tests` with no filter). Should be fully green. Expected test count: v1 suite + 2 new tests (Task 1 added 2 net — one was a replacement, two were additions).

- [ ] **Step 4: Update `docs/TODO.md`.**

  a. In the "Three-pass plan: status" table, update the Tier 4 "Shipped" cell. It currently ends with "`ENV.fetch("LIT")` argc=1 is now folded when snapshot carries the key (snapshot-presence check preserves runtime KeyError semantics; `:fetch_key_absent` log on miss)." Append:

  ```
   Taint classifier v2: read-only sends whitelist is argc-generic via forward-scan (first-send-encountered must match cd.argc and safe mid); `ENV.values_at("A","B","C")` siblings no longer taint.
  ```

  b. In the "Roadmap gap, ranked by talk-ROI" list, strike item #6 (mark shipped like #3 and #7):

  ```
  6. ~~**Tier 4 classifier v2 — argc-generic safe sends.** …~~
     **Shipped 2026-04-28.** Plan: `docs/superpowers/plans/2026-04-28-env-taint-classifier-v2.md`.
  ```

  c. Bump the "Last updated" line at the top from `2026-04-27 (after ConstFoldEnvPass — ENV.fetch literal-key fold).` to `2026-04-28 (after ConstFoldEnvPass — taint classifier v2, argc-generic safe sends).`.

- [ ] **Step 5: Commit green + wire-up + docs.**

  ```
  jj commit -m "feat: ConstFoldEnvPass — argc-generic safe-send classifier (v2)"
  ```

---

## Verification checklist

- [ ] `mcp__ruby-bytecode__run_optimizer_tests` green on full optimizer suite.
- [ ] `docs/TODO.md` item #6 marked shipped; Tier 4 cell updated; "Last updated" bumped.
- [ ] v1 tests (`test_env_fetch_does_not_taint_tree`, `test_env_to_h_does_not_taint_tree`, `test_env_key_question_does_not_taint_tree`) still green — the forward-scan must subsume v1's argc=0/1 cases.
- [ ] Fold log surface unchanged: no new log reasons, no renamed ones.
- [ ] Commit graph: 2 commits — `test: red …` then `feat: …`. Red-before-green preserved.
