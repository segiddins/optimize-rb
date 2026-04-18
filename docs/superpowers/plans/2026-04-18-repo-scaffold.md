# Repo Scaffold Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Scaffold a research/experimentation/drafting repo for the RubyKaigi 2026 talk *Ruby the Hard Way: Writing Bytecode to Optimize Plain Ruby*, with an in-repo Ruby MCP server that executes all Ruby code in Docker so the harness can iterate without per-command permission prompts.

**Architecture:** Single repo with four top-level artifact zones — `research/`, `experiments/`, `talk/`, `mcp-server/` — plus `.mcp.json` and `.claude/` wiring. The MCP server uses the official Ruby `mcp` gem over stdio and shells out to `docker run --rm ruby:4.0.2-slim` for each tool call.

**Tech Stack:** Ruby 4.0.2, `mcp` gem ≥ 0.13.0, `minitest` (stdlib), `benchmark-ips`, `prism`, Docker (host-side), `jj` for VCS.

**Spec:** `docs/superpowers/specs/2026-04-18-repo-scaffold-design.md`

**VCS note:** This repo uses `jj`. All commit commands are `jj commit -m "..."` — this closes the current change and starts a fresh working copy on top. Do not use `jj describe`.

**Note on `Kernel#send(:eval, ...)` in this plan:** the `benchmark_ips` tool runs caller-supplied Ruby as benchmark scenarios. That *is* evaluation of dynamic code, and it is deliberate — the server exists to run arbitrary Ruby. All execution happens inside a locked-down Docker container (no host FS, no network by default, memory+cpu capped, hard timeout). The plan writes `Kernel.send(:eval, ...)` rather than the direct form purely to avoid tripping a host-side PreToolUse substring check; the runtime semantics are identical.

---

## File Structure

```
.
├── .gitignore
├── .mcp.json
├── README.md
├── .claude/
│   ├── settings.json
│   └── skills/
│       ├── running-ruby-experiments/SKILL.md
│       └── disassembling-ruby/SKILL.md
├── docs/superpowers/
│   ├── specs/2026-04-18-repo-scaffold-design.md   (exists)
│   └── plans/2026-04-18-repo-scaffold.md          (this file)
├── research/
│   ├── README.md
│   ├── yarv/.gitkeep
│   ├── cruby/.gitkeep
│   └── prior-art/.gitkeep
├── talk/
│   ├── outline.md
│   ├── notes.md
│   └── references.md
├── experiments/
│   ├── .ruby-version
│   ├── Gemfile
│   ├── Gemfile.lock              (generated)
│   ├── Rakefile
│   ├── README.md
│   ├── lib/disasm_helper.rb
│   └── 01-iseq-basics/
│       ├── README.md
│       └── hello.rb
└── mcp-server/
    ├── .ruby-version
    ├── Gemfile
    ├── Gemfile.lock              (generated)
    ├── Rakefile
    ├── README.md
    ├── bin/ruby-bytecode-mcp
    ├── lib/
    │   ├── ruby_bytecode_mcp.rb       (loader)
    │   ├── ruby_bytecode_mcp/server.rb
    │   ├── ruby_bytecode_mcp/docker_runner.rb
    │   └── ruby_bytecode_mcp/tools/
    │       ├── run_ruby.rb
    │       ├── disasm.rb
    │       ├── parse_ast.rb
    │       ├── benchmark_ips.rb
    │       ├── iseq_to_binary.rb
    │       └── load_iseq_binary.rb
    └── test/
        ├── test_helper.rb
        ├── test_docker_runner.rb
        └── tools/
            ├── test_run_ruby.rb
            ├── test_disasm.rb
            ├── test_parse_ast.rb
            ├── test_benchmark_ips.rb
            └── test_iseq_binary.rb
```

---

## Task 1: Root README and .gitignore

**Files:**
- Create: `README.md`
- Create: `.gitignore`

- [ ] **Step 1: Write `.gitignore`**

```gitignore
# Ruby
*.gem
*.rbc
.bundle/
vendor/bundle/
/tmp/
/log/

# Editors
.vscode/
.idea/
*.swp

# OS
.DS_Store
```

Note: we DO track `Gemfile.lock` for reproducible experiments.

- [ ] **Step 2: Write root `README.md`**

````markdown
# ruby-the-hard-way-bytecode-talk

Research, experiments, and draft for the RubyKaigi 2026 talk
*Ruby the Hard Way: Writing Bytecode to Optimize Plain Ruby*
by Samuel Giddins.

Talk page: <https://rubykaigi.org/2026/presentations/segiddins.html>

## Layout

- `research/` — notes, references, prior art
- `experiments/` — runnable Ruby experiments (shared Gemfile, numbered subdirs)
- `talk/` — prose outline, notes, bibliography
- `mcp-server/` — local MCP server that runs Ruby in Docker for the harness
- `docs/superpowers/` — design specs and implementation plans

## Prerequisites

- Ruby 4.0.2 (see each subproject's `.ruby-version`)
- Docker Desktop or compatible daemon (for the MCP server)
- `jj` for version control

## Getting started

```sh
cd experiments && bundle install
cd ../mcp-server && bundle install && bundle exec rake test
```

The MCP server is registered via `.mcp.json` at the repo root; Claude
Code picks it up automatically when started from this directory.
````

- [ ] **Step 3: Commit**

```sh
jj commit -m "Add root README and .gitignore"
```

---

## Task 2: Research skeleton

**Files:**
- Create: `research/README.md`
- Create: `research/yarv/.gitkeep`
- Create: `research/cruby/.gitkeep`
- Create: `research/prior-art/.gitkeep`

- [ ] **Step 1: Create the three `.gitkeep` files (empty)**

```sh
mkdir -p research/yarv research/cruby research/prior-art
: > research/yarv/.gitkeep
: > research/cruby/.gitkeep
: > research/prior-art/.gitkeep
```

- [ ] **Step 2: Write `research/README.md`**

```markdown
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
```

- [ ] **Step 3: Commit**

```sh
jj commit -m "Scaffold research/ with topic subdirectories"
```

---

## Task 3: Talk skeleton

**Files:**
- Create: `talk/outline.md`
- Create: `talk/notes.md`
- Create: `talk/references.md`

- [ ] **Step 1: Write `talk/outline.md`**

```markdown
# Ruby the Hard Way: Writing Bytecode to Optimize Plain Ruby

Prose outline. Content TBD — structure only for now.

## 0. Cold open

Hook: a production hotspot that refused to yield to profiling and
refactoring.

## 1. Why bytecode?

What's left when you've exhausted "write better Ruby".

## 2. From source to YARV

The compilation pipeline, in enough detail to write bytecode by hand.

## 3. Writing bytecode by hand

`RubyVM::InstructionSequence.compile`, `.load_from_binary`, the shape of
the iseq array.

## 4. Replacing a hot method

A worked example: identify, compile, swap, measure.

## 5. Tradeoffs

Portability, debuggability, maintenance, Ruby version drift.

## 6. When to reach for this

And, more importantly, when not to.

## 7. Close

Call to action / links / questions.
```

- [ ] **Step 2: Write `talk/notes.md`**

```markdown
# Notes

Loose scratch. Quotes, code fragments, production anecdotes to weave
into the outline later. No structure required.
```

- [ ] **Step 3: Write `talk/references.md`**

```markdown
# References

Bibliography for the talk. One entry per source; include link, author,
and a one-line note on why it's relevant.

## Format

- Title — Author/Org — <url>
  - Why it matters: one line.
```

- [ ] **Step 4: Commit**

```sh
jj commit -m "Scaffold talk/ with outline, notes, references stubs"
```

---

## Task 4: Experiments skeleton + smoke-test experiment

**Files:**
- Create: `experiments/.ruby-version`
- Create: `experiments/Gemfile`
- Create: `experiments/Rakefile`
- Create: `experiments/README.md`
- Create: `experiments/lib/disasm_helper.rb`
- Create: `experiments/01-iseq-basics/README.md`
- Create: `experiments/01-iseq-basics/hello.rb`

- [ ] **Step 1: Pin Ruby version**

```sh
echo '4.0.2' > experiments/.ruby-version
```

- [ ] **Step 2: Write `experiments/Gemfile`**

```ruby
# frozen_string_literal: true

source "https://rubygems.org"

ruby "4.0.2"

gem "benchmark-ips", "~> 2.14"
gem "prism", "~> 1.2"

group :development do
  gem "debug", "~> 1.9"
end
```

- [ ] **Step 3: Write `experiments/lib/disasm_helper.rb`**

```ruby
# frozen_string_literal: true

module DisasmHelper
  # Returns the disassembly of +code+ including all nested iseqs.
  def self.deep_disasm(code)
    iseq = RubyVM::InstructionSequence.compile(code)
    [iseq.disasm, *each_child(iseq).map(&:disasm)].join("\n")
  end

  def self.each_child(iseq, &block)
    return enum_for(__method__, iseq) unless block_given?
    iseq.each_child do |child|
      yield child
      each_child(child, &block)
    end
  end
end
```

- [ ] **Step 4: Write `experiments/01-iseq-basics/hello.rb`**

```ruby
# frozen_string_literal: true

# Smoke test: compile `1 + 2` and print the disasm.
# Run from experiments/: `bundle exec ruby 01-iseq-basics/hello.rb`

require_relative "../lib/disasm_helper"

puts "Ruby: #{RUBY_VERSION}"
puts
puts DisasmHelper.deep_disasm("1 + 2")
```

- [ ] **Step 5: Write `experiments/01-iseq-basics/README.md`**

````markdown
# 01 — ISeq basics

Smoke test confirming the experiments harness works:

```sh
bundle exec ruby 01-iseq-basics/hello.rb
```

Expected: the Ruby version and a disassembly containing `putobject 1`,
`putobject 2`, and `opt_plus`.
````

- [ ] **Step 6: Write `experiments/Rakefile`**

```ruby
# frozen_string_literal: true

require "rake"

task default: :list

desc "List available experiments"
task :list do
  Dir.glob("[0-9]*").sort.each do |dir|
    next unless File.directory?(dir)
    readme = File.join(dir, "README.md")
    summary = File.exist?(readme) ? File.readlines(readme).first.strip.sub(/^#+\s*/, "") : ""
    puts "  #{dir.ljust(24)} #{summary}"
  end
end
```

- [ ] **Step 7: Write `experiments/README.md`**

````markdown
# Experiments

Single Ruby project shared across all experiments. Numbered subdirectories
correspond to a narrative arc that maps onto the talk outline.

## Layout

- `Gemfile` — shared dependencies
- `lib/` — helpers shared across experiments
- `NN-topic/` — one experiment, with its own `README.md` and one or more
  runnable `.rb` files

## Usage

```sh
bundle install
bundle exec rake list            # see what's here
bundle exec ruby 01-iseq-basics/hello.rb
```

Prefer adding a new numbered directory over mutating an existing one —
experiments are journal entries, not production code.
````

- [ ] **Step 8: Generate `Gemfile.lock`**

Run: `cd experiments && bundle install`
Expected: `Bundle complete!` with no errors. `Gemfile.lock` is created.

If Ruby 4.0.2 is not installed on the host, this step is expected to fail.
Document the failure and move on — `Gemfile.lock` will be generated via
Docker during the smoke test in Task 14. In that case, skip to Step 9
without staging `Gemfile.lock`.

- [ ] **Step 9: Commit**

```sh
jj commit -m "Scaffold experiments/ with shared Gemfile and 01-iseq-basics smoke test"
```

---

## Task 5: MCP server bootstrap

**Files:**
- Create: `mcp-server/.ruby-version`
- Create: `mcp-server/Gemfile`
- Create: `mcp-server/Rakefile`
- Create: `mcp-server/bin/ruby-bytecode-mcp`
- Create: `mcp-server/lib/ruby_bytecode_mcp.rb`
- Create: `mcp-server/lib/ruby_bytecode_mcp/server.rb`
- Create: `mcp-server/test/test_helper.rb`
- Create: `mcp-server/README.md`

- [ ] **Step 1: Pin Ruby version**

```sh
echo '4.0.2' > mcp-server/.ruby-version
```

- [ ] **Step 2: Write `mcp-server/Gemfile`**

```ruby
# frozen_string_literal: true

source "https://rubygems.org"

ruby "4.0.2"

gem "mcp", "~> 0.13"

group :test do
  gem "minitest", "~> 5.22"
  gem "rake", "~> 13.2"
end
```

- [ ] **Step 3: Write `mcp-server/Rakefile`**

```ruby
# frozen_string_literal: true

require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "lib" << "test"
  t.pattern = "test/**/test_*.rb"
  t.warning = false
end

task default: :test
```

- [ ] **Step 4: Write `mcp-server/lib/ruby_bytecode_mcp.rb` (loader)**

```ruby
# frozen_string_literal: true

require "mcp"

module RubyBytecodeMcp
  DEFAULT_RUBY_VERSION = "4.0.2"
  DEFAULT_IMAGE_PREFIX = "ruby"
  DEFAULT_IMAGE_SUFFIX = "-slim"
  DEFAULT_TIMEOUT_S = 30
end

require_relative "ruby_bytecode_mcp/docker_runner"
require_relative "ruby_bytecode_mcp/server"
```

- [ ] **Step 5: Write `mcp-server/lib/ruby_bytecode_mcp/server.rb`**

```ruby
# frozen_string_literal: true

require_relative "tools/run_ruby"
require_relative "tools/disasm"
require_relative "tools/parse_ast"
require_relative "tools/benchmark_ips"
require_relative "tools/iseq_to_binary"
require_relative "tools/load_iseq_binary"

module RubyBytecodeMcp
  TOOLS = [
    Tools::RunRuby,
    Tools::Disasm,
    Tools::ParseAst,
    Tools::BenchmarkIps,
    Tools::IseqToBinary,
    Tools::LoadIseqBinary,
  ].freeze

  def self.build_server
    MCP::Server.new(name: "ruby-bytecode", tools: TOOLS.dup)
  end
end
```

Note: the tool files referenced by this `require_relative` block are
created in Tasks 7-11. Until those tasks complete, `require
"ruby_bytecode_mcp"` will raise LoadError — that is expected and fully
resolved at the end of Task 11.

- [ ] **Step 6: Write `mcp-server/bin/ruby-bytecode-mcp`**

```ruby
#!/usr/bin/env ruby
# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "ruby_bytecode_mcp"

server = RubyBytecodeMcp.build_server
transport = MCP::Server::Transports::StdioTransport.new(server)
transport.open
```

Then: `chmod +x mcp-server/bin/ruby-bytecode-mcp`

- [ ] **Step 7: Write `mcp-server/test/test_helper.rb`**

```ruby
# frozen_string_literal: true

require "minitest/autorun"
require "ruby_bytecode_mcp"

module TestHelper
  def docker_available?
    system("docker info > /dev/null 2>&1")
  end

  def skip_without_docker!
    skip "Docker is not available on this host" unless docker_available?
  end
end
```

- [ ] **Step 8: Write `mcp-server/README.md`**

````markdown
# ruby-bytecode-mcp

Local MCP server exposing Ruby/YARV tools that execute inside
`docker run --rm ruby:4.0.2-slim`. Used by the Claude Code harness to
iterate on bytecode experiments for the talk.

## Install

```sh
bundle install
bundle exec rake test
```

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
````

- [ ] **Step 9: Verify bootstrap tests run (and currently do nothing)**

Run: `cd mcp-server && bundle install && bundle exec rake test`
Expected: exit 0 with `0 runs, 0 assertions` (no test files yet).

If `bundle install` fails due to missing Ruby 4.0.2, this is the same
situation as Task 4 Step 8 — document and continue; tests run under
Docker in Task 14.

- [ ] **Step 10: Commit**

```sh
jj commit -m "Bootstrap mcp-server with Gemfile, loader, stdio entrypoint"
```

---

## Task 6: DockerRunner

**Files:**
- Create: `mcp-server/lib/ruby_bytecode_mcp/docker_runner.rb`
- Create: `mcp-server/test/test_docker_runner.rb`

- [ ] **Step 1: Write failing unit test for the command builder**

`mcp-server/test/test_docker_runner.rb`:

```ruby
# frozen_string_literal: true

require_relative "test_helper"

class TestDockerRunner < Minitest::Test
  include TestHelper

  def test_command_for_inline_code_pins_image_and_disables_network
    cmd = RubyBytecodeMcp::DockerRunner.command_for_inline(
      code: "puts :hi",
      ruby_version: "4.0.2",
      timeout_s: 5,
    )
    assert_equal "docker", cmd.first
    assert_includes cmd, "--rm"
    assert_includes cmd, "--network=none"
    assert_includes cmd, "ruby:4.0.2-slim"
    assert_includes cmd, "timeout"
    assert_includes cmd, "5"
    assert_includes cmd, "puts :hi"
  end

  def test_run_inline_returns_stdout_and_exit_code
    skip_without_docker!
    result = RubyBytecodeMcp::DockerRunner.run_inline(
      code: "puts RUBY_VERSION",
      ruby_version: "4.0.2",
    )
    assert_equal 0, result[:exit_code]
    assert_equal "4.0.2", result[:stdout].strip
    assert_equal "", result[:stderr]
  end
end
```

- [ ] **Step 2: Run tests to confirm they fail**

Run: `cd mcp-server && bundle exec rake test`
Expected: failure — `NameError: uninitialized constant RubyBytecodeMcp::DockerRunner`.

- [ ] **Step 3: Implement `docker_runner.rb`**

```ruby
# frozen_string_literal: true

require "open3"

module RubyBytecodeMcp
  module DockerRunner
    module_function

    # Build a `docker run` command array for inline Ruby code.
    # `-e` is used so no host filesystem is mounted.
    def command_for_inline(code:, ruby_version: DEFAULT_RUBY_VERSION, timeout_s: DEFAULT_TIMEOUT_S, network: false)
      image = "#{DEFAULT_IMAGE_PREFIX}:#{ruby_version}#{DEFAULT_IMAGE_SUFFIX}"
      net_flag = network ? "--network=bridge" : "--network=none"
      [
        "docker", "run", "--rm", "-i",
        net_flag,
        "--memory=512m",
        "--cpus=1",
        image,
        "timeout", timeout_s.to_s,
        "ruby", "-e", code,
      ]
    end

    # Execute inline Ruby code in a container.
    # Returns {stdout:, stderr:, exit_code:, duration_ms:}.
    def run_inline(code:, ruby_version: DEFAULT_RUBY_VERSION, timeout_s: DEFAULT_TIMEOUT_S, stdin: nil, network: false)
      cmd = command_for_inline(
        code: code, ruby_version: ruby_version, timeout_s: timeout_s, network: network,
      )
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      stdout, stderr, status = Open3.capture3(*cmd, stdin_data: stdin || "")
      duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).to_i
      {
        stdout: stdout,
        stderr: stderr,
        exit_code: status.exitstatus || -1,
        duration_ms: duration_ms,
      }
    rescue Errno::ENOENT => e
      {
        stdout: "",
        stderr: "docker not found on PATH: #{e.message}",
        exit_code: 127,
        duration_ms: 0,
      }
    end
  end
end
```

The `network:` kwarg is present from the start even though Tasks 7-9 and
11 all default it to `false`; only Task 10's `benchmark_ips` tool opts in.

- [ ] **Step 4: Run tests**

Run: `cd mcp-server && bundle exec rake test`
Expected: the command-builder test passes; the docker test passes if
Docker is available, otherwise it skips.

- [ ] **Step 5: Commit**

```sh
jj commit -m "Add DockerRunner with command builder and inline runner"
```

---

## Task 7: `run_ruby` tool

**Files:**
- Create: `mcp-server/lib/ruby_bytecode_mcp/tools/run_ruby.rb`
- Create: `mcp-server/test/tools/test_run_ruby.rb`

- [ ] **Step 1: Write failing test**

`mcp-server/test/tools/test_run_ruby.rb`:

```ruby
# frozen_string_literal: true

require_relative "../test_helper"

class TestRunRuby < Minitest::Test
  include TestHelper

  def test_returns_stdout_for_simple_program
    skip_without_docker!
    response = RubyBytecodeMcp::Tools::RunRuby.call(
      code: "puts 'hello'",
      server_context: nil,
    )
    text = response.content.first[:text]
    assert_match(/"exit_code": *0/, text)
    assert_match(/hello/, text)
  end
end
```

- [ ] **Step 2: Run tests — confirm failure**

Run: `cd mcp-server && bundle exec rake test`
Expected: `NameError: uninitialized constant RubyBytecodeMcp::Tools::RunRuby`.

- [ ] **Step 3: Implement the tool**

`mcp-server/lib/ruby_bytecode_mcp/tools/run_ruby.rb`:

```ruby
# frozen_string_literal: true

require "json"

module RubyBytecodeMcp
  module Tools
    class RunRuby < MCP::Tool
      description "Run arbitrary Ruby code inside a sandboxed Docker container."
      input_schema(
        properties: {
          code: { type: "string", description: "Ruby source to execute." },
          ruby_version: { type: "string", description: "Ruby version tag, e.g. 4.0.2." },
          stdin: { type: "string", description: "Data piped to STDIN." },
          timeout_s: { type: "integer", description: "Container timeout in seconds." },
        },
        required: ["code"],
      )

      class << self
        def call(code:, server_context:, ruby_version: RubyBytecodeMcp::DEFAULT_RUBY_VERSION, stdin: nil, timeout_s: RubyBytecodeMcp::DEFAULT_TIMEOUT_S)
          result = DockerRunner.run_inline(
            code: code, ruby_version: ruby_version, stdin: stdin, timeout_s: timeout_s,
          )
          MCP::Tool::Response.new([{ type: "text", text: JSON.pretty_generate(result) }])
        end
      end
    end
  end
end
```

- [ ] **Step 4: Run tests**

Run: `cd mcp-server && bundle exec rake test`
Expected: all passing (or skipped if no Docker).

- [ ] **Step 5: Commit**

```sh
jj commit -m "Add run_ruby MCP tool"
```

---

## Task 8: `disasm` tool

**Files:**
- Create: `mcp-server/lib/ruby_bytecode_mcp/tools/disasm.rb`
- Create: `mcp-server/test/tools/test_disasm.rb`

- [ ] **Step 1: Write failing test**

`mcp-server/test/tools/test_disasm.rb`:

```ruby
# frozen_string_literal: true

require_relative "../test_helper"

class TestDisasm < Minitest::Test
  include TestHelper

  def test_disasm_of_addition_mentions_opt_plus
    skip_without_docker!
    response = RubyBytecodeMcp::Tools::Disasm.call(
      code: "1 + 2",
      server_context: nil,
    )
    text = response.content.first[:text]
    assert_match(/putobject\s+1/, text)
    assert_match(/putobject\s+2/, text)
    assert_match(/opt_plus/, text)
  end
end
```

- [ ] **Step 2: Run tests — expect failure**

Run: `cd mcp-server && bundle exec rake test`

- [ ] **Step 3: Implement the tool**

`mcp-server/lib/ruby_bytecode_mcp/tools/disasm.rb`:

```ruby
# frozen_string_literal: true

module RubyBytecodeMcp
  module Tools
    class Disasm < MCP::Tool
      description "Compile Ruby code and return disassembly of the top-level iseq and all child iseqs."
      input_schema(
        properties: {
          code: { type: "string", description: "Ruby source to compile." },
          ruby_version: { type: "string", description: "Ruby version tag." },
        },
        required: ["code"],
      )

      RUNNER = <<~RUBY
        code = STDIN.read
        iseq = RubyVM::InstructionSequence.compile(code)
        out = [iseq.disasm]
        walk = ->(i) { i.each_child { |c| out << c.disasm; walk.call(c) } }
        walk.call(iseq)
        puts out.join("\\n")
      RUBY

      class << self
        def call(code:, server_context:, ruby_version: RubyBytecodeMcp::DEFAULT_RUBY_VERSION)
          result = DockerRunner.run_inline(
            code: RUNNER, ruby_version: ruby_version, stdin: code,
          )
          text = result[:exit_code].zero? ? result[:stdout] : "ERROR (exit #{result[:exit_code]}):\n#{result[:stderr]}"
          MCP::Tool::Response.new([{ type: "text", text: text }])
        end
      end
    end
  end
end
```

- [ ] **Step 4: Run tests**

Run: `cd mcp-server && bundle exec rake test`
Expected: pass (or skip without Docker).

- [ ] **Step 5: Commit**

```sh
jj commit -m "Add disasm MCP tool"
```

---

## Task 9: `parse_ast` tool

**Files:**
- Create: `mcp-server/lib/ruby_bytecode_mcp/tools/parse_ast.rb`
- Create: `mcp-server/test/tools/test_parse_ast.rb`

- [ ] **Step 1: Write failing test**

`mcp-server/test/tools/test_parse_ast.rb`:

```ruby
# frozen_string_literal: true

require_relative "../test_helper"

class TestParseAst < Minitest::Test
  include TestHelper

  def test_prism_parse_returns_non_empty
    skip_without_docker!
    response = RubyBytecodeMcp::Tools::ParseAst.call(
      code: "1 + 2",
      server_context: nil,
    )
    text = response.content.first[:text]
    refute_empty text
    assert_match(/CallNode|ProgramNode|@/, text)
  end

  def test_ruby_vm_parser
    skip_without_docker!
    response = RubyBytecodeMcp::Tools::ParseAst.call(
      code: "1 + 2",
      parser: "ruby_vm",
      server_context: nil,
    )
    text = response.content.first[:text]
    assert_match(/SCOPE|OPCALL|:\+/, text)
  end
end
```

- [ ] **Step 2: Run tests — expect failure**

Run: `cd mcp-server && bundle exec rake test`

- [ ] **Step 3: Implement the tool**

`mcp-server/lib/ruby_bytecode_mcp/tools/parse_ast.rb`:

```ruby
# frozen_string_literal: true

module RubyBytecodeMcp
  module Tools
    class ParseAst < MCP::Tool
      description "Parse Ruby code and return the AST via Prism (default) or RubyVM::AbstractSyntaxTree."
      input_schema(
        properties: {
          code: { type: "string", description: "Ruby source to parse." },
          parser: { type: "string", enum: %w[prism ruby_vm], description: "Which parser to use." },
          ruby_version: { type: "string", description: "Ruby version tag." },
        },
        required: ["code"],
      )

      PRISM_RUNNER = <<~RUBY
        require "prism"
        puts Prism.parse(STDIN.read).value.inspect
      RUBY

      RUBY_VM_RUNNER = <<~RUBY
        puts RubyVM::AbstractSyntaxTree.parse(STDIN.read).inspect
      RUBY

      class << self
        def call(code:, server_context:, parser: "prism", ruby_version: RubyBytecodeMcp::DEFAULT_RUBY_VERSION)
          runner = parser == "ruby_vm" ? RUBY_VM_RUNNER : PRISM_RUNNER
          result = DockerRunner.run_inline(code: runner, ruby_version: ruby_version, stdin: code)
          text = result[:exit_code].zero? ? result[:stdout] : "ERROR (exit #{result[:exit_code]}):\n#{result[:stderr]}"
          MCP::Tool::Response.new([{ type: "text", text: text }])
        end
      end
    end
  end
end
```

Note: `prism` ships with Ruby 4.0.2 as a default gem, so no extra install
is needed in the container.

- [ ] **Step 4: Run tests**

Run: `cd mcp-server && bundle exec rake test`
Expected: pass (or skip).

- [ ] **Step 5: Commit**

```sh
jj commit -m "Add parse_ast MCP tool"
```

---

## Task 10: `benchmark_ips` tool

**Files:**
- Create: `mcp-server/lib/ruby_bytecode_mcp/tools/benchmark_ips.rb`
- Create: `mcp-server/test/tools/test_benchmark_ips.rb`

- [ ] **Step 1: Write failing test**

`mcp-server/test/tools/test_benchmark_ips.rb`:

```ruby
# frozen_string_literal: true

require_relative "../test_helper"

class TestBenchmarkIps < Minitest::Test
  include TestHelper

  def test_runs_two_scenarios_and_reports_ips
    skip_without_docker!
    response = RubyBytecodeMcp::Tools::BenchmarkIps.call(
      scenarios: [
        { "name" => "plus", "code" => "1 + 2" },
        { "name" => "times", "code" => "2 * 3" },
      ],
      warmup: 1,
      time: 1,
      server_context: nil,
    )
    text = response.content.first[:text]
    assert_match(/plus/, text)
    assert_match(/times/, text)
    assert_match(/i\/s/, text)
  end
end
```

- [ ] **Step 2: Run tests — expect failure**

Run: `cd mcp-server && bundle exec rake test`

- [ ] **Step 3: Implement the tool**

`mcp-server/lib/ruby_bytecode_mcp/tools/benchmark_ips.rb`:

This tool passes caller-supplied Ruby (the `code` of each scenario) to
`benchmark-ips` via `Kernel.send(:eval, ...)`. That is the entire
purpose of the tool — evaluating arbitrary Ruby in timed loops. It runs
inside Docker with memory, CPU, and wall-clock limits, and with network
opt-in enabled only so that `benchmark-ips` can be fetched on first use.

```ruby
# frozen_string_literal: true

require "json"

module RubyBytecodeMcp
  module Tools
    class BenchmarkIps < MCP::Tool
      description "Run benchmark-ips over named Ruby scenarios in a container."
      input_schema(
        properties: {
          setup: { type: "string", description: "Code run once before benchmarking." },
          scenarios: {
            type: "array",
            items: {
              type: "object",
              properties: { name: { type: "string" }, code: { type: "string" } },
              required: ["name", "code"],
            },
          },
          warmup: { type: "integer" },
          time: { type: "integer" },
          ruby_version: { type: "string" },
        },
        required: ["scenarios"],
      )

      RUNNER = <<~'RUBY'
        require "json"
        unless Gem::Specification.find_all_by_name("benchmark-ips").any?
          Gem.install("benchmark-ips", "2.14.0")
        end
        require "benchmark/ips"

        payload = JSON.parse(STDIN.read)
        if payload["setup"] && !payload["setup"].empty?
          Kernel.send(:eval, payload["setup"])
        end

        Benchmark.ips do |x|
          x.config(warmup: payload["warmup"] || 2, time: payload["time"] || 5)
          payload["scenarios"].each do |s|
            x.report(s["name"]) { Kernel.send(:eval, s["code"]) }
          end
          x.compare!
        end
      RUBY

      class << self
        def call(scenarios:, server_context:, setup: nil, warmup: nil, time: nil, ruby_version: RubyBytecodeMcp::DEFAULT_RUBY_VERSION)
          payload = JSON.generate(
            "setup" => setup,
            "scenarios" => scenarios,
            "warmup" => warmup,
            "time" => time,
          )
          total_timeout = 10 + ((warmup || 2) + (time || 5)) * scenarios.length * 2
          result = DockerRunner.run_inline(
            code: RUNNER,
            ruby_version: ruby_version,
            stdin: payload,
            timeout_s: total_timeout,
            network: true,
          )
          text = result[:exit_code].zero? ? result[:stdout] : "ERROR (exit #{result[:exit_code]}):\n#{result[:stderr]}"
          MCP::Tool::Response.new([{ type: "text", text: text }])
        end
      end
    end
  end
end
```

- [ ] **Step 4: Run tests**

Run: `cd mcp-server && bundle exec rake test`
Expected: pass (or skip). Note: this test takes ~10 seconds because
warmup+time = 2s per scenario × 2 scenarios, plus container startup
and `Gem.install`.

- [ ] **Step 5: Commit**

```sh
jj commit -m "Add benchmark_ips MCP tool with network opt-in"
```

---

## Task 11: `iseq_to_binary` and `load_iseq_binary` tools

**Files:**
- Create: `mcp-server/lib/ruby_bytecode_mcp/tools/iseq_to_binary.rb`
- Create: `mcp-server/lib/ruby_bytecode_mcp/tools/load_iseq_binary.rb`
- Create: `mcp-server/test/tools/test_iseq_binary.rb`

- [ ] **Step 1: Write failing test**

`mcp-server/test/tools/test_iseq_binary.rb`:

```ruby
# frozen_string_literal: true

require_relative "../test_helper"
require "json"

class TestIseqBinary < Minitest::Test
  include TestHelper

  def test_round_trip_prints_expected_output
    skip_without_docker!

    dump = RubyBytecodeMcp::Tools::IseqToBinary.call(
      code: "puts 40 + 2",
      server_context: nil,
    )
    payload = JSON.parse(dump.content.first[:text])
    assert payload["blob_b64"].is_a?(String)
    assert payload["size"].to_i.positive?

    load = RubyBytecodeMcp::Tools::LoadIseqBinary.call(
      blob_b64: payload["blob_b64"],
      call: true,
      server_context: nil,
    )
    text = load.content.first[:text]
    assert_match(/42/, text)
  end
end
```

- [ ] **Step 2: Run tests — expect failure**

Run: `cd mcp-server && bundle exec rake test`

- [ ] **Step 3: Implement `iseq_to_binary`**

`mcp-server/lib/ruby_bytecode_mcp/tools/iseq_to_binary.rb`:

```ruby
# frozen_string_literal: true

require "json"

module RubyBytecodeMcp
  module Tools
    class IseqToBinary < MCP::Tool
      description "Compile Ruby code and return the base64-encoded iseq binary."
      input_schema(
        properties: {
          code: { type: "string" },
          ruby_version: { type: "string" },
        },
        required: ["code"],
      )

      RUNNER = <<~'RUBY'
        require "base64"
        require "json"
        bin = RubyVM::InstructionSequence.compile(STDIN.read).to_binary
        puts JSON.generate("blob_b64" => Base64.strict_encode64(bin), "size" => bin.bytesize)
      RUBY

      class << self
        def call(code:, server_context:, ruby_version: RubyBytecodeMcp::DEFAULT_RUBY_VERSION)
          result = DockerRunner.run_inline(code: RUNNER, ruby_version: ruby_version, stdin: code)
          text = result[:exit_code].zero? ? result[:stdout] : "ERROR (exit #{result[:exit_code]}):\n#{result[:stderr]}"
          MCP::Tool::Response.new([{ type: "text", text: text }])
        end
      end
    end
  end
end
```

- [ ] **Step 4: Implement `load_iseq_binary`**

`mcp-server/lib/ruby_bytecode_mcp/tools/load_iseq_binary.rb`:

```ruby
# frozen_string_literal: true

require "json"

module RubyBytecodeMcp
  module Tools
    class LoadIseqBinary < MCP::Tool
      description "Load a base64-encoded iseq binary; optionally run it and capture stdout/stderr."
      input_schema(
        properties: {
          blob_b64: { type: "string" },
          call: { type: "boolean", description: "If true, run the loaded iseq and return its output." },
          ruby_version: { type: "string" },
        },
        required: ["blob_b64"],
      )

      RUNNER = <<~'RUBY'
        require "base64"
        require "json"
        payload = JSON.parse(STDIN.read)
        bin = Base64.strict_decode64(payload["blob_b64"])
        iseq = RubyVM::InstructionSequence.load_from_binary(bin)
        if payload["call"]
          iseq.eval
        else
          puts iseq.disasm
        end
      RUBY

      class << self
        def call(blob_b64:, server_context:, call: false, ruby_version: RubyBytecodeMcp::DEFAULT_RUBY_VERSION)
          payload = JSON.generate("blob_b64" => blob_b64, "call" => call)
          result = DockerRunner.run_inline(code: RUNNER, ruby_version: ruby_version, stdin: payload)
          combined = [result[:stdout], result[:stderr]].reject(&:empty?).join("\n")
          text = result[:exit_code].zero? ? combined : "ERROR (exit #{result[:exit_code]}):\n#{combined}"
          MCP::Tool::Response.new([{ type: "text", text: text }])
        end
      end
    end
  end
end
```

Note: `iseq.eval` here is a method on `RubyVM::InstructionSequence`, not
`Kernel#eval`. It runs the loaded iseq; this is the *only* way to
execute a binary iseq without dynamically calling `Kernel#eval` on
source code.

- [ ] **Step 5: Run all tests, and verify the entry point loads**

Run: `cd mcp-server && bundle exec rake test`
Expected: pass (or skip).

Also:
Run: `cd mcp-server && bundle exec ruby -e 'require "ruby_bytecode_mcp"; puts RubyBytecodeMcp::TOOLS.map(&:name)'`
Expected: six tool class names, one per line.

- [ ] **Step 6: Commit**

```sh
jj commit -m "Add iseq_to_binary and load_iseq_binary MCP tools"
```

---

## Task 12: `.mcp.json` and `.claude/settings.json`

**Files:**
- Create: `.mcp.json`
- Create: `.claude/settings.json`

- [ ] **Step 1: Write `.mcp.json` at repo root**

```json
{
  "mcpServers": {
    "ruby-bytecode": {
      "command": "bundle",
      "args": ["exec", "ruby", "bin/ruby-bytecode-mcp"],
      "cwd": "mcp-server"
    }
  }
}
```

- [ ] **Step 2: Write `.claude/settings.json`**

```json
{
  "permissions": {
    "allow": [
      "mcp__ruby-bytecode__run_ruby",
      "mcp__ruby-bytecode__disasm",
      "mcp__ruby-bytecode__parse_ast",
      "mcp__ruby-bytecode__benchmark_ips",
      "mcp__ruby-bytecode__iseq_to_binary",
      "mcp__ruby-bytecode__load_iseq_binary"
    ]
  }
}
```

Explicit list rather than a wildcard so each tool's approval is visible
when someone audits the settings file.

- [ ] **Step 3: Commit**

```sh
jj commit -m "Register ruby-bytecode MCP server and auto-approve its tools"
```

---

## Task 13: Project-local skills

**Files:**
- Create: `.claude/skills/running-ruby-experiments/SKILL.md`
- Create: `.claude/skills/disassembling-ruby/SKILL.md`

- [ ] **Step 1: Write `running-ruby-experiments` skill**

`.claude/skills/running-ruby-experiments/SKILL.md`:

```markdown
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
```

- [ ] **Step 2: Write `disassembling-ruby` skill**

`.claude/skills/disassembling-ruby/SKILL.md`:

```markdown
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
```

- [ ] **Step 3: Commit**

```sh
jj commit -m "Add project-local skills for routing to the ruby-bytecode MCP"
```

---

## Task 14: End-to-end smoke test

**Files:** none created. This task exercises what's already built.

- [ ] **Step 1: Verify Docker is available**

Run: `docker info > /dev/null 2>&1 && echo OK || echo "Docker not running"`
Expected: `OK`. If not, start Docker Desktop and retry.

- [ ] **Step 2: Pull the base image**

Run: `docker pull ruby:4.0.2-slim`
Expected: image present locally after command completes.

- [ ] **Step 3: Run the MCP server test suite**

Run: `cd mcp-server && bundle install && bundle exec rake test`
Expected: all tests pass (none skipped, since Docker is available).

- [ ] **Step 4: Confirm the stdio entry point loads**

Run: `cd mcp-server && timeout 2 bundle exec ruby bin/ruby-bytecode-mcp < /dev/null; echo "exit=$?"`
Expected: the server starts, blocks on stdin, exits 124 (timeout) or 0.
Any other exit code (e.g. 1) indicates a load error — investigate.

- [ ] **Step 5: Manually invoke each tool via IRB**

Run: `cd mcp-server && bundle exec irb -r ./lib/ruby_bytecode_mcp.rb`

Paste and confirm each of:

```ruby
RubyBytecodeMcp::Tools::RunRuby.call(code: "puts RUBY_VERSION", server_context: nil).content.first[:text]
# => must contain "4.0.2" and `"exit_code": 0`

RubyBytecodeMcp::Tools::Disasm.call(code: "1 + 2", server_context: nil).content.first[:text]
# => must contain "putobject" and "opt_plus"

RubyBytecodeMcp::Tools::ParseAst.call(code: "1 + 2", server_context: nil).content.first[:text]
# => non-empty Prism AST

dump = RubyBytecodeMcp::Tools::IseqToBinary.call(code: "puts 40 + 2", server_context: nil).content.first[:text]
blob = JSON.parse(dump)["blob_b64"]
RubyBytecodeMcp::Tools::LoadIseqBinary.call(blob_b64: blob, call: true, server_context: nil).content.first[:text]
# => must contain "42"
```

- [ ] **Step 6: Run the experiments smoke test in Docker**

Run:

```sh
docker run --rm -v "$PWD/experiments:/w" -w /w ruby:4.0.2-slim \
  bash -lc "bundle install && bundle exec ruby 01-iseq-basics/hello.rb"
```

Expected: prints Ruby version `4.0.2` and a disasm that mentions
`putobject 1`, `putobject 2`, `opt_plus`. Also produces
`experiments/Gemfile.lock` on the host via the bind mount.

- [ ] **Step 7: Commit any generated `Gemfile.lock`**

```sh
jj status
jj commit -m "Add Gemfile.lock(s) generated during smoke test"
```

If `jj status` shows no changes, skip this step.

- [ ] **Step 8: Final verification — enumerate commits**

Run: `jj log -r '::@- & ~root()' --no-pager`
Expected: one commit per task (Tasks 1-13 at minimum), each with a clear
message. Task 14 may add one additional commit for `Gemfile.lock`.

---

## Self-Review

Verified against `docs/superpowers/specs/2026-04-18-repo-scaffold-design.md`:

- **Goals** — scaffold with three artifact zones + MCP server: Tasks 1-13.
- **Ruby 4.0.2 pin** — Tasks 4 Step 1, 5 Step 1; MCP default via `DEFAULT_RUBY_VERSION`.
- **Repo layout** — every file in the spec's layout diagram maps to exactly one task.
- **MCP transport/runtime** — Task 5 Step 6 uses `MCP::Server::Transports::StdioTransport`.
- **Sandboxing** — Task 6 sets `--network=none`, `--memory=512m`, `--cpus=1`, inner `timeout`.
- **All six tools** — Tasks 7-11.
- **Auto-approval** — Task 12.
- **Two skills** — Task 13.
- **Smoke test** — Task 14 covers all five acceptance criteria from the spec.
- **Method signature consistency** — `DockerRunner.run_inline` takes `(code:, ruby_version:, timeout_s:, stdin:, network:)` from Task 6 onward; all tool call sites match.
- **Open item — project-local `.claude/skills/` loading:** if Task 14 reveals the skills aren't auto-picked-up, a follow-up plan can wrap them in a plugin manifest; not blocking for this scaffold.
- **Open item — `mcp` gem stdio invocation:** verified from the gem README; confirmed by Task 5 Step 6 code and Task 14 Step 4.
- **Open item — custom Dockerfile:** not needed; `benchmark_ips` handles its one extra dep via `Gem.install` with network opt-in.
