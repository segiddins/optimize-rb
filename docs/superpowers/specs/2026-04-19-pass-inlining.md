# Spec: Inlining Pass

**Part of:** [Ruby the Hard Way](2026-04-19-talk-structure-design.md)
**Depends on:** [Optimizer core](2026-04-19-optimizer.md)

## Purpose

Replace a `send` instruction with the callee's body, eliminating the
call frame, the method lookup, and (importantly for the demos) a layer
of the stack trace.

Inlining is the enabling pass: it exposes constants, literal
arithmetic, and identities that the other two passes can then fold.

## Preconditions

A call site is inlinable iff:

1. **Receiver class resolves uniquely** — either via an RBS signature on
   the caller, a literal receiver (`1.foo`, `"x".foo`), or a
   single-definition method name in the loaded program
2. **Callee iseq is available** — we can reach it through the type
   environment's `resolve_call`
3. **Callee size is under the budget** — threshold TBD; a small ceiling
   like 20 instructions keeps the demos readable
4. **Callee doesn't use constructs we can't splice** — `super`,
   explicit `return` from a block the caller doesn't own, `break`/`next`
   targeting a frame we're about to erase. These are logged and
   skipped.

Otherwise: log reason, leave the call site alone.

## Transformations

### Standard inlining

Replace the `send` with the callee's basic blocks, wired into the
caller's CFG:

- Allocate fresh local slots for the callee's locals
- Map callee arg positions to pre-send stack values (or to the new
  local slots after a `setlocal`)
- Rewrite callee `leave` instructions to jumps to the block that
  follows the original call site
- Map callee `getlocal`/`setlocal` indices to the new slots
- Splice the callee's basic blocks into the caller's CFG

### Wrapper-method flattening

A common special case worth a dedicated code path in the demo. A
"wrapper" method looks like:

```ruby
def foo(x)
  bar(x) { yield }   # or any single pass-through call
end
```

When a caller `obj.foo(v) { ... }` is inlined:

- `foo`'s single call site becomes the caller's direct call to `bar`
- The caller's block is threaded straight through to `bar`
- `foo` disappears from the resulting iseq — and from backtraces

This is the pass's most visible win for object-y code, and makes for
a great before/after demo (two `caller` prints, same program).

## Failure behavior

Per precondition above, each unmet condition logs a structured reason
and returns the call site unchanged. The pass never raises on a
failed inline; it just leaves the site alone and moves on.

## Demo opportunities

- Numeric kernel: inlining exposes a chain of arithmetic that the
  arith pass then collapses
- Object-y method (e.g. `Point#distance_to` calling
  `Math.sqrt(dx*dx + dy*dy)`): inlining the arithmetic helper methods
  flattens the whole computation
- Wrapper flattening: a `def logged_call(x); log_entry; result = real_call(x); log_exit; result; end`
  style wrapper, inlined, disappears from the backtrace entirely

## Not in scope

- Recursive inlining (inlining the inlined code's own calls); pipeline
  runs each pass once
- Polymorphic inlining (multiple possible receiver classes)
- Inlining across `Module` boundaries the type env can't see
- Cost-model heuristics beyond a flat size budget
