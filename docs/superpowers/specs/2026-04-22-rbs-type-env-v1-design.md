# RBS type environment v1 — receiver-resolving inlining

**Date:** 2026-04-22
**Roadmap item:** `docs/TODO.md` #1 ("RBS type environment").
**Talk section unblocked:** §5 object-y demo (`Point#distance_to`) in
`docs/superpowers/specs/2026-04-19-talk-structure-design.md`.

## Problem

Every pass we ship today is literal-only. The talk-structure spec
calls out RBS as what makes inlining and specialization *sound in
principle*, and names `Point#distance_to` as the object-y demo. The
current `InliningPass` handles FCALL into top-level defs only; there
is no type information flowing into any pass. `RbsParser` and
`TypeEnv` exist as a lookup skeleton (parsed `# @rbs (T) -> T`
comments into a `(receiver_class, method_name) → Signature` map) but
are unconsumed — every `apply` does `_ = type_env`.

## Scope (v1)

**Deliver:** receiver-resolving inlining for `p.distance_to(q)` when
the receiver's type is known, driven by (a) RBS signatures on the
enclosing function and (b) `ClassName.new` constructor-return
inference. Unlocks the `Point#distance_to` demo end-to-end.

**Non-goals for v1:**

- Multi-arg OPT_SEND (argc > 1). `distance_to(other)` is argc=1.
- Forward type-propagation through arithmetic or assignment chains.
- Block-taking callees; `yield`; blocks as args.
- Type hierarchy / subtype matching. Types are compared as strings,
  exact match. `"Integer"` and `"Numeric"` are different strings.
- OPT_SEND where either receiver type or callee `@rbs` is missing.

## Architecture

Three new pieces, one upgraded pass, one data-flow addition.

### 1. `TypeEnv` upgrade

Adds two queries on the existing `RubyOpt::TypeEnv`:

- `signature_for_function(function) → Signature | nil` — returns the
  `@rbs` signature for the function's own definition. Used to seed
  slot types at function entry.
- `new_returns?(class_name) → String | nil` — trivial "`X.new`
  returns `X`" rule; exists to make the rule explicit and testable.
  No other constructor semantics.

### 2. `SlotTypeTable` (new)

Per-function `local_slot_index → type_string` map. Lives in
`optimizer/lib/ruby_opt/ir/slot_type_table.rb` (alongside other IR
bits). Three construction phases:

1. **Signature seeding.** On entry, if the function has an `@rbs`
   signature, each parameter slot is assigned its declared type.
   Non-param slots start at `:unknown`.
2. **Forward scan for `.new`.** Single linear pass over the function's
   instruction stream, looking for the shape
   `[..., opt_getconstant_path <Name>, <arg producers...>,
   opt_send_without_block <mid: :new, argc: N>, setlocal <slot> level=0]`.
   On match, `slot_types[slot] = "Name"`.
3. **Taint on re-assignment.** Any `setlocal <slot> level=0` whose
   producer is not a recognized typed producer clears `slot_types[slot]`
   back to `:unknown`. Non-matching `.new` shapes also clear.

Does not iterate to fixpoint.

**Cross-level lookup.** A `SlotTypeTable` knows its parent iseq's
table. `lookup(slot, level)` walks up `level` parent tables.
Essential for the `1M.times { p.distance_to(q) }` shape, where the
call site is in a block iseq and the types live on the parent.

### 3. `callee_map` upgrade

Current `callee_map` is keyed by method name (FCALL targets
top-level defs). Extend to keys of two shapes:

- `method_name` (top-level defs, unchanged behavior)
- `(receiver_class, method_name)` (instance methods on class bodies)

Populated by walking the iseq tree; class-body children contribute
their methods under the enclosing class name.

### 4. `InliningPass` upgrade (v3)

Adds a second recognizer alongside the existing FCALL one:

**OPT_SEND recognizer.** Matches the window
`<receiver producer>; <one arg producer>; opt_send_without_block <cd: mid: M, argc: 1>`.
Fires when *all* of:

- Receiver producer is `getlocal <slot> level=L`.
- `slot_types.lookup(slot, L)` returns a concrete class name `C`.
- `type_env.signature_for(receiver_class: C, method_name: M)` is non-nil.
- `callee_map[(C, M)]` returns a callee `Function`.
- Callee body is splice-eligible (definition below).

**Self-substitution.** Grow caller's local table by up to two slots:
one stash for the receiver, one stash for the argument (mirrors v2's
one-arg FCALL pattern). Emit `setlocal <arg_stash> level=0` then
`setlocal <self_stash> level=0` before the spliced body (stack
order: receiver is deeper, arg is on top). If the callee body
contains zero self-reading ops, skip the self-stash. Inside the
spliced body, rewrite:

- `putself` → `getlocal <self_stash> level=0`.
- Level-0 `getlocal` / `setlocal` references to the callee's single
  arg slot → rewritten to the arg-stash slot.

Note: YARV's `getinstancevariable` / `setinstancevariable` read/write
through the VM's `GET_SELF()` with no stack operand — they cannot be
retargeted by pushing a different self onto the stack. v1 therefore
forbids them inside splice-eligible bodies (see rule 5 below). The
fixture sidesteps this by using `attr_reader` *method calls* (`x`, `y`)
instead of `@x`/`@y`, which compile to ordinary `putself; send` shapes
and rewrite cleanly.

Every other instruction (including nested plain sends on other
receivers, attr_reader-style sends on the stashed self,
arithmetic) stays as-is.

**Splice-eligible body.** A callee body is splice-eligible iff:

1. Straight-line: no branches of any kind (`branchif`, `branchunless`,
   `branchnil`, `jump` forward/back, `throw`).
2. Single `leave` at the end; the splice drops it.
3. No catch-table entries (no `rescue`/`ensure`/`retry`).
4. No block setup ops (`send` with block arg, `getblockparam`,
   `invokeblock`, `yield`).
5. No `getinstancevariable` / `setinstancevariable`. These ops
   access VM-level `self` with no stack operand and cannot be
   retargeted by stashing the receiver. Bodies that need `@ivar`
   access must use `attr_reader` / `attr_writer` method calls.
6. Callee defines no locals beyond its declared parameters.
   `getlocal`/`setlocal` at level 0 must reference the single arg
   slot only. Callees that introduce intermediate locals (e.g.
   `def foo(x); y = x + 1; y * 2; end`) are out of scope for v1 —
   handling them needs one stash slot per intermediate local.

Nested plain sends on other receivers or the stashed self are fine.
The eligibility rule constrains *shape*, not *op vocabulary*.

### 5. Pipeline wiring

`InliningPass` already receives `type_env`; it now consumes it.
`SlotTypeTable.build(function, type_env, parent_table)` is called at
the top of `InliningPass#apply` per function; the table is passed
into the recognizer. `Pipeline.default` needs no other changes.
Downstream passes (ArithReassoc, ConstFold*, IdentityElim,
DeadBranchFold) benefit automatically because the inliner now
exposes more surface.

## Data flow per OPT_SEND call site

```
window at i: <receiver producer>; <arg producer>; opt_send_without_block
  receiver producer is getlocal(slot, level)?           ─ no → skip
  slot_types.lookup(slot, level) → C ?                  ─ nil → skip
  type_env.signature_for(C, mid) → Signature ?          ─ nil → skip
  callee_map[(C, mid)] → Function ?                     ─ nil → skip
  callee body splice-eligible ?                         ─ no → skip
  grow local_table by 1 or 2 (self-stash, arg-stash)
  rewrite window:
    [receiver producer] [arg producer] [opt_send_without_block]
    →
    [receiver producer] [arg producer]
    [setlocal arg_stash level=0] [setlocal self_stash level=0]
    [spliced body with putself/getivar/arg-LINDEX retargeted, leave dropped]
  advance i past the splice
```

## Demo fixture

**File:** `optimizer/examples/point_distance.rb` (new)

```ruby
# frozen_string_literal: true

class Point
  attr_reader :x, :y

  # @rbs (Integer, Integer) -> void
  def initialize(x, y)
    @x = x
    @y = y
  end

  # @rbs (Point) -> Integer
  def distance_to(other)
    (x - other.x) + (y - other.y)
  end
end

p = Point.new(1, 2)
q = Point.new(4, 6)

1_000_000.times { p.distance_to(q) }
```

Why this shape:

- Body uses attr_reader calls (not `@x`/`@y` directly) — exercises
  the "self-reading ops retarget to stash" rule through nested plain
  sends, which is the more honest story for the talk.
- Integer return (not Float) avoids `Math.sqrt` — keeps the body
  inline-eligible per the splice rule.
- Top-level `.new` assignments trigger constructor-prop; block-body
  access through `1M.times { ... }` exercises cross-level lookup.

## Testing

Red-first ladder, one behavior per test.

1. **`test/ir/slot_type_table_test.rb`** (new)
   - Params of an `@rbs`-annotated function get their types; others
     are `:unknown`.
   - `.new` pattern types the destination slot.
   - Non-`.new` `setlocal` on a previously typed slot clears it.
   - `lookup(slot, 1)` walks to the parent table.

2. **`test/rbs_parser_test.rb`** (existing)
   - Already covers top-level and `Point#distance_to` shapes. No
     new cases expected unless v1 surfaces a gap.

3. **`test/passes/inlining_pass_test.rb`** (existing, extended)
   - **red**: typed receiver + matching callee IR → call site is
     spliced; `putself` rewritten to self-stash; callee arg LINDEX
     rewritten to arg-stash.
   - **red**: callee body has zero self-reading ops → no self-stash
     slot grown.
   - **red**: block iseq with `getlocal level=1` receiver →
     cross-level lookup fires.
   - **guards (no fold, one assertion each)**: receiver slot
     untyped; callee missing from map; callee body branches; callee
     body has a catch entry; callee body has a block arg; callee
     body has `getinstancevariable`.

4. **`test/pipeline_test.rb`** (existing, extended)
   - End-to-end: `point_distance.rb` round-trips through
     `Pipeline.default` and the resulting iseq reloads via
     `InstructionSequence.load_from_binary`.

5. **`optimizer/examples/point_distance.rb`** (new fixture)
   - Smoke-tested through the ruby-bytecode MCP tools.

No benchmark asserts in the suite; benchmark numbers for the talk
are driven separately via the MCP `benchmark_ips` tool, same
pattern as the ArithReassoc work.

## Future work (explicitly deferred)

- **`Math.sqrt` wrap around the body** to make `distance_to` return
  a proper Euclidean distance. Needs: nested-send inlining or a
  `SAFE_STDLIB_SENDS` allowlist; `Math` isn't an instance method so
  constructor-prop doesn't help. Not blocking v1. File as a
  follow-up once v1 lands.
- **IdentityElim / ArithReassoc upgrade to RBS-typed operands.**
  Changes "sound in practice" to "sound in principle" for the
  numeric demo. Self-contained follow-ups; feeds on v1's
  `SlotTypeTable`.
- **Multi-arg OPT_SEND (argc ≥ 2).** Needed for any demo richer
  than `distance_to`. Same LINDEX-remap machinery as v3, generalized.
- **Callee-internal locals.** Bodies like `def foo(x); y = x+1; y*2; end`
  need one stash slot per intermediate local, in addition to the
  self-stash and arg-stash v1 already grows.
- **Constructor-prop for `X.new` inside blocks / conditionals.** v1
  only scans the current function's straight-line stream. Anything
  defined via branching assignment stays `:unknown`.
- **Subtype matching.** `Array[Integer]` vs `Array` and `Integer` vs
  `Numeric` both fail v1's string-equality check.

## Maintenance

On completion, strike roadmap item #1 in `docs/TODO.md` and update
the three-pass-status table's Inlining row with the v3 capability.
