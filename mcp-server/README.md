# ruby-bytecode-mcp

Local MCP server exposing Ruby/YARV tools that execute inside
`docker run --rm ruby:4.0.2-slim`. Used by the Claude Code harness to
iterate on bytecode experiments for the talk.

## Install

    bundle install
    bundle exec rake test

## Tools

| Name | Purpose |
|---|---|
| `run_ruby` | Execute arbitrary Ruby in a container |
| `disasm` | Return disassembly of top-level + child iseqs |
| `parse_ast` | Return AST via Prism or `RubyVM::AbstractSyntaxTree` |
| `benchmark_ips` | Run `benchmark-ips` across named scenarios |
| `iseq_to_binary` | Compile code and return base64 binary iseq |
| `load_iseq_binary` | Load a base64 binary iseq and optionally call it |

All tools accept an optional `ruby_version` string (default `4.0.2`).

## Registration

The repo-root `.mcp.json` points Claude Code at `bin/ruby-bytecode-mcp`.
The tools are auto-approved via `.claude/settings.json`.
