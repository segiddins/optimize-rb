# optimizer

Talk-artifact Ruby optimizer. Companion to
`docs/superpowers/specs/2026-04-19-optimizer.md`.

## Status

- **Binary codec**: round-trippable decoder/encoder for YARB binaries.
  Modifications to `IR::Function#instructions` are re-encoded including
  length changes — passes can freely insert, delete, or replace instructions.
  `IR::Function` also carries decoded `#catch_entries`, `#line_entries`, and
  `#arg_positions` whose references to instructions are by identity, so they
  survive instruction-list mutation; the encoder resolves identity to
  current positions at emit time.
- **IR**: `IR::Function` (one per iseq), `IR::Instruction` (one per YARV op),
  `IR::BasicBlock` and `IR::CFG` for control-flow analysis.
- **Passes**: base class (`RubyOpt::Pass`), orchestrator (`RubyOpt::Pipeline`),
  hardcoded contract (`RubyOpt::Contract`), structured log (`RubyOpt::Log`).
  A `NoopPass` ships as proof-of-life. Real passes come in subsequent plans.
- **Type env**: `RubyOpt::RbsParser` extracts inline `@rbs` signatures;
  `RubyOpt::TypeEnv` exposes `#signature_for`.
- **Harness**: `RubyOpt::Harness::LoadIseqHook` installs a `load_iseq`
  override that runs the pipeline on every loaded file. Opt out with
  `# rbs-optimize: false` at the top of the file. Any failure falls back
  to MRI's built-in compilation.

## Passes

- `RubyOpt::Passes::ArithReassocPass` — arithmetic reassociation driven by
  the `REASSOC_OPS` table. Two rows today: `opt_plus` (identity 0, reducer `:+`)
  and `opt_mult` (identity 1, reducer `:*`). Collapses chains of one operator
  within a basic block where ≥2 operands are Integer literals, keeping non-literal
  operands in original order and emitting a single combined-literal tail. Reaches
  shapes const-fold cannot: `x + 1 + 2 + 3` → `x + 6`, `x * 2 * 3 * 4` → `x * 24`.
  Non-Integer literals, chains with <2 integer literals, and results that would
  fall outside `ObjectTable#special_const?`'s intern range are left alone
  (`:mixed_literal_types`, `:chain_too_short`, `:would_exceed_intern_range`).
  An outer any-rewrite fixpoint wraps the per-operator inner fixpoints so a
  mult rewrite can expose a `+` chain (e.g., `x + 2 * 3 + 4` → `x + 10`).
  Mixed same-precedence chains (`+`/`-`, `*`/`/`) and `**` are out of scope;
  see follow-up plans.
- `RubyOpt::Passes::ConstFoldPass` — tier 1 constant folding. Folds
  Integer literal arithmetic (`+ - * / %`) and Integer literal
  comparison (`< <= > >= == !=`) triples within a basic block,
  iterating until no more folds fire. Division/modulo by zero and
  non-Integer literal operands are left alone and logged
  (`:would_raise`, `:non_integer_literal`). The default pipeline runs
  `ConstFoldPass` only; inlining, arithmetic specialization, and
  higher tiers of const-fold are future plans.

## Running tests

Tests run inside a Ruby 4.0.2 Docker container via the repo's MCP server
(see `mcp-server/`). From a Claude Code session, use the
`mcp__ruby-bytecode__run_optimizer_tests` tool.

Or, on a host with Ruby 4.0.2 and Docker:

    cd optimizer
    bundle install
    bundle exec rake test

## Layout

- `lib/ruby_opt/codec/` — YARB binary surgery
- `lib/ruby_opt/ir/` — `Function`, `Instruction`, `BasicBlock`, `CFG`
- `lib/ruby_opt/pass.rb` — Pass base class + NoopPass
- `lib/ruby_opt/pipeline.rb` — pass orchestration
- `lib/ruby_opt/contract.rb` — the hardcoded ground rules
- `lib/ruby_opt/log.rb` — structured optimizer log
- `lib/ruby_opt/rbs_parser.rb` — inline `@rbs` extraction
- `lib/ruby_opt/type_env.rb` — typed-environment queries
- `lib/ruby_opt/harness.rb` — `load_iseq` override
- `test/` — minitest suites, fixtures under `test/harness_fixtures/`

## The round-trip contract

For any iseq produced by `RubyVM::InstructionSequence#to_binary`:

    encode(decode(bin)) == bin  (byte-identical)

Any input that doesn't round-trip is a codec bug. Modifications to the
decoded IR are applied on re-encode via IR-driven serialization of the
body record and data regions; length-changing edits cascade through the
header and object-table offsets automatically.
