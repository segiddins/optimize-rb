# Research

Notes and references collected while preparing the talk.

## Subdirectories

- `yarv/` — YARV instruction set references, iseq binary format notes,
  `RubyVM::InstructionSequence` API usage.
- `cruby/` — annotated excerpts from the CRuby source (compile.c,
  insns.def, iseq.c) with line references.
- `prior-art/` — gems, talks, blog posts that touch bytecode
  generation or iseq manipulation (e.g. `RubyVM::InstructionSequence.load`,
  `iseq_loader`, existing RubyKaigi talks on YARV).

Add notes as plain markdown files. Prefer one file per topic; link
between files rather than duplicating.
