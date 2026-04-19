# Intercepting code loading to swap method iseqs

## The hook: `RubyVM::InstructionSequence.load_iseq(path)`

If this singleton method is defined, MRI calls it from `rb_iseq_load_iseq`
on every `require` / `load` / `require_relative` (the latter resolves to an
absolute path and takes the same codepath). The return value:

- an `ISeq` → MRI uses it verbatim, skipping its own compilation
- `nil` → MRI falls back to compiling the source file normally

This is the only supported seam for substituting a precompiled or rewritten
iseq at load time. It's what Bootsnap uses to install cached `.rbc`-style
binaries (see `Shopify/bootsnap` → `lib/bootsnap/compile_cache/iseq.rb`).

### Caveats

- Not called for `eval`, `instance_eval`, or `Kernel#eval`-backed DSLs.
- Not called for scripts loaded via the initial `ruby foo.rb` entry point.
- The returned ISeq's `path` / `absolute_path` should match the file being
  loaded, or error messages and `__FILE__` get misleading.
- `Marshal.load` is *not* how iseqs serialize — use `to_binary` /
  `load_from_binary`. The binary format is version-locked (MRI minor + patch
  + platform); store a version tag next to the blob.

## Observation-only alternatives

- `TracePoint.new(:script_compiled)` — fires after MRI compiles a script.
  `tp.instruction_sequence` is the freshly-built ISeq. You can cache or
  log, but you can't substitute at this point; compilation already happened.
- `RubyVM::InstructionSequence.compile_option=` — toggles peephole, tailcall,
  stack caching, etc. Global, affects future compiles, doesn't edit iseqs.

## Building a replacement iseq

| Input | API | Output |
|---|---|---|
| Source string | `RubyVM::InstructionSequence.compile(src, file, path, line)` | ISeq |
| Source file | `RubyVM::InstructionSequence.compile_file(path)` | ISeq |
| AST | re-emit source (Prism `#source` or manual), then `compile` | ISeq |
| Cached blob | `RubyVM::InstructionSequence.load_from_binary(blob)` | ISeq |
| ISeq | `iseq.to_binary` | Blob |

There is **no public API to mutate an ISeq in place**. The op arrays are
frozen when read from Ruby.

## Swapping an existing method's iseq

No `Method#iseq=` exists. Options, cleanest first:

1. **Load-time substitution** — rewrite or replace the defining file via
   `load_iseq`. The `def` runs against your ISeq during class body
   evaluation; the resulting method entry points at your bytecode natively.
2. **`eval` / `class_eval` with rewritten source** — loses the "I shipped
   raw bytecode" angle but trivially works for any method.
3. **C extension** — `rb_iseq_new_with_opt` + `rb_method_entry_make`, or
   patching `rb_method_definition_t->body.iseq`. This is the territory
   MJIT / experimental YJIT patches play in. Not portable across minor Ruby
   versions; internal structs shift.
4. **Remove + redefine** — `Module#remove_method` then re-`def` via
   `module_eval` of a new source string. Works for top-level method
   redefinition but doesn't reuse existing iseq machinery.

## Pedagogical arc for the talk

Source → AST → ISeq (show `compile`) → transform at either AST or source
level → round-trip through `to_binary` / `load_from_binary` → install via
`load_iseq` hook. This matches what the `ruby-bytecode` MCP tools already
expose and stays out of C-extension territory.

## References

- MRI source: `iseq.c` (`rb_iseq_load_iseq`), `load.c`, `vm_core.h`
- Bootsnap: `Shopify/bootsnap` `lib/bootsnap/compile_cache/iseq.rb`
- `doc/yjit/*.md` in MRI — adjacent, shows how iseqs are consumed
- Koichi Sasada, "The Ruby Virtual Machine" (RubyConf 2007) — baseline model
- "YJIT: Building a New JIT Compiler for CRuby" (Chevalier-Boisvert, 2022)
