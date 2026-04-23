# Spec: Optimizer Core

**Part of:** [Ruby the Hard Way](2026-04-19-talk-structure-design.md)
**Related:** [Harness](2026-04-19-harness.md), passes:
[inlining](2026-04-19-pass-inlining.md),
[arith](2026-04-19-pass-arith-specialization.md),
[const-fold](2026-04-19-pass-const-fold.md)

## Purpose

The core defines the IR that passes operate on, the type environment
they consult, the contract they assume, and the orchestration that
runs them in sequence over an iseq.

## Pipeline

```
iseq  ──►  IR (CFG of basic blocks)  ──►  passes ──►  IR  ──►  iseq
                                  ▲
                                  │
                          type environment (from RBS)
                                  │
                             the contract
```

Input and output are both YARV iseqs. The IR is a lossless
round-trippable representation at CFG granularity. Not SSA — passes
work on linear instructions within each basic block plus the CFG
edges.

## IR shape

- **Function** = one iseq (a method, block, or top-level)
- **Basic block** = a maximal straight-line sequence of YARV
  instructions with one entry and one exit (branch, return, or
  fallthrough)
- **CFG** = directed graph of basic blocks with edge kinds
  (fall-through, conditional true, conditional false, unconditional)
- **Instruction** = a struct wrapping a YARV opcode + operands, with
  back-reference to the source location
- **Locals table** = preserved from the original iseq; passes may
  allocate new slots during transformations (notably inlining)

Each IR function also carries:
- The original iseq (for round-tripping unchanged regions)
- A reference to the enclosing type environment
- A log buffer (see "Logging" below)

## The contract

Hardcoded. Using the optimizer means accepting all of:

1. **No core basic-operation redefinition** — `Integer#+`, `Array#[]`,
   `String#==`, etc. are the definitions the language ships with
2. **No `prepend` into any class after load** — method tables don't
   shift under our feet
3. **Inline `@rbs` signatures are truthful** — if you say `(Integer,
   Integer) -> Integer`, that's what shows up at runtime
4. **ENV is read-only after load** — enables `ENV["X"]` folding (see
   const-fold pass)
5. **Top-level constants are not reassigned and `const_set` is not
   used after load** — enables treating assigned-once constants as
   literals (see const-fold tier 2)

Breaking any of these is a miscompile, not a slowdown. We say so on
the contract slide and we mean it.

## Type environment

Built from inline `@rbs` comments parsed by the harness. Exposes:

- `signature_for(receiver_class, method_name)` → return type, arg
  types (or nil if no signature)
- `class_of(local_or_constant)` → class, if derivable from signatures
  or from literal form
- `resolve_call(receiver_expr, method_name)` → iseq of the callee, if
  uniquely resolvable

Passes that can't get what they need from the type env log the reason
and skip the transformation.

## Pass pipeline

Fixed order, run once each (no iteration to fixpoint, to keep the
scope small):

1. **Inlining** — expands call sites, grows the CFG
2. **Arithmetic specialization** — exploits known-Integer arithmetic
3. **Constant folding** — folds everything foldable, including things
   only exposed by the previous two passes

The order matters: inlining exposes new const-fold opportunities
(constants from the callee), and arith specialization's reassociation
exposes new literal subexpressions. Const-fold last picks those up.

## Logging

Every "I could have optimized this but didn't" decision is logged with:

- Source location (file, line)
- Pass name
- Reason (e.g. `receiver_not_uniquely_resolvable`,
  `callee_over_size_budget`, `type_mismatch`)

The log is available as a structured object per file. The talk uses
it to show the audience what the optimizer saw and why it gave up —
"the optimizer tells you why it didn't optimize" is itself a feature
of the demo.

## Round-tripping

IR → iseq must produce something the VM will accept. Ruby 4.0.2
(confirmed empirically, 2026-04-19) does not expose an assembler:
`to_a` is a read-only view, `.load` is a disabled stub, and there is
no public entry that ingests a modified array. The only path in is
`RubyVM::InstructionSequence.load_from_binary`, which accepts the
`YARB`-magic packed binary format produced by `to_binary`.

Consequence: the round-trip goes **iseq → `.to_binary` → our binary
decoder → IR → passes → IR → our binary encoder → `load_from_binary`
→ iseq**. The binary format is private and version-specific. Our
codec lives in a single isolated module (`optimize/codec/`) and is
not shown in the talk — the audience sees the IR and the passes; the
codec is acknowledged as "we did the brittle part for you."

The codec must:

- Preserve iseq metadata (arg shape, local table layout,
  catch-table entries) that isn't being transformed
- Adjust stack-depth annotations (`stack_max`) when instruction
  counts change
- Preserve line numbers where we can, synthesize where we can't
- Be version-gated: the binary format changes with Ruby minor
  releases. We target exactly the Ruby version the talk runs on
  (4.0.2) and fail loudly on mismatch.

The codec is validated by an identity round-trip test: for a corpus
of iseqs produced by `compile`, `decode(encode(decode(to_binary)))`
must produce a binary byte-identical to the original. Transformations
layer on top of this identity foundation.

The optimizer punts on any construct the codec can't round-trip
(catch tables with complex handlers, for instance). Those iseqs are
returned unchanged and logged.

## Not in scope

- SSA or any dataflow form beyond local in-block analysis
- Iterating passes to fixpoint
- Interprocedural analysis beyond the direct call-graph walk inlining
  needs
- Speculative optimizations with deoptimization guards (too much VM
  surgery for 600 LOC)
