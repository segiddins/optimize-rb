# Repo Scaffold: `ruby-the-hard-way-bytecode-talk`

Design for the research, experimentation, and drafting environment for the
RubyKaigi 2026 talk *Ruby the Hard Way: Writing Bytecode to Optimize Plain
Ruby* (Samuel Giddins).

## Goals

- A single repo holding three artifact kinds: **research notes**, **runnable
  experiments**, and the **talk draft**.
- Make it easy for Claude Code to iterate on bytecode experiments without
  per-command permission prompts, by running all Ruby execution inside
  Docker via a local MCP server.
- Keep the talk draft as plain markdown prose until the structure stabilizes
  enough to convert to slides.

## Non-goals

- Writing the actual talk content.
- Building out real experiments beyond a smoke-test.
- Slide tooling (Marp / Reveal) — deferred until the outline firms up.
- CI, publishing, theming.
- Multi-Ruby-version support in the first cut. The MCP server accepts a
  `ruby_version` parameter per call, but the default and the only version
  tested during scaffolding is the pinned one (see *Ruby version* below).

## Ruby version

Pin to **Ruby 4.0.2** — the latest stable release as of 2026-04-18 per
<https://www.ruby-lang.org/en/downloads/>. Pinned in:

- `experiments/.ruby-version`
- `mcp-server/.ruby-version`
- `mcp-server`'s Docker runner default image tag: `ruby:4.0.2-slim`

Both `experiments/` and `mcp-server/` get their own `.ruby-version` so each
sub-project can move independently later.

## Repo layout

```
.
├── README.md
├── docs/
│   └── superpowers/specs/          # design specs (this file lives here)
├── research/
│   ├── README.md                   # index of notes
│   ├── yarv/                       # YARV instruction refs, iseq format
│   ├── cruby/                      # annotated CRuby source excerpts
│   └── prior-art/                  # gems, talks, blog posts
├── experiments/
│   ├── .ruby-version               # 4.0.2
│   ├── Gemfile                     # benchmark-ips, prism, debug
│   ├── Gemfile.lock
│   ├── Rakefile                    # `rake -T` lists experiments
│   ├── lib/                        # shared helpers
│   ├── 01-iseq-basics/
│   │   ├── README.md
│   │   └── hello.rb                # smoke test: compile + disasm
│   └── README.md
├── talk/
│   ├── outline.md                  # prose outline (primary artifact)
│   ├── notes.md                    # scratch
│   └── references.md               # bibliography
├── mcp-server/
│   ├── .ruby-version               # 4.0.2
│   ├── Gemfile                     # mcp, json
│   ├── Gemfile.lock
│   ├── bin/ruby-bytecode-mcp       # stdio entry point
│   ├── lib/
│   │   ├── server.rb               # tool registration
│   │   ├── docker_runner.rb        # wraps `docker run --rm ruby:X -e ...`
│   │   └── tools/
│   │       ├── run_ruby.rb
│   │       ├── disasm.rb
│   │       ├── parse_ast.rb
│   │       ├── benchmark_ips.rb
│   │       ├── iseq_to_binary.rb
│   │       └── load_iseq_binary.rb
│   └── README.md
├── .claude/
│   ├── settings.json               # auto-allow mcp__ruby-bytecode__* tools
│   └── skills/
│       ├── running-ruby-experiments/SKILL.md
│       └── disassembling-ruby/SKILL.md
└── .mcp.json                       # registers the local stdio MCP server
```

## MCP server

### Transport & runtime

- **Transport:** stdio.
- **Language:** Ruby, using the `mcp` gem (official Anthropic Ruby SDK).
- **Registration:** `.mcp.json` at the repo root points at
  `mcp-server/bin/ruby-bytecode-mcp`. The server is started by the Claude
  Code harness on demand.

### Sandboxing

All Ruby execution happens inside `docker run --rm` against a pinned
`ruby:X.Y-slim` image. The container has no mounted host volumes by
default, a fixed short timeout, and no network. This isolation is why the
tools are safe to auto-approve in `.claude/settings.json`.

If Docker is not running or the image is missing, every tool returns a
structured error (not an exception) pointing the caller at the fix.

### Tools

| Tool | Inputs | Output |
|---|---|---|
| `run_ruby` | `code: str`, `ruby_version?: str`, `gems?: str[]`, `stdin?: str`, `timeout_s?: int` | `{stdout, stderr, exit_code, duration_ms}` |
| `disasm` | `code: str`, `ruby_version?: str` | disasm text of top-level iseq and all child iseqs |
| `parse_ast` | `code: str`, `parser?: "prism" \| "ruby_vm"` (default `prism`) | AST as text |
| `benchmark_ips` | `setup?: str`, `scenarios: {name, code}[]`, `ruby_version?: str`, `warmup?: int`, `time?: int` | benchmark-ips report text |
| `iseq_to_binary` | `code: str`, `ruby_version?: str` | `{blob_b64: str, size: int}` |
| `load_iseq_binary` | `blob_b64: str`, `ruby_version?: str`, `call?: bool` | execution result |

All tools accept an optional `ruby_version` (default: `4.0.2`). The docker
runner lazily pulls images on first use and caches them in the local
Docker daemon.

### Auto-approval

`.claude/settings.json` contains:

```json
{
  "permissions": {
    "allow": ["mcp__ruby-bytecode__*"]
  }
}
```

Justification: the tools' blast radius is bounded by the container (no
host FS, no network, time-limited). The worst case is wasted CPU, which
the timeout caps.

## Project-local skills

Under `.claude/skills/`:

- **running-ruby-experiments** — triggers when the assistant is about to
  shell out to `ruby`, `irb`, `bundle exec`, or set up a benchmark. Routes
  to the MCP `run_ruby` / `benchmark_ips` tools.
- **disassembling-ruby** — triggers when exploring YARV output, iseq
  structure, or ASTs. Routes to `disasm` / `parse_ast` /
  `iseq_to_binary` / `load_iseq_binary`.

Each skill is a directory with a single `SKILL.md` using standard
frontmatter (`name`, `description`).

## Talk format

Plain markdown prose in `talk/outline.md`. Placeholder sections only;
content is out of scope for the scaffold.

## Smoke test

After scaffolding, this must work end-to-end:

1. `cd experiments && bundle install` succeeds.
2. `cd mcp-server && bundle install` succeeds.
3. Claude Code picks up `.mcp.json` and lists the six tools.
4. Calling `disasm` with `code: "1 + 2"` returns a disasm dump that
   mentions `putobject` and `opt_plus`.
5. Calling `run_ruby` with `code: "puts RUBY_VERSION"` returns stdout
   `4.0.2`.

## Open items (tracked for the plan)

- Exact dependency list for `experiments/Gemfile` (benchmark-ips, prism,
  debug — confirm during plan).
- Whether to ship a custom Dockerfile with gems pre-installed, or rely on
  the stock `ruby:4.0.2-slim` + per-call `gem install`. Default for the
  scaffold: stock image; revisit if cold-starts hurt.
- Exact invocation shape for the `mcp` gem's stdio server — confirm
  during plan by reading its README.
- Whether project-local `.claude/skills/` is auto-loaded by the Claude
  Code harness, or whether the skills need to be wrapped in a small
  in-repo plugin. Confirm at plan time; fall back to a plugin wrapper
  if bare `.claude/skills/` is not picked up.
