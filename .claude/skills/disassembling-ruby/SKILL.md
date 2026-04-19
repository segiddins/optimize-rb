---
name: disassembling-ruby
description: Use when exploring YARV bytecode, iseq structure, ASTs, or round-tripping iseq binaries. Routes to the ruby-bytecode MCP disasm, parse_ast, iseq_to_binary, and load_iseq_binary tools.
---

# Disassembling Ruby

When the task involves looking at YARV bytecode, the AST, or the iseq
binary format, call the `ruby-bytecode` MCP tools rather than running
`RubyVM::InstructionSequence.compile(...).disasm` manually.

## Tool routing

- Disassembly of a snippet (and its children) → `mcp__ruby-bytecode__disasm`
- AST (Prism default, RubyVM::AST on request) → `mcp__ruby-bytecode__parse_ast`
- Compile to binary iseq → `mcp__ruby-bytecode__iseq_to_binary`
- Load/execute a binary iseq → `mcp__ruby-bytecode__load_iseq_binary`

The `iseq_to_binary` / `load_iseq_binary` pair round-trips cleanly within
a single Ruby version; cross-version binaries are not portable.
