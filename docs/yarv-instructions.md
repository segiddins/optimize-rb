# YARV Instruction Reference

> Source: [`insns.def`](https://github.com/ruby/ruby/blob/master/insns.def) from
> [ruby/ruby](https://github.com/ruby/ruby) at commit
> `8f02f644eb5e021b3138b028b4292617650b614a` (2026-04-18).
> `include/ruby/version.h` declares `RUBY_API_VERSION 4.1.0`, i.e. this
> corresponds to the in-development Ruby 3.5+ line on master
> (`RUBY_VERSION_TEENY 0`). Regenerate when Ruby cuts a new version.

## What YARV is

YARV ("Yet Another Ruby VM") is the stack-based bytecode interpreter introduced
by Koichi Sasada in Ruby 1.9 and still CRuby's primary execution engine. A
Ruby method, block, class body, or top-level script compiles to an
`RubyVM::InstructionSequence` (an *iseq*): a flat sequence of instructions plus
per-call caches, constant caches, inline variable caches, exception tables, and
local-variable metadata.

Each instruction pops zero or more values from the VM stack, optionally reads
*operands* from the instruction stream, does work, and pushes zero or more
values. There is no register file: everything flows through the operand stack
and a per-frame environment pointer (`EP`) that holds locals and specials.

### `insns.def`

`insns.def` is the canonical, pseudo-C definition file. The CRuby build
generates `vm.inc`, opcode tables, the disassembler, and tooling from it via
the ERB templates under `tool/ruby_vm/`. Each entry looks like:

```
DEFINE_INSN
instruction_name
(type operand, ...)       // operands read from the bytecode stream
(pop_values, ...)         // values popped from the stack (left = deeper)
(return_values, ...)      // values pushed (left = pushed first)
// attr ... pragmas (sp_inc, leaf, handles_sp, ...)
{
    /* C body */
}
```

`DEFINE_INSN_IF(cond)` gates an instruction on a build flag (stack-caching,
joke instructions). The stack notation `(...)` means "variadic" — the real
stack delta is computed by an `sp_inc` attribute.

### Operand types

From `tool/ruby_vm/models/typemap.rb`:

| Type         | Meaning                                                  |
|--------------|----------------------------------------------------------|
| `VALUE`      | Any Ruby object reference                                |
| `ID`         | Interned symbol (method / ivar / gvar name)              |
| `ISEQ`       | Pointer to a child `rb_iseq_t`                           |
| `CALL_DATA`  | `rb_call_data` — call-info + inline method cache         |
| `IC`         | Inline constant cache                                    |
| `IVC`        | Inline instance-variable cache                           |
| `ICVARC`     | Inline class-variable cache                              |
| `ISE`        | Inline storage entry (used by `once`)                    |
| `CDHASH`     | Hash used by `opt_case_dispatch`                         |
| `OFFSET`     | Signed PC-relative branch offset                         |
| `rb_num_t`   | Unsigned machine-word integer immediate                  |
| `lindex_t`   | Local-variable slot index                                |
| `RB_BUILTIN` | Built-in C function pointer                              |
| `...`        | Variadic popped/pushed list                              |

### Instruction counts

110 `DEFINE_INSN` entries are enabled by default (plus 2 joke insns —
`bitblt`, `answer` — gated on `SUPPORT_JOKE`, and `reput` gated on
`STACK_CACHING`, which is off in default builds).

---

## Variable access

### Locals / block params

| Insn | Operands | Pops → Pushes | Description |
|------|----------|---------------|-------------|
| `getlocal`  | `idx`, `level` | — → val | Load local `idx` from the env `level` frames up |
| `setlocal`  | `idx`, `level` | val → — | Store TOS into local `idx` at `level` up |
| `getblockparam` | `idx`, `level` | — → blk | Load the block parameter, creating the `Proc` on first read |
| `setblockparam` | `idx`, `level` | val → — | Assign a new value to a `&blk` parameter slot |
| `getblockparamproxy` | `idx`, `level` | — → proxy | Load a lightweight proxy that only implements `call`; avoids `Proc` allocation for `yield`-like use |

### Specials ($~, $_, flip-flops)

| Insn | Operands | Pops → Pushes | Description |
|------|----------|---------------|-------------|
| `getspecial` | `key`, `type` | — → val | Read `$~`/`$_`/back-refs or flip-flop state |
| `setspecial` | `key` | val → — | Write a special variable (used for flip-flop state) |

### Instance / class / global variables

| Insn | Operands | Pops → Pushes | Description |
|------|----------|---------------|-------------|
| `getinstancevariable` | `id`, `IVC ic` | — → val | Read `@id` from `self` using an inline shape cache |
| `setinstancevariable` | `id`, `IVC ic` | val → — | Write `@id` on `self` using the inline cache |
| `getclassvariable`    | `id`, `ICVARC ic` | — → val | Read `@@id` with inline cache (toplevel warns) |
| `setclassvariable`    | `id`, `ICVARC ic` | val → — | Write `@@id` with inline cache |
| `getconstant`         | `id` | klass, allow\_nil → val | Dynamic constant lookup (honors autoload); `klass = nil, allow_nil = true` means unscoped lookup |
| `setconstant`         | `id` | val, cbase → — | Assign `cbase::id = val` |
| `opt_getconstant_path` | `IC ic` | — → val | Fused lookup for a full `A::B::C` path with inline cache invalidation; the JIT-friendly replacement for old `getinlinecache`/`setinlinecache` + `getconstant` chains |
| `getglobal` | `gid` | — → val | Read global `$gid` |
| `setglobal` | `gid` | val → — | Write global `$gid` |

---

## Putting literal values on the stack

| Insn | Operands | Pops → Pushes | Description |
|------|----------|---------------|-------------|
| `putnil`   | —   | — → nil       | Push `nil` |
| `putself`  | —   | — → self      | Push the current `self` |
| `putobject` | `val` | — → val     | Push an embedded, immutable literal (Integer, Symbol, true/false, frozen small obj) |
| `putspecialobject` | `value_type` | — → obj | Push a VM-internal singleton: `VMCORE`, `CBASE`, or `CONST_BASE` (used by `define_method`, `defined?`, etc.) |
| `putstring` | `str` | — → copy | Push a fresh `String` copy of the literal |
| `putchilledstring` | `str` | — → copy | Same, but the copy is "chilled" — will become frozen in a future Ruby; mutations warn |

### String / Regexp / Symbol construction

| Insn | Operands | Pops → Pushes | Description |
|------|----------|---------------|-------------|
| `concatstrings` | `num` | num strs → str | Concatenate `num` strings (interpolation) |
| `anytostring`   | —     | val, str → str | If `val` is not a `String`, call `rb_any_to_s`; used inside interpolation after `objtostring` miss |
| `toregexp`      | `opt`, `cnt` | cnt strs → regexp | Build a `Regexp` from `cnt` pieces with options `opt` |
| `intern`        | —     | str → sym      | `str.to_sym` (used by dynamic symbols `:"#{x}"`) |

---

## Arrays, hashes, ranges

| Insn | Operands | Pops → Pushes | Description |
|------|----------|---------------|-------------|
| `newarray` | `num` | num vals → ary | Build an array from the top `num` stack slots |
| `pushtoarraykwsplat` | — | ary, hash → ary | Push `hash` onto `ary` unless `hash` is empty; used for `[..., **h]` |
| `duparray` | `ary` | — → dup | Push a shallow copy of a literal array |
| `duphash`  | `hash` | — → dup | Push a shallow copy of a literal hash |
| `expandarray` | `num`, `flag` | ary → num vals (+rest) | Multiple assignment / destructuring; `flag` encodes splat position and post-count |
| `concatarray` | — | a1, a2 → a | `a1 + a2` without mutating `a1` (splat calls) |
| `concattoarray` | — | a1, a2 → a1 | Append `a2` into `a1` in place |
| `pushtoarray` | `num` | ary, v1..vN → ary | Push `num` values onto the array in place |
| `splatarray` | `flag` | ary → new\_ary | `ary.to_a`; `flag` chooses whether to always dup |
| `splatkw` | — | hash, block → hash, block | `hash.to_hash`; used when `**h` appears before a block |
| `newhash` | `num` | 2*num vals → hash | Build a hash from `num` key/value pairs |
| `newrange` | `flag` | low, high → range | `Range.new(low, high, flag)`; `flag` is exclusive-end bit |

---

## Stack manipulation

| Insn | Operands | Pops → Pushes | Description |
|------|----------|---------------|-------------|
| `pop`   | — | val → — | Discard TOS |
| `dup`   | — | val → val, val | Duplicate TOS |
| `dupn`  | `n` | top-n → top-n, top-n | Duplicate the top `n` values as a block |
| `swap`  | — | a, b → b, a | Swap top two values |
| `opt_reverse` | `n` | top-n → reversed | Reverse the top `n` values (used for multiple return values) |
| `topn`  | `n` | — → stack\[sp-n-1] | Push the N-th element from the top |
| `setn`  | `n` | ..., val → ..., val | Write TOS into the N-th stack slot, leaving TOS alone |
| `adjuststack` | `n` | n values → — | Pop `n` values (bulk `pop`) |
| `reput` | — | val → val | *(`STACK_CACHING` builds only)* stack-cache shuffler |

---

## Defined / type / match checks

| Insn | Operands | Pops → Pushes | Description |
|------|----------|---------------|-------------|
| `defined`   | `op_type`, `obj`, `pushval` | v → result | Implements `defined? expr` for most expression kinds; pushes `pushval` or `nil` |
| `definedivar` | `id`, `IVC ic`, `pushval` | — → result | Specialized `defined? @ivar` with inline cache |
| `checkmatch` | `flag` | target, pattern → bool | `pattern === target` with rescue/case/when semantics (`flag` = type + array bit) |
| `checkkeyword` | `kw_bits_index`, `keyword_index` | — → bool | In keyword-arg prologue: was keyword `keyword_index` passed? |
| `checktype` | `type` | val → bool | `RB_TYPE_P(val, type)`; used for pattern matching and fast-path guards |

---

## Class / method definition

| Insn | Operands | Pops → Pushes | Description |
|------|----------|---------------|-------------|
| `defineclass`   | `id`, `class_iseq`, `flags` | cbase, super → ret | Enter class/module/sclass body; `flags` encodes class vs module vs `class <<`, scoped-cbase, has-super |
| `definemethod`  | `id`, `iseq` | — → — | `def id ...` on current class scope |
| `definesmethod` | `id`, `iseq` | obj → — | `def obj.id ...` (singleton method definition) |

---

## Method dispatch

### Regular calls

| Insn | Operands | Pops → Pushes | Description |
|------|----------|---------------|-------------|
| `send` | `CALL_DATA cd`, `ISEQ blockiseq` | recv, args... → val | General call site; `blockiseq` is `NULL` unless a literal `{ ... }` / `do...end` block is attached |
| `sendforward` | `CALL_DATA cd`, `ISEQ blockiseq` | recv, args... → val | Call via an `...` forwarded-arguments forwarder |
| `opt_send_without_block` | `CALL_DATA cd` | recv, args... → val | Hot path: `send` specialized for "no block attached" |
| `opt_new` | `CALL_DATA cd`, `OFFSET dst` | — → — | Fast path for `Class.new` when the user has not overridden `new` |
| `objtostring` | `CALL_DATA cd` | recv → str | Call `to_s` if `recv` isn't already a `String`; paired with `anytostring` for interpolation |
| `opt_ary_freeze`  | `ary`, `CALL_DATA cd`  | — → val | `[...].freeze` literal |
| `opt_hash_freeze` | `hash`, `CALL_DATA cd` | — → val | `{...}.freeze` literal |
| `opt_str_freeze`  | `str`, `CALL_DATA cd`  | — → val | `"..."` .freeze` literal |
| `opt_nil_p`       | `CALL_DATA cd` | recv → bool | Specialized `x.nil?` |
| `opt_str_uminus`  | `str`, `CALL_DATA cd` | — → val | `-"literal"` — fetch the fstring singleton |
| `opt_duparray_send` | `ary`, `method`, `argc` | args... → val | `[...].include?(x)` on a literal array without allocating |
| `opt_newarray_send` | `num`, `method` | n vals → val | Fused `[a,b,c].min/max/hash/pack/include?` on a freshly built array |

### Super / yield

| Insn | Operands | Pops → Pushes | Description |
|------|----------|---------------|-------------|
| `invokesuper`        | `CALL_DATA cd`, `ISEQ blockiseq` | args... → val | `super(args)` |
| `invokesuperforward` | `CALL_DATA cd`, `ISEQ blockiseq` | args... → val | `super(...)` forwarding frame args |
| `invokeblock`        | `CALL_DATA cd` | args... → val | `yield` |

---

## Control flow

### Returning / unwinding

| Insn | Operands | Pops → Pushes | Description |
|------|----------|---------------|-------------|
| `leave` | — | val → val | Return TOS from this frame; handles interrupts and `finish` markers |
| `throw` | `throw_state` | throwobj → val | Non-local exit: `break`/`next`/`redo`/`return`/`retry`/exceptions; `throw_state` encodes kind + target frame |

### Branches & jumps

| Insn | Operands | Pops → Pushes | Description |
|------|----------|---------------|-------------|
| `jump`         | `dst` | — → — | Unconditional PC += dst, with interrupt check |
| `branchif`     | `dst` | val → — | Jump iff `val` is truthy |
| `branchunless` | `dst` | val → — | Jump iff `val` is falsy |
| `branchnil`    | `dst` | val → — | Jump iff `val` is `nil` (used by `&.`) |
| `jump_without_ints`         | `dst` | — → — | Same, skipping the interrupt check (safe inner-loop variant) |
| `branchif_without_ints`     | `dst` | val → — | `branchif` without interrupt check |
| `branchunless_without_ints` | `dst` | val → — | `branchunless` without interrupt check |
| `branchnil_without_ints`    | `dst` | val → — | `branchnil` without interrupt check |

### Misc control

| Insn | Operands | Pops → Pushes | Description |
|------|----------|---------------|-------------|
| `once` | `ISEQ iseq`, `ISE ise` | — → val | Run `iseq` exactly once, cache the result in `ise`; used for `/.../o` and `once { }` |
| `opt_case_dispatch` | `CDHASH hash`, `OFFSET else_offset` | key → — | `case/when` jump table when `when` values are hashable literals |

---

## Optimized sends (inline-cached binops and methods)

All of these take a `CALL_DATA cd`. They first try a fast C path; if the
receiver isn't a redefined-core type they fall through to a generic `send`.

| Insn | Pops → Pushes | Ruby equivalent |
|------|---------------|-----------------|
| `opt_plus`   | recv, obj → val | `recv + obj` |
| `opt_minus`  | recv, obj → val | `recv - obj` |
| `opt_mult`   | recv, obj → val | `recv * obj` |
| `opt_div`    | recv, obj → val | `recv / obj` |
| `opt_mod`    | recv, obj → val | `recv % obj` |
| `opt_eq`     | recv, obj → val | `recv == obj` |
| `opt_neq`    | recv, obj → val | `recv != obj` (takes two `CALL_DATA`s: one for `==`, one for `!=`) |
| `opt_lt`     | recv, obj → val | `recv < obj` |
| `opt_le`     | recv, obj → val | `recv <= obj` |
| `opt_gt`     | recv, obj → val | `recv > obj` |
| `opt_ge`     | recv, obj → val | `recv >= obj` |
| `opt_ltlt`   | recv, obj → val | `recv << obj` (String/Array append, Integer shift) |
| `opt_and`    | recv, obj → val | `recv & obj` |
| `opt_or`     | recv, obj → val | `recv \| obj` |
| `opt_aref`   | recv, obj → val | `recv[obj]` (String, Array, Hash fast paths) |
| `opt_aset`   | recv, obj, set → set | `recv[obj] = set` |
| `opt_length` | recv → val | `recv.length` |
| `opt_size`   | recv → val | `recv.size` |
| `opt_empty_p`| recv → val | `recv.empty?` |
| `opt_succ`   | recv → val | `recv.succ` (Integer/String fast path) |
| `opt_not`    | recv → val | `!recv` |
| `opt_regexpmatch2` | obj2, obj1 → val | `obj2 =~ obj1` (or `obj1.match? obj2` when folded) |

There is also an `opt_aref_with` / `opt_aset_with` family in older Ruby for
`hash["literal"]`; in current master those have been folded into `opt_aref`
and `opt_aset` with string-frozen fast paths.

---

## Built-in delegation (Ruby-in-C `__builtin__`)

| Insn | Operands | Pops → Pushes | Description |
|------|----------|---------------|-------------|
| `invokebuiltin` | `RB_BUILTIN bf` | args... → val | Call a C `cfunc` directly with `bf->argc` stack args; used by `prelude.rb`-compiled methods |
| `opt_invokebuiltin_delegate`       | `bf`, `index` | — → val | Same, but pass the current frame's locals starting at `index` as args (zero stack traffic) |
| `opt_invokebuiltin_delegate_leave` | `bf`, `index` | — → val | Fused `opt_invokebuiltin_delegate` + `leave` tail-call for one-line builtins |

---

## Miscellaneous

| Insn | Operands | Pops → Pushes | Description |
|------|----------|---------------|-------------|
| `nop` | — | — → — | No-op (padding / patch point) |

### Joke instructions (`DEFINE_INSN_IF(SUPPORT_JOKE)`, off by default)

| Insn | Pops → Pushes | Description |
|------|---------------|-------------|
| `bitblt` | — → str | Pushes `"a bit of bacon, lettuce and tomato"` |
| `answer` | — → 42  | Pushes `INT2FIX(42)` |

---

## Specialized / unified variants you see in disasm

CRuby specializes frequently-used instructions at build time into fixed-operand
variants. These aren't separate `DEFINE_INSN` entries — they are generated
from `defs/opt_operand.def` (operand union) and `defs/opt_insn_unif.def`
(instruction unification). A few naming conventions:

- **`_WC_N`** — "with wildcard": the `level` operand is baked in at value
  `N`. `getlocal_WC_0` is `getlocal idx, 0` (current frame), `getlocal_WC_1`
  is `getlocal idx, 1` (outer scope). These cover the overwhelming majority
  of local accesses so the interpreter avoids decoding the `level` operand.
  The same exists for `setlocal_WC_0`, `setlocal_WC_1`.
- **`putobject_INT2FIX_0_`, `putobject_INT2FIX_1_`** — `putobject` with the
  operand fixed to `INT2FIX(0)` or `INT2FIX(1)`. Pushing `0` or `1` is
  extremely common (loop counters, `a + 1`, etc.) so the fused form saves an
  operand read.
- **`opt_*`** — already covered above; any `opt_*` insn is an
  inline-cached, type-guarded specialization of a core method that falls
  through to the generic call path on cache miss. Not the same thing as the
  `_WC_*` / `_INT2FIX_*` mechanical specializations.
- **Instruction unification (`opt_insn_unif.def`)** — combines pairs like
  `putobject + putstring`, `putobject + setlocal`, `getlocal + getlocal`
  into a single fused insn when both appear back-to-back. These carry
  compound names but are off by default in recent Ruby builds; you mostly
  see them in trace-enabled or specially-built interpreters.
- **Trace variants** — when `TracePoint` is enabled, CRuby swaps the
  insn-dispatch table over to a parallel "trace_" table that fires hooks
  and then jumps into the original insn body. There is *not* a
  `trace_<insn>` in `insns.def`; the mechanism is done at dispatch time, so
  you never see trace variants in normal disasm output.

Run `RubyVM::InstructionSequence.compile("x = 1; x + 1").disasm` to see the
specialized names used by the current build.

---

## Further reading

- **Canonical instruction source** —
  <https://github.com/ruby/ruby/blob/master/insns.def>
- **Specialization configs** —
  <https://github.com/ruby/ruby/blob/master/defs/opt_operand.def>,
  <https://github.com/ruby/ruby/blob/master/defs/opt_insn_unif.def>
- **Helpers invoked from insn bodies** —
  [`vm_insnhelper.c`](https://github.com/ruby/ruby/blob/master/vm_insnhelper.c),
  [`vm_insnhelper.h`](https://github.com/ruby/ruby/blob/master/vm_insnhelper.h)
- **Code generator** — `tool/ruby_vm/` (ERB templates that turn `insns.def`
  into `vm.inc` / opcode tables)
- **`RubyVM::InstructionSequence` runtime API** —
  <https://docs.ruby-lang.org/en/master/RubyVM/InstructionSequence.html>
- **Koichi Sasada's original YARV papers** — linked from
  <https://www.atdot.net/yarv/> (the design rationale, the "why stack
  machine", the original opcode set)
- **CRuby Ruby-level docs in tree** — `doc/contributing/`,
  `doc/extension.rdoc`; there is no `doc/yarv/` subtree in current master
  (checked 2026-04), only the historical papers linked above.
