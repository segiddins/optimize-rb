---
name: running-ruby-experiments
description: Use when about to execute Ruby code, run a benchmark, or invoke bundle/irb for any part of this talk repo. Route to the ruby-bytecode MCP tools instead of shelling out so execution stays sandboxed in Docker and does not require permission prompts.
---

# Running Ruby experiments

When this repo needs Ruby code executed — a quick `ruby -e`, a benchmark,
an experiment from `experiments/NN-*/` — use the `ruby-bytecode` MCP
server instead of `Bash`.

## Tool routing

- One-off execution → `mcp__ruby-bytecode__run_ruby`
- Benchmark comparison → `mcp__ruby-bytecode__benchmark_ips`
- Everything runs inside `docker run --rm ruby:4.0.2-slim`; no host
  filesystem or network by default.

## When NOT to use the MCP

- Editing files (use `Edit`/`Write`).
- `bundle install` (needs to write `Gemfile.lock` on host; use `Bash`).
- Non-Ruby shell commands.
