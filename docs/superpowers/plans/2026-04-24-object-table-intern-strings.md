# ObjectTable#intern for frozen strings — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let `ObjectTable#intern` accept `String` values and emit a valid T_STRING payload on encode, so `ConstFoldEnvPass` can fold `ENV[LIT]` to its snapshot string unconditionally.

**Architecture:** Two surgical codec changes (relax `intern`'s guard, add a T_STRING branch in the encode-append loop) plus a matching `ConstFoldEnvPass` change that calls `intern` instead of the `index_for`-only lookup. Tests drive each change TDD-style.

**Tech Stack:** Ruby (4.0.2), Minitest. All Ruby execution and tests run via the `ruby-bytecode` MCP server — never via host shell. All VCS via `jj`.

---

## File map

- Modify: `optimizer/lib/optimize/codec/object_table.rb`
  - `intern` (lines 202–215): accept `String`, freeze-and-dup on append.
  - `encode` (lines 139–183): dispatch `write_special_const` vs
    `write_string` in the append loop.
  - New private `write_string(writer, value)` next to `write_special_const`.
- Modify: `optimizer/lib/optimize/passes/const_fold_env_pass.rb`
  - Replace the `index_for(value) || skip` branch (lines 68–76) with
    `intern(value)`. Leave the non-String defensive leg.
- Modify: `optimizer/test/codec/object_table_intern_test.rb` (add string tests).
- Modify: `optimizer/test/passes/const_fold_env_pass_test.rb`
  - Update `test_skips_fold_when_snapshot_value_not_in_object_table`
    (now folds).
  - Add `test_folds_env_bare_aref_via_string_intern`.
- Modify: `docs/TODO.md` — move the Refinements entry to the Shipped
  column for Tier 4; strike the `:env_value_not_interned` note.

---

## Task 1: Red — string intern round-trip test

**Files:**
- Modify: `optimizer/test/codec/object_table_intern_test.rb`

- [ ] **Step 1: Add the failing test**

Append to `optimizer/test/codec/object_table_intern_test.rb`, before the final `end`:

```ruby
  def test_intern_appends_string_and_round_trips
    src = "def f; 2 + 3; end; f"
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    before_size = ot.objects.size

    idx = ot.intern("hello")
    assert_equal before_size, idx, "new index should be end-of-table"
    assert_equal "hello", ot.objects[idx]
    assert_predicate ot.objects[idx], :frozen?

    modified = Optimize::Codec.encode(ir)
    reloaded = Optimize::Codec.decode(modified)
    assert_equal "hello", reloaded.misc[:object_table].objects[idx]
    loaded = RubyVM::InstructionSequence.load_from_binary(modified)
    assert_kind_of RubyVM::InstructionSequence, loaded
    assert_equal 5, loaded.eval
  end

  def test_intern_string_returns_existing_index_when_literal_present
    src = 'def f; "already_here"; end; f'
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    existing = ot.index_for("already_here")
    refute_nil existing, "literal must exist in the table"
    before_size = ot.objects.size
    assert_equal existing, ot.intern("already_here")
    assert_equal before_size, ot.objects.size
  end

  def test_intern_still_rejects_arrays_and_hashes
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile("def f; 1; end; f").to_binary)
    ot = ir.misc[:object_table]
    assert_raises(ArgumentError) { ot.intern([1, 2]) }
    assert_raises(ArgumentError) { ot.intern({ a: 1 }) }
  end
```

- [ ] **Step 2: Run to confirm failure**

Via `mcp__ruby-bytecode__run_ruby` (working dir `optimizer`):

```
bundle exec ruby -Ilib -Itest test/codec/object_table_intern_test.rb -n /intern_appends_string|intern_string_returns_existing|intern_still_rejects/
```

Expected: `test_intern_appends_string_and_round_trips` fails with `ArgumentError: ObjectTable#intern only supports special-const values`. The two other new tests should already pass (existing-index via `index_for`; arrays/hashes already raise).

- [ ] **Step 3: Commit the red test**

```
jj commit -m "test: red — ObjectTable#intern string round-trip" \
  optimizer/test/codec/object_table_intern_test.rb
```

---

## Task 2: Green — relax `intern` and emit T_STRING

**Files:**
- Modify: `optimizer/lib/optimize/codec/object_table.rb`

- [ ] **Step 1: Dispatch in the encode-append loop**

Replace the line at `object_table.rb:154`:

```ruby
            write_special_const(writer, value)
```

with:

```ruby
            if value.is_a?(String)
              write_string(writer, value)
            else
              write_special_const(writer, value)
            end
```

- [ ] **Step 2: Relax the `intern` guard**

Replace `intern` (lines 202–215) with:

```ruby
      def intern(value)
        existing = index_for(value)
        return existing if existing

        if value.is_a?(String)
          stored = value.dup.freeze
          new_idx = @objects.size
          @objects << stored
          @appended ||= []
          @appended << stored
          return new_idx
        end

        unless special_const?(value)
          raise ArgumentError, "ObjectTable#intern only supports special-const values (Integer/true/false/nil) or String, got #{value.inspect}"
        end

        new_idx = @objects.size
        @objects << value
        @appended ||= []
        @appended << value
        new_idx
      end
```

- [ ] **Step 3: Add `write_string` next to `write_special_const`**

Insert after `write_special_const` (after line 452, before the final
`end`s of the class/module):

```ruby
      # Write one T_STRING object payload.
      # Layout (mirrors decode_string):
      #   header byte: 0x45 (T_STRING=5, frozen bit set)
      #   small_value: encindex (0=ASCII_8BIT, 1=UTF_8, 2=US_ASCII)
      #   small_value: byte length
      #   raw bytes
      def write_string(writer, value)
        writer.write_u8(0x45)
        encindex =
          case value.encoding
          when Encoding::ASCII_8BIT then 0
          when Encoding::US_ASCII   then 2
          else                           1  # UTF-8 / fallback
          end
        bytes = value.b
        writer.write_small_value(encindex)
        writer.write_small_value(bytes.bytesize)
        writer.write_bytes(bytes)
      end
```

- [ ] **Step 4: Re-run the intern tests**

```
bundle exec ruby -Ilib -Itest test/codec/object_table_intern_test.rb
```

Expected: all tests pass (six existing + three new).

- [ ] **Step 5: Run the full codec suite to guard against regressions**

```
bundle exec ruby -Ilib -Itest -e "Dir['test/codec/**/*_test.rb'].each { |f| load f }"
```

Expected: all green.

- [ ] **Step 6: Commit**

```
jj commit -m "codec: ObjectTable#intern accepts frozen strings; emit T_STRING in append path" \
  optimizer/lib/optimize/codec/object_table.rb \
  optimizer/test/codec/object_table_intern_test.rb
```

---

## Task 3: ConstFoldEnvPass — call `intern` instead of skipping

**Files:**
- Modify: `optimizer/lib/optimize/passes/const_fold_env_pass.rb`
- Modify: `optimizer/test/passes/const_fold_env_pass_test.rb`

- [ ] **Step 1: Red — rewrite the `not_interned` test to assert folding**

In `optimizer/test/passes/const_fold_env_pass_test.rb` replace
`test_skips_fold_when_snapshot_value_not_in_object_table` (lines 124–143) with:

```ruby
  def test_folds_env_to_interned_string_value
    # "xyzzy" is in the snapshot but NOT anywhere in the compiled program.
    # After string-intern support, the pass MUST fold by interning the
    # snapshot value into the object table.
    src = 'def f; ENV["K"]; end; f'
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    f = find_iseq(ir, "f")
    snap = { "K" => "xyzzy" }.freeze
    log = Optimize::Log.new

    pass = Optimize::Passes::ConstFoldEnvPass.new
    each_function(ir) do |fn|
      pass.apply(fn, type_env: nil, log: log, object_table: ot, env_snapshot: snap)
    end

    refute_includes f.instructions.map(&:opcode), :opt_aref,
      "opt_aref should be folded away"
    folded = log.for_pass(:const_fold_env).count { |e| e.reason == :folded }
    assert_operator folded, :>=, 1
    not_interned = log.for_pass(:const_fold_env).count { |e| e.reason == :env_value_not_interned }
    assert_equal 0, not_interned, ":env_value_not_interned should no longer fire for strings"

    # End-to-end: the re-encoded binary loads and returns the snapshot value.
    loaded = RubyVM::InstructionSequence.load_from_binary(Optimize::Codec.encode(ir))
    assert_equal "xyzzy", loaded.eval
  end
```

- [ ] **Step 2: Run to confirm failure**

```
bundle exec ruby -Ilib -Itest test/passes/const_fold_env_pass_test.rb -n /folds_env_to_interned_string_value/
```

Expected: fails because the pass currently skips and leaves `opt_aref`.

- [ ] **Step 3: Green — update the pass**

In `optimizer/lib/optimize/passes/const_fold_env_pass.rb` replace lines
65–82 (the `replacement = ...` branch) with:

```ruby
          replacement =
            if value.nil?
              IR::Instruction.new(opcode: :putnil, operands: [], line: a.line)
            elsif value.is_a?(String)
              idx = object_table.intern(value)
              IR::Instruction.new(opcode: :putobject, operands: [idx], line: a.line)
            else
              # ENV values are strings or nil by contract. Defensive.
              log.skip(pass: :const_fold_env, reason: :env_value_not_string,
                       file: function.path, line: (a.line || function.first_lineno || 0))
              nil
            end
```

- [ ] **Step 4: Run the full ConstFoldEnvPass suite**

```
bundle exec ruby -Ilib -Itest test/passes/const_fold_env_pass_test.rb
```

Expected: all green.

- [ ] **Step 5: Run the whole test suite**

```
bundle exec ruby -Ilib -Itest -e "Dir['test/**/*_test.rb'].each { |f| load f }"
```

Expected: all green. If anything else regressed, stop and diagnose.

- [ ] **Step 6: Commit**

```
jj commit -m "const_fold_env: intern snapshot string so ENV[LIT] folds unconditionally" \
  optimizer/lib/optimize/passes/const_fold_env_pass.rb \
  optimizer/test/passes/const_fold_env_pass_test.rb
```

---

## Task 4: Update TODO.md

**Files:**
- Modify: `docs/TODO.md`

- [ ] **Step 1: Move the Refinements entry**

In `docs/TODO.md`, remove the `**`ObjectTable#intern` for frozen strings.**` bullet (lines 68–75). Replace the Tier 4 row's `Remaining` text so it no longer mentions the `:env_value_not_interned` skip. The "Three-pass plan: status" Tier 4 cell currently reads:

```
Tier 4 (ConstFoldEnvPass): `ENV["LIT"]` fold with whole-IR-tree taint gate.
```

Append to that cell, on the same line:

```
 String snapshot values interned on-the-fly (no skip).
```

Also update the "ConstFoldEnvPass narrowing of taint classifier" bullet's parenthetical note: strike "Needs string-intern first to be worth it" (string-intern now shipped; that line becomes a plain "candidate refinement").

- [ ] **Step 2: Commit**

```
jj commit -m "docs: TODO.md — ObjectTable#intern strings shipped" docs/TODO.md
```

---

## Self-review checklist

- Spec coverage: intern relaxation ✓ (Task 2), T_STRING encoder ✓ (Task 2), frozen-on-append ✓ (Task 2), ConstFoldEnvPass wiring ✓ (Task 3), TODO update ✓ (Task 4), round-trip test ✓ (Task 1), existing-index test ✓ (Task 1), non-string rejection test ✓ (Task 1), integration test via `ENV["X"]` minimal shape ✓ (Task 3).
- No placeholders: each step shows the exact code block and command.
- Type consistency: `intern` signature unchanged (`(value) → Integer`); `write_string(writer, value)` matches `write_special_const(writer, value)`; header byte `0x45` consistent with the spec's derivation.
