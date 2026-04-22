# Const-fold Tier 2 — frozen top-level constants

Status: approved (2026-04-26)
Owner: Samuel Giddins

## Motivation

The talk names four const-fold tiers. Tier 1 (literal-on-literal) and
Tier 4 (ENV) are shipped; Tier 2 (frozen top-level constants) has been
the missing narrative beat. With Tier 2 in place, the "four tiers"
story is coherent even before the RBS-typed Tier 3 lands.

Concrete payoff: `FOO = 42; def f; FOO + 1; end` — Tier 2 rewrites
`opt_getconstant_path FOO → putobject 42`, then Tier 1 (`ConstFoldPass`)
folds `42 + 1 → 43`. Cascades through the pipeline in a single run.

## Scope v1

**In.** Top-level bare constants whose RHS is a recognizable literal
producer: `putobject`, `putchilledstring`, `putstring`, `putnil`,
`putobject_INT2FIX_0_`, `putobject_INT2FIX_1_`. Foldable value types:
Integer (bit_length<62), String, true, false, nil — the `intern` ceiling.

**Out.** Nested assignments (`M::FOO = ...`), dup-flavored assignments
(module-body tail), non-literal RHS, frozen Array/Hash/Symbol literals,
reassignment-in-any-scope. Each is conservatively a "taint" that removes
the constant from the fold table.

## Opcode shapes (confirmed via `disasm` 2026-04-26)

**Top-level assignment.** Exactly three instructions at positions
`i-2, i-1, i`:

```
<literal-producer>        # e.g. putobject N / putchilledstring N / ...
putspecialobject 3
setconstant :NAME
```

The `putspecialobject 3` operand is the `cbase` sentinel; we match on
opcode + operand `== 3`. `setconstant` carries the Symbol-name ID in
operand[0] — that index resolves to `:NAME` via the object table.

**Nested / module-body assignment.** Contains a `dup` between value and
`putspecialobject`:

```
<literal>
dup
putspecialobject 3
setconstant :NESTED
```

…or the cbase is produced by a different opcode (`opt_getconstant_path`
for `M::FOO = ...`). Either way we decline to admit this to the table,
and we *also* mark the name tainted so a read site can't accidentally
fold based on some other assignment to the same name elsewhere.

**Read site.** `opt_getconstant_path <idx>` where `object_table[idx]` is
a T_ARRAY of symbol-name indices. Fold only when the array has exactly
one element and that element resolves to a name in our fold table.

## Algorithm

Mirror `ConstFoldEnvPass`'s whole-tree pre-scan shape.

1. `tree_root(function)` memoizes `@root ||= function`. `misc` on the
   root carries `:const_fold_tier2_scanned` (one-shot) and
   `:const_fold_tier2_table` (the collected table).

2. **Scan.** Walk every function in the tree. For each `setconstant`
   instruction, classify:
   - `top_level_literal`: the two preceding instructions are
     `<literal-producer>; putspecialobject 3`, and the literal reads
     to a `intern`-able value. Admit `(name → value)` — unless `name`
     is already present with a different value or already tainted, in
     which case taint.
   - anything else (`dup` present, non-literal RHS, nested, shadow):
     taint `name`.

   "Taint" = remove from the fold table AND record in a tainted-names
   set so a later scan-order occurrence cannot re-admit.

3. **Fold.** Per-function, walk instructions. For each
   `opt_getconstant_path`, decode the path; if it's a single-element
   array whose symbol is in the fold table (and not tainted), splice
   the single instruction to a literal producer.

Emission:
- Integer / true / false / nil → `LiteralValue.emit`.
- String → `putobject <intern(value)>` (matches `ConstFoldEnvPass`
  pattern; frozen strings fit `putobject` semantics).

## Logging

- `reason: :folded` — each successful rewrite.
- `reason: :reassigned` — constant seen with 2+ assignments (distinct
  values or non-literal). One entry per tainted name.
- `reason: :non_literal_rhs` — an admittable shape except RHS isn't a
  literal producer.
- `reason: :non_top_level` — nested/module-body/dup-flavored shapes.

Log entries are informational; the narrative value is showing "we saw
`FOO` reassigned and declined to fold." No `:pass_raised` required —
the pass never raises in v1.

## Pipeline placement

Insert **before** `ConstFoldEnvPass` and `ConstFoldPass`:

```
Inlining, ArithReassoc, ConstFoldTier2, ConstFoldEnv, ConstFold, IdentityElim
```

Tier 2 rewrites to literals; Tier 1 then folds arithmetic around them.
Tier 2 before Tier 4 so a constant that happens to name `ENV` (impossible
but free) or that feeds into an ENV fold site is resolved first —
practically, ordering among the two is irrelevant because they match
disjoint opcodes. Before-Tier-1 is the load-bearing order.

## Risks / non-goals

- **Object identity of frozen strings.** `FOO = "hello"` and reads of
  `FOO` in pre-fold Ruby all return the *same* frozen String object.
  Our fold emits `putobject <idx>` against a single interned copy — so
  identity is preserved by construction (same object_table entry).
- **Per-file vs cross-file.** We scan the *IR tree* we were given. A
  constant assigned in another file is invisible. That's the intended
  scope: we fold only what we can prove from the current iseq tree.
- **Class/module body constants.** Constants inside a class or module
  body reach `setconstant` with a `dup` (the body's tail-expression
  shape). We skip these in v1; extending requires matching the
  `dup; putspecialobject 3; setconstant` 3-tuple *and* verifying the
  read site is inside the same module's lexical scope, which needs a
  scope model we don't have.
- **Symbol values.** `FOO = :bar` would require `intern` support for
  Symbols. Defer — same shape as the Array/Hash deferral.

## Tests

TDD:

1. Red — `FOO = 42; def f; FOO; end`: `f`'s instructions before the
   pass include `opt_getconstant_path`; after, `putobject 42` or
   `putobject_INT2FIX_*`.
2. String fold — `BAR = "hello"; def g; BAR; end`.
3. Cascade through `ConstFoldPass` — `FOO = 42; def f; FOO + 1; end`
   end-to-end via `Pipeline.default.run`, assert `43` appears.
4. Reassignment taint — `FOO = 1; FOO = 2; def f; FOO; end` → no fold,
   one `:reassigned` log.
5. Non-literal RHS — `FOO = some_method; def f; FOO; end` → no fold.
6. Nested path non-fold — `module M; NESTED = 99; end; def h; M::NESTED; end` →
   no fold (path length 2, AND `:NESTED` is tainted because of the
   module-body `dup` shape).
7. Pipeline placement smoke — run `Pipeline.default`; assert the
   cascade test produces the expected fold count.
