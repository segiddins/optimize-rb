# InliningPass v5 — `send` with block iseq, with invokeblock substitution — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend `InliningPass` so `5.tap { nil }` (with a user-supplied `def tap; yield self; self; end` in the same compilation unit) collapses through the default pipeline to `putobject 5; leave`.

**Architecture:** Add a third dispatch branch to `InliningPass#apply` for `:send` opcodes carrying a block iseq operand. The branch splices the callee body into the caller (v4-style receiver stash), and *within the spliced body* replaces each `invokeblock` site with (a) setlocal stashes for the pushed args and (b) the block body verbatim (minus its trailing `leave`, with block-param `getlocal`s retargeted to the stash slots). All "last mile" cleanup (`putnil;pop`, receiver stash forwarding, dead writes) is delegated to the existing `DeadStashElimPass` + `ConstFoldPass` + `IdentityElimPass` fixed-point loop in `Pipeline.default`.

**Tech Stack:** Ruby 3.4+, Minitest, `optimize/codec` (YARV binary round-trip), `Codec::LocalTable.grow!` / `shift_level0_lindex!`, `ruby-bytecode` MCP for disasm verification.

**Spec:** `docs/superpowers/specs/2026-04-24-pass-inlining-v5-tap-with-block-design.md`

---

## File Structure

**Modify:**
- `optimizer/lib/optimize/passes/inlining_pass.rb` — add `try_inline_send_with_block`, `disqualify_callee_for_send_with_block`, `disqualify_block`, `substitute_invokeblocks`, `BLOCK_FORBIDDEN` constant. Add third dispatch branch in the main `while` loop.
- `optimizer/lib/optimize/pipeline.rb` — thread `iseq_list` into `run_single_pass` keyword args so the inliner can resolve block iseq indices.

**Create:**
- `optimizer/test/passes/tap_inline_pass_test.rb` — unit tests for the new branch (positive cases, per-guard bailouts).
- `optimizer/test/codec/corpus/tap_constant_block.rb` — round-trip fixture for `5.tap { nil }`.
- `optimizer/test/codec/corpus/tap_identity_block.rb` — round-trip fixture for `x.tap { |y| y }`.
- `optimizer/examples/5_tap_nil.rb` — demo walkthrough source.

**Touch-test only (no code change):**
- `optimizer/test/pipeline_test.rb` — add end-to-end assertion that `5.tap { nil }` collapses to `putobject 5; leave`.
- `optimizer/test/passes/inlining_pass_test.rb` — add regression test that existing v4 behavior is unchanged.

---

## Task 1: Plumb `iseq_list` into `InliningPass#apply`

The pass needs to resolve `send` operand[1] (an iseq-list index) to an `IR::Function`. `Pipeline#run_single_pass` already knows the `iseq_list` (used by `build_callee_map`); we just need to pass it.

**Files:**
- Modify: `optimizer/lib/optimize/pipeline.rb:104-117` (extend `run_single_pass` kwargs)
- Modify: `optimizer/lib/optimize/pipeline.rb:60-100` (compute `iseq_list` once at top of `run`)
- Modify: `optimizer/lib/optimize/passes/inlining_pass.rb:42` (add `iseq_list:` to `apply` signature)

- [ ] **Step 1: Write the failing test**

Append to `optimizer/test/passes/inlining_pass_test.rb` above the final `end`:

```ruby
def test_apply_accepts_iseq_list_kwarg
  src = "def magic; 42; end; def use_it; magic; end; use_it"
  ir  = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
  ot  = ir.misc[:object_table]
  use_it = find_iseq(ir, "use_it")
  magic  = find_iseq(ir, "magic")
  log = Optimize::Log.new
  # Passing iseq_list: must not raise or break v4 behavior.
  Optimize::Passes::InliningPass.new.apply(
    use_it, type_env: nil, log: log,
    object_table: ot, callee_map: { magic: magic },
    iseq_list: ir.misc[:iseq_list],
  )
  assert_equal [:putobject, :leave], use_it.instructions.map(&:opcode)
end
```

- [ ] **Step 2: Run test to verify it fails**

Run via the MCP optimizer-tests runner:

```
mcp__ruby-bytecode__run_optimizer_tests test_filter=test/passes/inlining_pass_test.rb
```

Expected: FAIL with `ArgumentError: unknown keyword: :iseq_list` (because `apply` swallows via `**_extras` today, so this should actually PASS — verify).

If the test passes because `**_extras` already absorbs the kwarg, convert the test to assert the kwarg reaches pipeline calls: modify to assert via a subclass that captures the kwarg. Replacement test body:

```ruby
def test_pipeline_passes_iseq_list_to_inlining
  captured = nil
  captor = Class.new(Optimize::Passes::InliningPass) do
    define_method(:apply) do |function, **kwargs|
      captured = kwargs[:iseq_list]
      super(function, **kwargs)
    end
  end
  src = "def magic; 42; end; def use_it; magic; end; use_it"
  ir  = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
  pipeline = Optimize::Pipeline.new([captor.new])
  pipeline.run(ir, type_env: nil)
  refute_nil captured, "pipeline should pass iseq_list: into pass apply"
end
```

Run again — expected FAIL with `captured` nil.

- [ ] **Step 3: Modify Pipeline to pass `iseq_list`**

In `optimizer/lib/optimize/pipeline.rb`, change `run` to compute `iseq_list` once:

```ruby
def run(ir, type_env:, env_snapshot: nil)
  log = Log.new
  object_table = ir.misc && ir.misc[:object_table]
  iseq_list    = ir.misc && ir.misc[:iseq_list]
  callee_map = build_callee_map(ir)
  slot_type_map, signature_map = build_type_maps(ir, type_env, object_table)
  # ...
```

Then update `run_single_pass` signature and call site to thread it through:

```ruby
def run_single_pass(pass, function, type_env, log, object_table, callee_map,
                    slot_type_map, signature_map, env_snapshot, iseq_list)
  pass.apply(
    function,
    type_env: type_env, log: log,
    object_table: object_table, callee_map: callee_map,
    slot_type_map: slot_type_map,
    signature_map: signature_map,
    env_snapshot: env_snapshot,
    iseq_list: iseq_list,
  )
rescue => e
  log.skip(pass: pass.name, reason: :pass_raised,
           file: function.path, line: function.first_lineno || 0)
end
```

And update both call sites in `run` (the one-shot and iterative loops) to pass `iseq_list` as the tenth positional argument.

- [ ] **Step 4: Run test to verify it passes**

```
mcp__ruby-bytecode__run_optimizer_tests test_filter=test/passes/inlining_pass_test.rb
```

Expected: PASS (new test plus all existing). `apply`'s `**_extras` in `inlining_pass.rb:42` will absorb the new kwarg; no pass code change needed yet.

- [ ] **Step 5: Commit**

```
jj commit -m "optimizer: thread iseq_list through Pipeline to passes" optimizer/lib/optimize/pipeline.rb optimizer/test/passes/inlining_pass_test.rb
```

---

## Task 2: `disqualify_block` helper

Block-level guards: empty catch table, single trailing leave, no level-1 local access, no opcode in `BLOCK_FORBIDDEN`.

**Files:**
- Modify: `optimizer/lib/optimize/passes/inlining_pass.rb` (add `BLOCK_FORBIDDEN` constant near `CONTROL_FLOW_OPCODES` at line 25, add private `disqualify_block(block)` method near `disqualify_callee` at line 370)
- Create: `optimizer/test/passes/tap_inline_pass_test.rb`

- [ ] **Step 1: Write the failing test**

Create `optimizer/test/passes/tap_inline_pass_test.rb`:

```ruby
# frozen_string_literal: true
require "test_helper"
require "optimize/codec"
require "optimize/passes/inlining_pass"

class TapInlinePassTest < Minitest::Test
  def test_disqualify_block_accepts_constant_body
    src = "5.tap { nil }"
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    block = find_block(ir)
    refute_nil block
    assert_nil pass.send(:disqualify_block, block),
      "expected { nil } block to be inlineable"
  end

  def test_disqualify_block_rejects_catch_table
    src = "5.tap { begin; 1; rescue; 2; end }"
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    block = find_block(ir)
    refute_nil block
    assert_equal :block_has_catch_table, pass.send(:disqualify_block, block)
  end

  def test_disqualify_block_rejects_level1_local_access
    src = "x = 1; 5.tap { x }"
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    block = find_block(ir)
    refute_nil block
    assert_equal :block_captures_level1, pass.send(:disqualify_block, block)
  end

  def test_disqualify_block_rejects_break
    src = "5.tap { break nil }"
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    block = find_block(ir)
    refute_nil block
    reason = pass.send(:disqualify_block, block)
    assert_includes [:block_escapes, :block_nested_leave, :block_has_catch_table], reason
  end

  def test_disqualify_block_rejects_branches
    src = "x = true; 5.tap { x ? 1 : 2 }"
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    block = find_block(ir)
    refute_nil block
    reason = pass.send(:disqualify_block, block)
    # Either the branch trips :block_escapes, or the x-read trips
    # :block_captures_level1. Both are legitimate rejections.
    assert_includes [:block_escapes, :block_captures_level1], reason
  end

  private

  def pass
    @pass ||= Optimize::Passes::InliningPass.new
  end

  def find_block(fn)
    return fn if fn.type == :block
    (fn.children || []).each do |c|
      found = find_block(c)
      return found if found
    end
    nil
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

```
mcp__ruby-bytecode__run_optimizer_tests test_filter=test/passes/tap_inline_pass_test.rb
```

Expected: FAIL with `NoMethodError: private method 'disqualify_block' called`.

- [ ] **Step 3: Add `BLOCK_FORBIDDEN` constant and `disqualify_block` method**

In `optimizer/lib/optimize/passes/inlining_pass.rb`, after the `CONTROL_FLOW_OPCODES` constant (around line 25):

```ruby
# Opcodes that prevent block inlining. Branches are forbidden for the
# same reason callee branches are: a straight-line splice can't preserve
# branch targets across index shifts. Escape-like opcodes (throw, break,
# next, redo) would change meaning after splicing out of the block frame.
BLOCK_FORBIDDEN = (CONTROL_FLOW_OPCODES + %i[
  throw break next redo
  invokesuper invokesuperforward
  getblockparam getblockparamproxy
  definemethod definesmethod defineclass
  once
]).freeze
```

Then, after `disqualify_callee` around line 414, add:

```ruby
def disqualify_block(block)
  return :block_has_catch_table if block.catch_entries && !block.catch_entries.empty?
  insts = block.instructions || []
  return :block_empty if insts.empty?
  return :block_no_trailing_leave unless insts.last.opcode == :leave
  body = insts[0..-2]
  body.each do |inst|
    return :block_nested_leave if inst.opcode == :leave
    return :block_escapes if BLOCK_FORBIDDEN.include?(inst.opcode)
    case inst.opcode
    when :getlocal_WC_1
      return :block_captures_level1
    when :getlocal, :setlocal
      return :block_captures_level1 if inst.operands[1] && inst.operands[1] != 0
    when :send, :opt_send_without_block, :invokesuper, :invokesuperforward
      cd = inst.operands[0]
      if cd.respond_to?(:flag) && (cd.flag & 0x20) != 0
        return :block_escapes
      end
    end
  end
  nil
end
```

- [ ] **Step 4: Run tests to verify they pass**

```
mcp__ruby-bytecode__run_optimizer_tests test_filter=test/passes/tap_inline_pass_test.rb
```

Expected: all five `disqualify_block` tests PASS. Also run the full inliner suite to check for regressions:

```
mcp__ruby-bytecode__run_optimizer_tests test_filter=test/passes/inlining_pass_test.rb
```

Expected: all existing tests PASS.

- [ ] **Step 5: Commit**

```
jj commit -m "optimizer: InliningPass — disqualify_block helper and BLOCK_FORBIDDEN" optimizer/lib/optimize/passes/inlining_pass.rb optimizer/test/passes/tap_inline_pass_test.rb
```

---

## Task 3: `disqualify_callee_for_send_with_block` variant

Like `_for_opt_send` but permits `invokeblock` (since that's what we're substituting). Still rejects nested block-carrying sends, invokesuper, catch tables, and branches.

**Files:**
- Modify: `optimizer/lib/optimize/passes/inlining_pass.rb` (add new private method next to `disqualify_callee_for_opt_send`)

- [ ] **Step 1: Write the failing test**

Append to `optimizer/test/passes/tap_inline_pass_test.rb`:

```ruby
def test_disqualify_callee_for_send_with_block_accepts_tap_body
  src = <<~RUBY
    def tap; yield self; self; end
    5.tap { nil }
  RUBY
  ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
  callee = find_iseq(ir, "tap")
  refute_nil callee
  assert_nil pass.send(:disqualify_callee_for_send_with_block, callee)
end

def test_disqualify_callee_for_send_with_block_rejects_invokesuper
  src = <<~RUBY
    class A; def tap; super; end; end
    A.new.tap { nil }
  RUBY
  ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
  callee = find_iseq(ir, "tap")
  refute_nil callee
  assert_equal :callee_uses_super, pass.send(:disqualify_callee_for_send_with_block, callee)
end

def test_disqualify_callee_for_send_with_block_rejects_nested_block_send
  # A callee body that itself yields and then makes a send with its own block.
  src = <<~RUBY
    def tap; yield self; [1].each { |x| x }; end
    5.tap { nil }
  RUBY
  ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
  callee = find_iseq(ir, "tap")
  refute_nil callee
  assert_equal :callee_send_has_block, pass.send(:disqualify_callee_for_send_with_block, callee)
end

private

def find_iseq(fn, name)
  return fn if fn.name == name
  (fn.children || []).each do |c|
    found = find_iseq(c, name)
    return found if found
  end
  nil
end
```

- [ ] **Step 2: Run tests to verify they fail**

```
mcp__ruby-bytecode__run_optimizer_tests test_filter=test/passes/tap_inline_pass_test.rb
```

Expected: FAIL with `NoMethodError: private method 'disqualify_callee_for_send_with_block' called`.

- [ ] **Step 3: Add the disqualifier**

In `optimizer/lib/optimize/passes/inlining_pass.rb`, directly after `disqualify_callee_for_opt_send` (around line 368):

```ruby
# Like #disqualify_callee_for_opt_send but permits `:invokeblock`
# (the whole point of v5 is to substitute these) while still rejecting
# invokesuper, nested block-carrying sends, branches, catch tables.
def disqualify_callee_for_send_with_block(callee)
  return :callee_has_catch if callee.catch_entries && !callee.catch_entries.empty?
  insts = callee.instructions || []
  return :callee_empty if insts.empty?
  return :callee_over_budget if insts.size > INLINE_BUDGET
  return :callee_no_trailing_leave unless insts.last.opcode == :leave

  body = insts[0..-2]
  body.each do |inst|
    return :callee_has_branches     if CONTROL_FLOW_OPCODES.include?(inst.opcode)
    return :callee_has_leave_midway if inst.opcode == :leave
    return :callee_has_throw        if inst.opcode == :throw
    return :callee_uses_ivar        if inst.opcode == :getinstancevariable
    return :callee_uses_ivar        if inst.opcode == :setinstancevariable
    case inst.opcode
    when :invokesuper, :invokesuperforward
      return :callee_uses_super
    when :getblockparam, :getblockparamproxy
      return :callee_uses_block_param
    when :opt_send_without_block
      # A nested plain FCALL is allowed only if it wouldn't itself require
      # block-aware inlining. Accept; v5 does not recurse into it.
      nil
    when :send
      cd = inst.operands[0]
      blk_idx = inst.operands[1]
      if blk_idx.is_a?(Integer) && blk_idx >= 0
        return :callee_send_has_block
      end
      if cd.respond_to?(:blockarg?) && cd.blockarg?
        return :callee_send_has_block
      end
    end
  end
  nil
end
```

- [ ] **Step 4: Run tests to verify they pass**

```
mcp__ruby-bytecode__run_optimizer_tests test_filter=test/passes/tap_inline_pass_test.rb
```

Expected: three new tests PASS, prior tests still PASS.

- [ ] **Step 5: Commit**

```
jj commit -m "optimizer: InliningPass — disqualify_callee_for_send_with_block" optimizer/lib/optimize/passes/inlining_pass.rb optimizer/test/passes/tap_inline_pass_test.rb
```

---

## Task 4: Invokeblock substitution (pure function on an instruction list)

Extract the core block-substitution logic as a pure method that takes a callee body (list of `IR::Instruction`) and a block iseq, and returns a new instruction list with every `invokeblock` site replaced by (stashes for pushed args) + (block body minus trailing leave, with level-0 getlocal/setlocal remapped to caller-side stash slots).

This task does not yet wire the substitution into `apply` — it just builds and tests the pure function.

**Files:**
- Modify: `optimizer/lib/optimize/passes/inlining_pass.rb` (add private `substitute_invokeblocks(callee_body, block, stash_base_lindex:)` method)

- [ ] **Step 1: Write the failing test**

Append to `optimizer/test/passes/tap_inline_pass_test.rb`:

```ruby
def test_substitute_invokeblocks_replaces_invokeblock_with_block_body
  src = <<~RUBY
    def tap; yield self; self; end
    5.tap { nil }
  RUBY
  ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
  callee = find_iseq(ir, "tap")
  block  = find_block(ir)
  body   = callee.instructions[0..-2]  # drop trailing leave

  rewritten = pass.send(
    :substitute_invokeblocks,
    body, block, stash_base_lindex: 4,
  )

  # Before: putself; invokeblock argc:1; pop; putself
  # After : putself; setlocal_WC_0 <A0>; putnil; pop; putself
  opcodes = rewritten.map(&:opcode)
  assert_equal [:putself, :setlocal_WC_0, :putnil, :pop, :putself], opcodes
  assert_equal 4, rewritten[1].operands[0], "arg stash must target stash_base_lindex"
end

def test_substitute_invokeblocks_remaps_block_param_getlocal
  src = <<~RUBY
    def tap; yield self; self; end
    5.tap { |y| y }
  RUBY
  ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
  callee = find_iseq(ir, "tap")
  block  = find_block(ir)
  body   = callee.instructions[0..-2]

  rewritten = pass.send(
    :substitute_invokeblocks,
    body, block, stash_base_lindex: 4,
  )

  # The block body is `getlocal_WC_0 <y_lindex=3>; leave`. After substitution
  # the leave is dropped and the getlocal is remapped to lindex 4 (the stash).
  opcodes = rewritten.map(&:opcode)
  assert_equal [:putself, :setlocal_WC_0, :getlocal_WC_0, :pop, :putself], opcodes
  assert_equal 4, rewritten[1].operands[0]
  assert_equal 4, rewritten[2].operands[0]
end
```

- [ ] **Step 2: Run tests to verify they fail**

```
mcp__ruby-bytecode__run_optimizer_tests test_filter=test/passes/tap_inline_pass_test.rb
```

Expected: FAIL with `NoMethodError: private method 'substitute_invokeblocks' called`.

- [ ] **Step 3: Implement `substitute_invokeblocks`**

In `optimizer/lib/optimize/passes/inlining_pass.rb`, add a private method:

```ruby
# Replace every :invokeblock site in `callee_body` with:
#   <setlocal_WC_0 stash_base+k for k in argc-1..0>
#   <block body minus trailing leave, with level-0 getlocal/setlocal
#    remapped: param slots → stash_base..stash_base+argc-1, block temps
#    → fresh slots starting at stash_base+argc>
#
# Does NOT mutate callee_body. Returns a freshly allocated list of
# freshly allocated IR::Instruction values. Caller is responsible for
# growing the enclosing function's local table by the total slots used
# across all invokeblock sites.
def substitute_invokeblocks(callee_body, block, stash_base_lindex:)
  block_body = block.instructions[0..-2] # drop trailing leave
  block_lt_size = (block.misc && block.misc[:local_table_size]) || 0

  result = []
  callee_body.each do |inst|
    if inst.opcode == :invokeblock
      cd = inst.operands[0]
      argc = cd.argc

      # Stash pushed args: last-pushed lands at stash_base + argc - 1.
      (argc - 1).downto(0) do |k|
        result << IR::Instruction.new(
          opcode: :setlocal_WC_0,
          operands: [stash_base_lindex + k],
          line: inst.line,
        )
      end

      # Remap and splice block body. Parameter slots occupy the last `argc`
      # entries of the block's local table; in YARV LINDEX terms those are
      # 3 .. 3+argc-1 inclusive (since LINDEX = 3 + (lt_size - 1 - idx) and
      # params are the first `argc` table indices).
      param_lindexes = (0...argc).map { |k| NEW_SLOT_LINDEX + (block_lt_size - 1 - k) }
      param_to_stash = {}
      param_lindexes.each_with_index do |lidx, i|
        param_to_stash[lidx] = stash_base_lindex + i
      end

      block_body.each do |binst|
        result << remap_block_inst(binst, param_to_stash)
      end
    else
      result << IR::Instruction.new(
        opcode: inst.opcode,
        operands: inst.operands.dup,
        line: inst.line,
      )
    end
  end
  result
end

def remap_block_inst(binst, param_to_stash)
  case binst.opcode
  when :getlocal_WC_0, :setlocal_WC_0
    lidx = binst.operands[0]
    new_lidx = param_to_stash[lidx] || lidx
    IR::Instruction.new(opcode: binst.opcode, operands: [new_lidx], line: binst.line)
  when :getlocal, :setlocal
    lidx, level = binst.operands
    if level == 0
      new_lidx = param_to_stash[lidx] || lidx
      IR::Instruction.new(opcode: binst.opcode, operands: [new_lidx, 0], line: binst.line)
    else
      IR::Instruction.new(opcode: binst.opcode, operands: binst.operands.dup, line: binst.line)
    end
  else
    IR::Instruction.new(opcode: binst.opcode, operands: binst.operands.dup, line: binst.line)
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

```
mcp__ruby-bytecode__run_optimizer_tests test_filter=test/passes/tap_inline_pass_test.rb
```

Expected: both new tests PASS, prior tests still PASS.

- [ ] **Step 5: Commit**

```
jj commit -m "optimizer: InliningPass — pure substitute_invokeblocks helper" optimizer/lib/optimize/passes/inlining_pass.rb optimizer/test/passes/tap_inline_pass_test.rb
```

---

## Task 5: Wire `try_inline_send_with_block` into `apply`

Add the third dispatch branch. For the first cut, handle only `argc == 0` on the outer send with a `:send` opcode and a valid block iseq operand. Reuse v4's receiver-stash approach for `putself` rebinding; use `substitute_invokeblocks` (Task 4) for the inner block substitution. Grow the caller's local table by `1 (receiver) + Σ_sites (argc + block_temp_count)` and shift existing LINDEXes once.

**Files:**
- Modify: `optimizer/lib/optimize/passes/inlining_pass.rb` (add private `try_inline_send_with_block`, extend `#apply` dispatcher)

- [ ] **Step 1: Write the failing integration test**

Append to `optimizer/test/passes/tap_inline_pass_test.rb`:

```ruby
def test_5_tap_nil_inlines_and_substitutes_block
  src = <<~RUBY
    def tap; yield self; self; end
    5.tap { nil }
  RUBY
  ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
  ot = ir.misc[:object_table]
  top = ir  # top-level iseq
  tap_fn = find_iseq(ir, "tap")
  refute_nil tap_fn

  log = Optimize::Log.new
  Optimize::Passes::InliningPass.new.apply(
    top, type_env: nil, log: log,
    object_table: ot, callee_map: { tap: tap_fn },
    iseq_list: ir.misc[:iseq_list],
  )

  # The caller's :send is gone.
  refute top.instructions.any? { |i| i.opcode == :send },
    "send should have been replaced: #{top.instructions.map(&:opcode).inspect}"

  # The inlined body must produce a valid VM state; verify semantically via
  # round-trip execution after the pass.
  loaded = RubyVM::InstructionSequence.load_from_binary(Optimize::Codec.encode(ir))
  assert_equal 5, loaded.eval
end
```

- [ ] **Step 2: Run test to verify it fails**

```
mcp__ruby-bytecode__run_optimizer_tests test_filter=test/passes/tap_inline_pass_test.rb
```

Expected: FAIL — `:send` still present because `apply` has no branch for it yet.

- [ ] **Step 3: Extend the dispatcher and add `try_inline_send_with_block`**

In `optimizer/lib/optimize/passes/inlining_pass.rb`, modify `apply` to accept `iseq_list:` as an explicit kwarg and dispatch `:send`:

```ruby
def apply(function, type_env:, log:, object_table: nil, callee_map: {},
          slot_type_map: {}, iseq_list: nil, **_extras)
  _ = type_env
  return unless object_table
  slot_table = slot_type_map[function]
  insts = function.instructions
  return unless insts

  loop do
    changed = false
    i = 0
    while i < insts.size
      b = insts[i]
      case b.opcode
      when :opt_send_without_block
        cd = b.operands[0]
        if cd.is_a?(IR::CallData) && cd.fcall?
          if try_inline(function, i, callee_map, object_table, log)
            changed = true; insts = function.instructions; next
          end
        elsif slot_table
          if try_inline_opt_send(function, i, callee_map, object_table, log, slot_table)
            changed = true; insts = function.instructions; next
          end
        end
      when :send
        if iseq_list && try_inline_send_with_block(
          function, i, callee_map, object_table, log, iseq_list
        )
          changed = true; insts = function.instructions; next
        end
      end
      i += 1
    end
    break unless changed
  end
end
```

Then add the new private method near the other `try_inline_*` methods:

```ruby
def try_inline_send_with_block(function, send_idx, callee_map, object_table, log, iseq_list)
  insts = function.instructions
  send_inst = insts[send_idx]
  cd = send_inst.operands[0]
  blk_idx = send_inst.operands[1]
  line = send_inst.line || function.first_lineno

  return false unless cd.is_a?(IR::CallData)
  return false unless cd.argc == 0
  return false unless cd.args_simple? && cd.kwlen.zero? && !cd.blockarg? && !cd.has_splat?
  return false unless blk_idx.is_a?(Integer) && blk_idx >= 0

  iseqs = iseq_list&.functions
  block = iseqs && iseqs[blk_idx]
  unless block && block.type == :block
    log.skip(pass: :inlining, reason: :send_shape_unsupported,
             file: function.path, line: line)
    return false
  end

  # Receiver producer must be a single-instruction push (same as v4 zero-arg).
  return false unless send_idx >= 1 && ARG_PUSH_OPCODES.include?(insts[send_idx - 1].opcode)
  recv_inst = insts[send_idx - 1]

  mid = cd.mid_symbol(object_table)
  callee = callee_map[mid]
  unless callee
    log.skip(pass: :inlining, reason: :callee_unresolved,
             file: function.path, line: line)
    return false
  end

  reason = disqualify_callee_for_send_with_block(callee)
  if reason
    log.skip(pass: :inlining, reason: reason, file: function.path, line: line)
    return false
  end

  reason = disqualify_block(block)
  if reason
    log.skip(pass: :inlining, reason: reason, file: function.path, line: line)
    return false
  end

  # Sum the stash slots we'll need across all invokeblock sites in the callee.
  callee_body = callee.instructions[0..-2]
  invokeblock_argcs = callee_body.select { |i| i.opcode == :invokeblock }
                                  .map { |i| i.operands[0].argc }
  # Self-stash is +1. Each invokeblock contributes argc stash slots.
  # (Block temps beyond params are out-of-scope for v5; disqualify_block
  # already rejected level-1 captures, and the block's own local_table_size
  # equals its param count for the accepted shapes.)
  total_stash = 1 + invokeblock_argcs.sum
  self_stash_lindex = NEW_SLOT_LINDEX + invokeblock_argcs.sum # layout: invokeblock stashes first, then self

  # Grow caller's local table and shift pre-existing level-0 LINDEXes.
  # Names: reuse a placeholder object index for each new slot.
  name_idx = 0 # object-table slot 0 is conventionally safe; names don't matter
  total_stash.times { Codec::LocalTable.grow!(function, name_idx) }
  Codec::LocalTable.shift_level0_lindex!(function, by: total_stash)

  # Build the substituted body. Each invokeblock gets its own stash block
  # starting at NEW_SLOT_LINDEX + (preceding sites' argc sum).
  stash_cursor = NEW_SLOT_LINDEX
  substituted = []
  callee_body.each do |inst|
    if inst.opcode == :invokeblock
      argc = inst.operands[0].argc
      # Inline substitute_invokeblocks's per-site logic.
      sub = substitute_invokeblocks([inst], block, stash_base_lindex: stash_cursor)
      substituted.concat(sub)
      stash_cursor += argc
    else
      substituted << IR::Instruction.new(
        opcode: inst.opcode,
        operands: inst.operands.dup,
        line: inst.line,
      )
    end
  end

  # Replace putself in the substituted body with getlocal_WC_0 self_stash_lindex.
  substituted = substituted.map do |inst|
    if inst.opcode == :putself
      IR::Instruction.new(opcode: :getlocal_WC_0,
                          operands: [self_stash_lindex],
                          line: inst.line)
    else
      inst
    end
  end

  # Refresh post-shift references to recv_inst in case it was a getlocal_WC_0.
  insts_now = function.instructions
  recv_in_now = insts_now[send_idx - 1]

  # Construct the receiver-stash preamble.
  receiver_stash = IR::Instruction.new(
    opcode: :setlocal_WC_0,
    operands: [self_stash_lindex],
    line: recv_in_now.line || line,
  )
  replacement = [recv_in_now, receiver_stash, *substituted]
  function.splice_instructions!((send_idx - 1)..send_idx, replacement)

  log.rewrite(pass: :inlining, reason: :inlined, file: function.path, line: line)
  true
end
```

- [ ] **Step 4: Run test to verify it passes**

```
mcp__ruby-bytecode__run_optimizer_tests test_filter=test/passes/tap_inline_pass_test.rb
```

Expected: the new `test_5_tap_nil_inlines_and_substitutes_block` PASSES. Then run the full suite:

```
mcp__ruby-bytecode__run_optimizer_tests
```

Expected: all tests PASS (no regressions to v4 behavior or codec round-trip).

- [ ] **Step 5: Commit**

```
jj commit -m "optimizer: InliningPass v5 — send with block + invokeblock substitution (zero-arg outer)" optimizer/lib/optimize/passes/inlining_pass.rb optimizer/test/passes/tap_inline_pass_test.rb
```

---

## Task 6: Pipeline end-to-end — `5.tap { nil }` → `putobject 5; leave`

Prove the cascade through `DeadStashElimPass` + `ConstFoldPass` + `IdentityElimPass` closes the gap without a new pass.

**Files:**
- Modify: `optimizer/test/pipeline_test.rb` (add one test)

- [ ] **Step 1: Write the failing test**

Append to `optimizer/test/pipeline_test.rb`:

```ruby
def test_5_tap_nil_collapses_to_putobject_leave
  src = <<~RUBY
    def tap; yield self; self; end
    5.tap { nil }
  RUBY
  ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
  log = Optimize::Pipeline.default.run(ir, type_env: nil)

  top = ir
  # The top-level iseq contains the definemethod for tap, followed by the
  # reduced caller region. Isolate the tail after definemethod.
  idx = top.instructions.index { |i| i.opcode == :definemethod }
  tail = top.instructions[(idx + 1)..]
  refute_nil tail
  # Expected tail: putobject 5; leave. (definemethod pushes the method name
  # and pops it, or leaves it on stack — verify the actual shape here.)
  assert tail.any? { |i| i.opcode == :putobject && i.operands[0] == 5 },
    "expected putobject 5 to survive; got: #{tail.map { |i| [i.opcode, i.operands] }.inspect}"
  assert_equal :leave, tail.last.opcode

  # Semantic check.
  loaded = RubyVM::InstructionSequence.load_from_binary(Optimize::Codec.encode(ir))
  assert_equal 5, loaded.eval
end
```

- [ ] **Step 2: Run test to verify it fails or passes**

```
mcp__ruby-bytecode__run_optimizer_tests test_filter=test/pipeline_test.rb
```

Expected: likely PASS (the cleanup passes should already collapse the canonical form from Task 5). If it FAILS, inspect the log entries and post-Pipeline disasm to identify which cleanup pass didn't fire. Common causes:

- `DeadStashElim` didn't collapse `setlocal A0; putnil` because `A0` is never read — check that the pass considers `setlocal` with no subsequent `getlocal` dead even when the value came from a side-effecting producer (it's not here: `putself`→`getlocal R_slot` has no side effects).
- `ConstFoldPass`/`IdentityElim` didn't collapse `putnil; pop` — check pass contracts.

Fix the canonical emission in Task 5's splice (adjust ordering) rather than adding a new pass.

- [ ] **Step 3: If the test failed, inspect with the MCP disasm tool**

Run a scratch Ruby script via the MCP to dump the post-pipeline iseq:

```
mcp__ruby-bytecode__run_ruby code='
  require "optimize"
  src = "def tap; yield self; self; end; 5.tap { nil }"
  ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
  Optimize::Pipeline.default.run(ir, type_env: nil)
  puts RubyVM::InstructionSequence.load_from_binary(Optimize::Codec.encode(ir)).disasm
'
```

Use the disasm to decide what to adjust in `try_inline_send_with_block`. If e.g. the stash slot is not immediately followed by the getlocal it feeds, add an intervening instruction in the splice that preserves that adjacency.

- [ ] **Step 4: Run test to verify it passes**

```
mcp__ruby-bytecode__run_optimizer_tests test_filter=test/pipeline_test.rb
mcp__ruby-bytecode__run_optimizer_tests
```

Expected: all PASS.

- [ ] **Step 5: Commit**

```
jj commit -m "optimizer: pipeline test — 5.tap { nil } collapses to putobject 5; leave" optimizer/test/pipeline_test.rb
```

---

## Task 7: Guards coverage — per-guard bailout tests

One test per row of the spec's guards table, verifying each skip path fires the right `log.skip` reason. This is what makes the demo walkthrough informative.

**Files:**
- Modify: `optimizer/test/passes/tap_inline_pass_test.rb`

- [ ] **Step 1: Write the failing tests**

Append to `optimizer/test/passes/tap_inline_pass_test.rb`:

```ruby
def test_bailout_block_has_catch_table
  log = run_inliner_on(<<~RUBY)
    def tap; yield self; self; end
    5.tap { begin; 1; rescue; 2; end }
  RUBY
  assert log.entries.any? { |e| e.reason == :block_has_catch_table },
    "reasons: #{log.entries.map(&:reason).inspect}"
end

def test_bailout_block_captures_level1
  log = run_inliner_on(<<~RUBY)
    def tap; yield self; self; end
    x = 1
    5.tap { x }
  RUBY
  assert log.entries.any? { |e| e.reason == :block_captures_level1 },
    "reasons: #{log.entries.map(&:reason).inspect}"
end

def test_bailout_block_escapes_on_branch
  log = run_inliner_on(<<~RUBY)
    def tap; yield self; self; end
    5.tap { 1 > 0 ? 1 : 2 }
  RUBY
  assert log.entries.any? { |e| e.reason == :block_escapes },
    "reasons: #{log.entries.map(&:reason).inspect}"
end

def test_bailout_callee_unresolved
  # No tap in callee_map — should log :callee_unresolved.
  src = "5.tap { nil }"
  ir  = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
  log = Optimize::Log.new
  Optimize::Passes::InliningPass.new.apply(
    ir, type_env: nil, log: log,
    object_table: ir.misc[:object_table], callee_map: {},
    iseq_list: ir.misc[:iseq_list],
  )
  assert log.entries.any? { |e| e.reason == :callee_unresolved },
    "reasons: #{log.entries.map(&:reason).inspect}"
end

private

def run_inliner_on(src)
  ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
  tap_fn = find_iseq(ir, "tap")
  log = Optimize::Log.new
  cm = tap_fn ? { tap: tap_fn } : {}
  Optimize::Passes::InliningPass.new.apply(
    ir, type_env: nil, log: log,
    object_table: ir.misc[:object_table], callee_map: cm,
    iseq_list: ir.misc[:iseq_list],
  )
  log
end
```

- [ ] **Step 2: Run tests to verify they fail or pass**

```
mcp__ruby-bytecode__run_optimizer_tests test_filter=test/passes/tap_inline_pass_test.rb
```

Expected: PASS (the guard code was already added in Tasks 2 & 3; this task codifies the expected reasons). If any reason doesn't match, adjust the test or (only if the logged reason is genuinely wrong for the case) fix the disqualifier.

- [ ] **Step 3: Commit**

```
jj commit -m "optimizer: InliningPass v5 — guard coverage tests for tap/block" optimizer/test/passes/tap_inline_pass_test.rb
```

(No step 4/5 here since no implementation change was needed.)

---

## Task 8: Corpus round-trip fixtures

Add the two canonical shapes to the codec corpus so the round-trip harness exercises them encode→decode→optimize→execute.

**Files:**
- Create: `optimizer/test/codec/corpus/tap_constant_block.rb`
- Create: `optimizer/test/codec/corpus/tap_identity_block.rb`

- [ ] **Step 1: Write the corpus fixtures**

Create `optimizer/test/codec/corpus/tap_constant_block.rb`:

```ruby
def tap; yield self; self; end
5.tap { nil }
```

Create `optimizer/test/codec/corpus/tap_identity_block.rb`:

```ruby
def tap; yield self; self; end
x = 42
x.tap { |y| y }
```

- [ ] **Step 2: Run the corpus round-trip test**

```
mcp__ruby-bytecode__run_optimizer_tests test_filter=test/codec/corpus_test.rb
```

Expected: PASS — both new fixtures encode/decode cleanly. (Optimization is not required for corpus_test; that's purely a codec fidelity check.)

- [ ] **Step 3: Commit**

```
jj commit -m "optimizer: corpus — tap_constant_block and tap_identity_block" optimizer/test/codec/corpus/tap_constant_block.rb optimizer/test/codec/corpus/tap_identity_block.rb
```

---

## Task 9: Demo walkthrough entry

Wire an example that the walkthrough renderer picks up for the §5 talk demo.

**Files:**
- Create: `optimizer/examples/5_tap_nil.rb`

- [ ] **Step 1: Write the example**

Create `optimizer/examples/5_tap_nil.rb`:

```ruby
def tap
  yield self
  self
end

5.tap { nil }
```

- [ ] **Step 2: Run the walkthrough test to verify pickup**

```
mcp__ruby-bytecode__run_optimizer_tests test_filter=test/demo/walkthrough_test.rb
```

Expected: PASS. If the walkthrough test enumerates examples and this one collapses through the pipeline as expected, no additional plumbing is needed. If it fails because the walkthrough expects specific diff output, inspect `optimizer/lib/optimize/demo/walkthrough.rb` and update the fixture list there to include the new example.

- [ ] **Step 3: Verify per-pass diff by running the demo runner**

```
mcp__ruby-bytecode__run_optimizer_tests test_filter=test/demo/runner_test.rb
```

Expected: PASS.

- [ ] **Step 4: Commit**

```
jj commit -m "optimizer: demo — 5_tap_nil example for §5 walkthrough" optimizer/examples/5_tap_nil.rb
```

---

## Task 10: Full suite, benchmark sanity

One final gate: run the entire optimizer test suite plus the benchmark harness to catch any unexpected interaction.

**Files:** none (verification only)

- [ ] **Step 1: Run the full optimizer suite**

```
mcp__ruby-bytecode__run_optimizer_tests
```

Expected: all tests PASS. If anything is red, triage individually.

- [ ] **Step 2: Run the benchmark harness**

```
mcp__ruby-bytecode__run_optimizer_tests test_filter=test/demo/benchmark_test.rb
```

Expected: PASS. The benchmark numbers themselves aren't asserted, but the harness must complete end-to-end against a pipeline that now includes v5 for at least the tap example.

- [ ] **Step 3: Disasm-level sanity via MCP**

Run the MCP disasm tool on the top-level iseq after pipeline:

```
mcp__ruby-bytecode__run_ruby code='
  $LOAD_PATH.unshift "optimizer/lib"
  require "optimize"
  src = File.read("optimizer/examples/5_tap_nil.rb")
  ir  = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
  Optimize::Pipeline.default.run(ir, type_env: nil)
  puts RubyVM::InstructionSequence.load_from_binary(Optimize::Codec.encode(ir)).disasm
'
```

Expected output includes a top-level iseq whose tail (after the `definemethod :tap`) is exactly:

```
putobject 5
leave
```

If instead you see residual `setlocal`/`getlocal` pairs or a lingering `putnil; pop`, the cascade didn't close. Return to Task 6's troubleshooting path.

- [ ] **Step 4: Final commit (if any noise)**

If any touch-ups were needed from step 3, commit them. Otherwise skip.

```
jj commit -m "optimizer: InliningPass v5 final sanity passes"
```

---

## Completion criteria

- All new tests in `tap_inline_pass_test.rb` and the new case in `pipeline_test.rb` pass.
- No regressions in `inlining_pass_test.rb`, `pipeline_test.rb`, or any codec/round-trip test.
- `optimizer/examples/5_tap_nil.rb` pipelines to a top-level iseq whose non-definemethod tail is exactly `putobject 5; leave`.
- Each guard in the spec's guards table has a corresponding bailout test.
- All commits follow the repo's existing `optimizer: ...` message style.
