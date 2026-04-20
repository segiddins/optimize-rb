# Spec: Arithmetic Reassociation Pass — v1 (literal-only, opt_plus)

**Part of:** [Ruby the Hard Way](2026-04-19-talk-structure-design.md)
**Refines:** [Arithmetic Specialization](2026-04-19-pass-arith-specialization.md) — this doc is the first-plan subset of that larger spec.
**Depends on:** `ConstFoldPass` tier 1 (already shipped), `LiteralValue` helper, `ObjectTable#intern`, `IR::CFG.compute_leaders`.

## Purpose

Reach the shape `ConstFoldPass` cannot: a chain of `+` operations where a non-literal operand splits the literals apart. Demonstrate assumption-driven integer folding on a single, self-contained slide.

```ruby
x + 1 + 2 + 3
# compiles to:
#   getlocal x; putobject 1; opt_plus; putobject 2; opt_plus; putobject 3; opt_plus
# ConstFoldPass: no all-literal triple anywhere → no fold.
# ArithReassocPass v1: collapses to `x + 6`.
```

## Scope

Exactly one transformation: within a single basic block, collapse an `opt_plus` chain whose operand producers are each single instructions, where ≥2 of those operand producers are Integer literals.

### Explicitly in

- `opt_plus` only.
- Chains whose operand-producing instructions are each in a fixed allowlist of "pushes exactly one value, pops zero, no side effects relevant to reordering":
  - All `LiteralValue::LITERAL_OPCODES` (`putobject`, `putobject_INT2FIX_0_`, `putobject_INT2FIX_1_`, `putchilledstring`, `putstring`, `putnil`)
  - `getlocal`, `getlocal_WC_0`, `getlocal_WC_1`
  - `getinstancevariable`, `getclassvariable`, `getglobal`
  - `putself`
- Reassociation output: non-literal operands kept in **original positional order**, followed by one combined-literal operand, followed by `n-1` `opt_plus` instructions (where `n` is the operand count).
- Reassociation fires only when every literal operand in the chain is an `Integer`.
- Chain boundaries respect basic blocks: any instruction index in `IR::CFG.compute_leaders` other than the chain's own start is a hard chain-breaker.

### Explicitly out (deferred to follow-up plans)

- `opt_mult` (mechanical repeat of the same chain helper).
- `opt_minus`, `opt_div`, `opt_mod` (need identity insertion or inverse handling).
- Multi-instruction operand producers (calls, nested expressions, any sub-sequence with net stack delta > +1 or with side effects).
- Cross-block chains (require CFG-directed traversal).
- RBS-driven type env — no typing of non-literal operands at all in v1.
- Inlining-driven chain exposure.
- Tracking `"folded"` / `"reassociated"` counts as a rich log structure; v1 reuses `Log#skip` with new reason tags, matching the const-fold convention.

## Algorithm

**Chain detection (Option (a) from brainstorming).** A chain of `n` operand producers (`n ≥ 2`) terminating at an `opt_plus` at index `i` occupies indices `[i-(2n-2) .. i]` with this layout:

```
  i-(2n-2)   producer_1   (SINGLE_PUSH_OPERAND_OPCODES)
  i-(2n-3)   producer_2   (SINGLE_PUSH_OPERAND_OPCODES)
  i-(2n-4)   opt_plus
  i-(2n-5)   producer_3   (SINGLE_PUSH_OPERAND_OPCODES)
  i-(2n-6)   opt_plus
  ...
  i-1        producer_n   (SINGLE_PUSH_OPERAND_OPCODES)
  i          opt_plus
```

Algorithm: forward scan `function.instructions`. When `insts[i].opcode == :opt_plus`, walk backward from `i-1`:

1. `insts[i-1]` must be in `SINGLE_PUSH_OPERAND_OPCODES`; if not, `i` is not a chain tail — advance.
2. Walk backward in `(opt_plus, producer)` pairs: check `insts[i-2]` is `opt_plus` and `insts[i-3]` is a single-push producer. Keep extending `n` as long as both hold.
3. When the pair pattern breaks (either `insts[j]` isn't `opt_plus` or `insts[j-1]` isn't a single-push producer): the chain's first producer is `insts[j+1]`, and the chain's second producer is `insts[j+2]`. Require that `insts[j+1]` and `insts[j+2]` are *both* single-push producers (they should be by construction — 2 is the chain's minimum `n`).
4. Leader check: for every index in the chain *other than the chain's first producer*, that index must NOT be in `IR::CFG.compute_leaders(insts)`. (The chain's first producer may itself be a leader — that's fine, it's the chain's entry.) If any intermediate index is a leader, shrink the chain by lopping everything up to and including that leader from the front.

If after leader-shrinking `n < 2`, there is no chain ending at `i`; advance.

**Reassociation rewrite.** Once a chain of `n` operand producers is identified:

- Read each producer via `LiteralValue.read`; classify as literal-integer, non-integer-literal, or non-literal.
- If any literal is **not** Integer → log `:mixed_literal_types`, skip the chain (do not rewrite).
- Let `L` = list of literal-integer values (preserving chain order is unnecessary — addition is commutative). Let `N` = list of non-literal operand-producer instructions in original chain order.
- If `L.size < 2` → log `:chain_too_short`, skip.
- Sum `L` to a single `Integer`; emit via `LiteralValue.emit(sum, line: <line>, object_table:)`. Line inherits from the chain's first `opt_plus` (matches const-fold's "line of the operation that disappeared" convention).
- Build replacement: `N[0], N[1], ..., N[m-1], <literal-sum>, opt_plus × (n-1)`. Each `opt_plus` inherits its `line` from the corresponding original `opt_plus` in chain order (so disassembly still shows sensible source lines; any leftover `opt_plus`es beyond `n-1` don't exist, since `n` operands = `n-1` opt_pluses).
- Replace `insts[first_producer_idx, chain_length] = replacement`.
- Log `:reassociated`.
- Resume the forward scan at `first_producer_idx` (the replacement's start) so any enclosing chain that ends at a later `opt_plus` still gets a chance to match.

**Fixpoint.** Wrap the forward scan in an outer `loop` matching const-fold's shape: break when no chain is rewritten in a full pass. Termination: an input chain of `n` producers occupies `2n-1` instructions; output is `(m+1)` producers and `m` opt_pluses = `2m+1` instructions, where `m = |N|` (non-literal count). Reassoc only fires when `|L| ≥ 2`, so `m+1 ≤ n-1 < n`, i.e. `2m+1 ≤ 2n-3 < 2n-1`. Each rewrite strictly decreases `insts.size` by at least 2.

**Pipeline ordering.** Default pipeline becomes `[ArithReassocPass.new, ConstFoldPass.new]`. Arith runs first so that if its output produces an all-literal adjacent triple (can happen in edge cases like chain = `[1, 2, x, 3, 4]` → arith rewrites to `x + 10` with no residual triples, OR if arith produces a tail that's `<lit>, <lit>, opt_plus`, const-fold catches it).

## Logging

Reuse `Log#skip(pass:, reason:, file:, line:)` with these reasons:

- `:reassociated` — success, one entry per chain rewritten.
- `:mixed_literal_types` — chain contained at least one non-Integer literal; chain left alone.
- `:chain_too_short` — chain detected with < 2 integer literals; chain left alone (common case, may get noisy — acceptable for v1).

Pass name: `:arith_reassoc`.

## Interface

```ruby
class RubyOpt::Passes::ArithReassocPass < RubyOpt::Pass
  def name = :arith_reassoc
  def apply(function, type_env:, log:, object_table: nil)
end
```

`type_env` is accepted for interface compatibility but ignored in v1.

## Files

```
optimizer/
  lib/ruby_opt/
    passes/
      arith_reassoc_pass.rb           # NEW — the pass
    pipeline.rb                       # MODIFIED — default pipeline adds arith before const-fold
  test/
    passes/
      arith_reassoc_pass_test.rb      # NEW — unit + end-to-end
      arith_reassoc_pass_corpus_test.rb  # NEW — corpus regression under updated default pipeline
```

## Test strategy

Mirror const-fold tier 1:

1. **Unit tests** on the pass in isolation, with hand-built IR fixtures and real `RubyVM::InstructionSequence.compile` → `Codec.decode` inputs.
2. **End-to-end:** after `apply`, round-trip through `Codec.encode` + `InstructionSequence.load_from_binary` and `.eval`; result must equal the un-optimized output.
3. **Corpus regression:** every file under `optimizer/test/codec/corpus/*.rb` survives the updated default pipeline (decode → `Pipeline.default.run` → encode → `load_from_binary`).

Critical fixtures:

- `x + 1 + 2 + 3` with `x = 10` → `16`, output contains a literal `6`, single `getlocal` followed by one `opt_plus`... wait: output is `getlocal x; putobject 6; opt_plus`, one `opt_plus`.
- `1 + x + 2` → `x + 3`; operand order: non-literals first, literal-sum tail.
- `1 + x + 2 + y + 3` → `x + y + 6`; multiple non-literals preserve order.
- `x + 1 + 2` where `x = "str"` → should raise `TypeError` at runtime; but arith still rewrites (we assume no redef + Integer literals → the BOP-no-redef rule says it's still safe to reassociate; the TypeError will surface at the single remaining `+`, not a semantic change since the original would also raise). **Covered with a test that asserts both original and optimized raise `TypeError` equivalently.**
- `x + 1.5 + 2` (mixed Float + Integer literal) → `:mixed_literal_types` log, chain left alone.
- `x + "a" + "b"` (string literals in the chain) → `:mixed_literal_types`, chain left alone.
- Chain crossed by a branch target → chain-breaker respected; no rewrite beyond the leader.
- Chain of length 2 with one literal (`x + 1`) → `:chain_too_short`, no rewrite (nothing to gain; rewriting would be a no-op).
- Chain of length 3 with only one literal (`x + y + 1`) → `:chain_too_short`.
- Multiple independent chains in one basic block → each rewritten independently.
- Empty / short function (no opt_plus) → no-op, no log entries.

## Interaction with const-fold

Const-fold remains last in the pipeline. Any residual all-literal adjacency in arith's output (e.g., `putobject A; putobject B; opt_plus` fragments) gets collapsed by const-fold's existing triple scan on the same run. In practice, arith's output puts the single literal tail *adjacent* to one non-literal and one `opt_plus`, so there's rarely anything for const-fold to find — but the ordering preserves correctness in the rare case.

## Not changing

- `Pass#apply` signature — already accepts `type_env:, log:, object_table:` from const-fold tier 1.
- `Pipeline#run` — already threads `object_table` through.
- `LiteralValue` / `ObjectTable#intern` — unchanged.
- No shared "pass iteration base class" — arith's outer fixpoint is different enough in shape (chain-sized strides, not triple-sized) that a shared helper would either over-fit or under-fit. Defer.

## Success criteria

1. All existing 107 tests remain green.
2. New unit tests green: chain detection, literal-only rewrite, mixed-type skip, chain-too-short skip, leader-crossing skip.
3. End-to-end: every fixture round-trips through `Codec.encode` → `load_from_binary` → `.eval`, producing a result equal to the un-optimized output.
4. Corpus regression: every `test/codec/corpus/*.rb` fixture survives `Pipeline.default.run`.
5. Disassembly slide: `x + 1 + 2 + 3 + 4` on a method boundary, before vs. after, shows the chain collapsing to `getlocal; putobject 10; opt_plus; leave`.
