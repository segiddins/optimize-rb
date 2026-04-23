# optimize-rb

The [`optimize`](https://rubygems.org/gems/optimize) gem — a hand-rolled
YARV bytecode optimizer for CRuby — plus the companion post and research
for the RubyKaigi 2026 talk *Ruby the Hard Way: Writing Bytecode to
Optimize Plain Ruby* by Samuel Giddins.

Talk page: <https://rubykaigi.org/2026/presentations/segiddins.html>

## Layout

- `optimizer/` — the `optimize` gem: IR, codec, passes, harness, demos
- `post.md` — long-form companion to the talk
- `talk/` — bibliography and references
- `research/` — notes and prior art
- `experiments/` — runnable Ruby experiments (shared Gemfile, numbered subdirs)
- `mcp-server/` — local MCP server that runs Ruby in Docker for the harness
- `docs/superpowers/` — design specs and implementation plans

## Prerequisites

- Ruby 4.0.2 (see each subproject's `.ruby-version`)
- Docker Desktop or compatible daemon (for the MCP server)
- `jj` for version control

## Getting started

    cd optimizer && bundle install && bundle exec rake test
    cd ../experiments && bundle install
    cd ../mcp-server && bundle install && bundle exec rake test

The MCP server is registered via `.mcp.json` at the repo root; Claude
Code picks it up automatically when started from this directory.
