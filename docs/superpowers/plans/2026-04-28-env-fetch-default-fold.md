# ConstFoldEnvPass — `ENV.fetch(LIT, default)` argc=2 fold — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a new fold arm to `ConstFoldEnvPass` for `ENV.fetch("LIT", <pure-default>)` argc=2. Key present → `putobject <value>` (default dropped — must be side-effect-free). Key absent → the default producer alone (preserves runtime semantics).

**Architecture:** New 4-instruction window dispatch inside the existing fold loop: `ENV; put*string KEY; <pure-default>; opt_send_without_block :fetch argc=2`. Purity is a whitelist of single-instruction side-effect-free producers (`putnil`, `putobject`, `putstring`, `putchilledstring`, `putself`). Anything else → skip (no fold, no log). Taint classifier already allows argc=2 `fetch` as-of 2026-04-28 v2, so this is purely a fold addition.

**Design doc:** `docs/superpowers/specs/2026-04-28-env-fetch-default-fold-design.md`.

**Tech Stack:** Ruby (4.0.2), Minitest. All Ruby/test execution via the `ruby-bytecode` MCP server (`mcp__ruby-bytecode__run_optimizer_tests`). VCS via `jj`: finalize commits with `jj commit -m`, never `jj describe -m`.

---

## File map

- Modify: `optimizer/lib/optimize/passes/const_fold_env_pass.rb`
  - Add `PURE_DEFAULT_OPCODES` frozen Set.
  - Add `fetch_send_argc2?(inst, object_table)` predicate.
  - Add `pure_default?(inst)` helper.
  - Add a new 4-window fold arm inside the existing fold loop, *before* the argc=1 arm so a valid argc=2 site is handled first.
- Modify: `optimizer/test/passes/const_fold_env_pass_test.rb`
  - **Replace** `test_env_fetch_argc_two_is_not_folded` with several positive tests (see Task 1).
  - Add impure-default negative test.
- Modify: `docs/TODO.md`
  - Append to the Tier 4 "Shipped" cell in the status table.
  - In the "Tier 4 follow-ups" tail of that cell, strike `ENV.fetch(LIT, default)`.
  - Bump "Last updated".

---

## Task 1: Red — argc=2 fetch-with-default folds; impure defaults still bail

**Files:**
- Modify: `optimizer/test/passes/const_fold_env_pass_test.rb`

The existing `test_env_fetch_argc_two_is_not_folded` (lines ~344–362) must be replaced by its inverse plus companions. Remove it entirely — the v2 scope is exactly to flip that behavior.

- [ ] **Step 1: Remove `test_env_fetch_argc_two_is_not_folded`.** Delete the entire method. Keep `test_env_fetch_with_block_does_not_crash` immediately after it — that test stays (block form is still out of scope).

- [ ] **Step 2: Add `test_folds_env_fetch_with_literal_default_when_key_present`.**

  ```ruby
  def test_folds_env_fetch_with_literal_default_when_key_present
    src = 'def r; ENV.fetch("A", "fallback"); end'
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    r = find_iseq(ir, "r")
    snap = { "A" => "1" }.freeze
    log = Optimize::Log.new

    pass = Optimize::Passes::ConstFoldEnvPass.new
    each_function(ir) do |fn|
      pass.apply(fn, type_env: nil, log: log, object_table: ot, env_snapshot: snap)
    end

    opcodes = r.instructions.map(&:opcode)
    refute_includes opcodes, :opt_send_without_block, "fetch send should be folded away"
    refute_includes opcodes, :opt_getconstant_path, "ENV producer should be gone"
    assert_includes opcodes, :putobject
    folded = log.for_pass(:const_fold_env).count { |e| e.reason == :folded }
    assert_operator folded, :>=, 1
  end
  ```

- [ ] **Step 3: Add `test_folds_env_fetch_with_string_default_when_key_absent`.**

  ```ruby
  def test_folds_env_fetch_with_string_default_when_key_absent
    src = 'def r; ENV.fetch("MISSING", "fallback"); end'
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    r = find_iseq(ir, "r")
    snap = {}.freeze
    log = Optimize::Log.new

    pass = Optimize::Passes::ConstFoldEnvPass.new
    each_function(ir) do |fn|
      pass.apply(fn, type_env: nil, log: log, object_table: ot, env_snapshot: snap)
    end

    opcodes = r.instructions.map(&:opcode)
    refute_includes opcodes, :opt_send_without_block, "fetch send should be folded away"
    refute_includes opcodes, :opt_getconstant_path, "ENV producer should be gone"
    # The default producer survives — either :putstring or :putchilledstring
    # depending on Ruby's compile-time string handling.
    assert(opcodes.include?(:putstring) || opcodes.include?(:putchilledstring),
      "default string producer should be preserved as the fold result")
    folded = log.for_pass(:const_fold_env).count { |e| e.reason == :folded }
    assert_operator folded, :>=, 1
  end
  ```

- [ ] **Step 4: Add `test_folds_env_fetch_with_putnil_default_when_key_absent`.**

  ```ruby
  def test_folds_env_fetch_with_putnil_default_when_key_absent
    src = 'def r; ENV.fetch("MISSING", nil); end'
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    r = find_iseq(ir, "r")
    snap = {}.freeze
    log = Optimize::Log.new

    pass = Optimize::Passes::ConstFoldEnvPass.new
    each_function(ir) do |fn|
      pass.apply(fn, type_env: nil, log: log, object_table: ot, env_snapshot: snap)
    end

    opcodes = r.instructions.map(&:opcode)
    refute_includes opcodes, :opt_send_without_block
    refute_includes opcodes, :opt_getconstant_path
    assert_includes opcodes, :putnil
    folded = log.for_pass(:const_fold_env).count { |e| e.reason == :folded }
    assert_operator folded, :>=, 1
  end
  ```

- [ ] **Step 5: Add `test_folds_env_fetch_with_integer_default_when_key_absent`.**

  ```ruby
  def test_folds_env_fetch_with_integer_default_when_key_absent
    src = 'def r; ENV.fetch("MISSING", 42); end'
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    r = find_iseq(ir, "r")
    snap = {}.freeze
    log = Optimize::Log.new

    pass = Optimize::Passes::ConstFoldEnvPass.new
    each_function(ir) do |fn|
      pass.apply(fn, type_env: nil, log: log, object_table: ot, env_snapshot: snap)
    end

    opcodes = r.instructions.map(&:opcode)
    refute_includes opcodes, :opt_send_without_block
    refute_includes opcodes, :opt_getconstant_path
    assert_includes opcodes, :putobject
    folded = log.for_pass(:const_fold_env).count { |e| e.reason == :folded }
    assert_operator folded, :>=, 1
  end
  ```

- [ ] **Step 6: Add impure-default negative test.**

  The default `ENV.fetch("A", other_call)` isn't on the purity whitelist (method call), so the site must not be folded and all original opcodes must survive.

  ```ruby
  def test_does_not_fold_env_fetch_with_impure_default
    # `other_call` compiles to a send, which is not on PURE_DEFAULT_OPCODES.
    src = <<~RUBY
      def other_call; "x"; end
      def r; ENV.fetch("A", other_call); end
    RUBY
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    r = find_iseq(ir, "r")
    before = r.instructions.map(&:opcode)
    snap = { "A" => "1" }.freeze
    log = Optimize::Log.new

    pass = Optimize::Passes::ConstFoldEnvPass.new
    each_function(ir) do |fn|
      pass.apply(fn, type_env: nil, log: log, object_table: ot, env_snapshot: snap)
    end

    assert_equal before, r.instructions.map(&:opcode),
      "impure default must preserve the full ENV.fetch bytecode"
    # The fetch send is still present, so an argc-match-but-impure-default
    # must not count as a fold.
    refute(log.for_pass(:const_fold_env).any? { |e| e.reason == :folded && e.file == r.path },
      "no :folded log entry should be emitted for r when default is impure")
  end
  ```

  Note: if `e.file` isn't the right accessor for the log entry's file in this codebase, drop the `&& e.file == r.path` guard — the presence check across the whole log will still fail green once the fold loop correctly skips impure defaults (there's no other ENV usage in `r`). The v1-era fetch tests check `:folded` counts globally; this stricter check is a nicety.

- [ ] **Step 7: Run env-pass test file via MCP.** Use `mcp__ruby-bytecode__run_optimizer_tests` with a name filter for these new tests (e.g. `test_folds_env_fetch_with_` and `test_does_not_fold_env_fetch_with_impure_default`). Expected: the four positive tests fail (argc=2 fold doesn't exist yet — fetch send still present). The impure-default test passes (no fold because no argc=2 arm today). Record the failure messages.

- [ ] **Step 8: Commit red.**

  ```
  jj commit -m "test: red — ENV.fetch(LIT, pure-default) argc=2 should fold"
  ```

---

## Task 2: Green — add argc=2 fold arm + wire-up + docs

**Files:**
- Modify: `optimizer/lib/optimize/passes/const_fold_env_pass.rb`
- Modify: `docs/TODO.md`

One commit combining the code change, the wire-up into the fold loop, and the status-table update.

- [ ] **Step 1: Add the two helpers + constant to `ConstFoldEnvPass`.**

  Place the constant near `SAFE_ENV_READ_METHODS`:

  ```ruby
  # Default-producer opcodes that are safe to drop when folding
  # `ENV.fetch(LIT, default)` on a key hit: each is a single-instruction
  # side-effect-free producer. Extending this set requires the producer
  # to be observably pure (no autoload, no side effects, no raises).
  PURE_DEFAULT_OPCODES = %i[
    putnil putobject putstring putchilledstring putself
  ].to_set.freeze
  ```

  Place the two helpers near the existing `fetch_send?` / `safe_send?` helpers (private section):

  ```ruby
  def fetch_send_argc2?(inst, object_table)
    cd = inst.operands[0]
    return false unless cd.is_a?(IR::CallData)
    return false unless cd.argc == 2
    return false if cd.has_kwargs? || cd.has_splat? || cd.blockarg?
    cd.mid_symbol(object_table) == :fetch
  end

  def pure_default?(inst)
    inst && PURE_DEFAULT_OPCODES.include?(inst.opcode)
  end
  ```

- [ ] **Step 2: Add the argc=2 fold arm to the fold loop.**

  Locate the existing `apply` method's fold loop. It currently contains, inside the `while i <= insts.size - 3` loop:
  1. A skip on non-`env_producer?` / non-`literal_string?` mismatch.
  2. A branch on `op.opcode == :opt_aref` (argc=0 fold).
  3. A branch on `op.opcode == :opt_send_without_block && fetch_send?(op, object_table)` (argc=1 fold).
  4. An `else` that does `i += 1`.

  Insert a new branch **before** the `opt_aref` branch (so it's tried first on any 4-inst window that matches). The new branch needs to also look at `insts[i + 3]`:

  ```ruby
  d   = insts[i + 2]
  op4 = insts[i + 3]
  if d && op4 && op4.opcode == :opt_send_without_block &&
     fetch_send_argc2?(op4, object_table) && pure_default?(d)
    key = LiteralValue.read(b, object_table: object_table)
    if env_snapshot.key?(key)
      value = env_snapshot[key]
      if value.is_a?(String)
        idx = object_table.intern(value)
        replacement = IR::Instruction.new(opcode: :putobject, operands: [idx], line: a.line)
        function.splice_instructions!(i..(i + 3), [replacement])
        log.skip(pass: :const_fold_env, reason: :folded,
                 file: function.path, line: (a.line || function.first_lineno || 0))
      else
        log.skip(pass: :const_fold_env, reason: :env_value_not_string,
                 file: function.path, line: (a.line || function.first_lineno || 0))
      end
    else
      # Key absent: return the default. Keep `d` as the sole instruction.
      function.splice_instructions!(i..(i + 3), [d])
      log.skip(pass: :const_fold_env, reason: :folded,
               file: function.path, line: (a.line || function.first_lineno || 0))
    end
    i += 1
    next
  end
  ```

  The `next` keeps the cursor bump out of the subsequent `if/elsif/else` chain. Verify the enclosing loop is a plain `while` with `next` semantics (not a `loop do`); if it's a bare `while`, `next` jumps to the re-check at the top — correct.

  Note: variables `a` and `b` are already bound earlier in the loop body to `insts[i]` and `insts[i + 1]` — reuse them. The purity check `pure_default?(d)` is what ensures we're allowed to drop the default when the key is present.

  Why this arm runs *before* `opt_aref`: both arms require the same `ENV; put*string` prefix at `i..i+1`. `opt_aref` at `i+2` is a no-match for the argc=2 arm (`op4.opcode == :opt_send_without_block` fails); the argc=2 arm's guard rejects it cleanly. Ordering is *not* a soundness issue but putting the new arm first keeps a natural narrative (widest window first).

- [ ] **Step 3: Run the env-pass test file via MCP.** All five new tests from Task 1 should be GREEN. All prior tests still green.

- [ ] **Step 4: Run the full optimizer suite via MCP** (no filter). Should be fully green. Expected net test count: `239 + 5 − 1 = 243` (Task 1 removed one, added five).

- [ ] **Step 5: Update `docs/TODO.md`.**

  a. In the "Three-pass plan: status" table, Tier 4 "Shipped" cell: append:

  ```
   argc=2 `ENV.fetch(LIT, pure-default)` now folds — default must be a single pure producer (`putnil`/`putobject`/`put[chilled]string`/`putself`); on key hit the default is dropped, on miss the default becomes the fold result.
  ```

  b. In the Tier 4 "Remaining" cell (same row, rightmost column), remove `ENV.fetch(LIT, default)` from the follow-ups list.

  c. In the "Roadmap gap, ranked by talk-ROI" section, if item #7.5 exists for this work, strike it. If it does not yet exist (we tracked it only in session memory), skip — nothing to strike.

  d. Bump "Last updated" to: `2026-04-28 (after ConstFoldEnvPass — argc=2 ENV.fetch-with-default fold).`

- [ ] **Step 6: Commit.**

  ```
  jj commit -m "feat: ConstFoldEnvPass — argc=2 ENV.fetch(LIT, pure-default) fold"
  ```

---

## Verification checklist

- [ ] `mcp__ruby-bytecode__run_optimizer_tests` green on full optimizer suite.
- [ ] All five new tests green; `test_env_fetch_argc_two_is_not_folded` is gone.
- [ ] `test_env_fetch_with_block_does_not_crash` still passes — the block form is still not folded (its send isn't `opt_send_without_block`).
- [ ] `test_env_fetch_fold_disabled_by_tree_taint`-style protection still works for argc=2 (tainted tree skips the fold arm entirely because `root.misc[TAINT_FLAG_KEY]` early-returns `apply`). Not a new test — just verify no regression.
- [ ] `docs/TODO.md` Tier 4 cell updated; "Last updated" bumped; follow-ups list trimmed.
- [ ] Commit graph: 2 commits — `test: red …` then `feat: …`.
