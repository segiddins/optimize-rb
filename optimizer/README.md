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
- **Passes**: base class (`Optimize::Pass`), orchestrator (`Optimize::Pipeline`),
  hardcoded contract (`Optimize::Contract`), structured log (`Optimize::Log`).
  A `NoopPass` ships as proof-of-life. Real passes come in subsequent plans.
- **Type env**: `Optimize::RbsParser` extracts inline `@rbs` signatures;
  `Optimize::TypeEnv` exposes `#signature_for`.
- **Harness**: `Optimize::Harness::LoadIseqHook` installs a `load_iseq`
  override that runs the pipeline on every loaded file. Opt out with
  `# rbs-optimize: false` at the top of the file. Any failure falls back
  to MRI's built-in compilation.

## Passes

- `Optimize::Passes::ArithReassocPass` — arithmetic reassociation driven by
  the `REASSOC_GROUPS` table. Two groups today: the additive group
  (`opt_plus` identity 0, `opt_minus` with sign `-`, primary `opt_plus`,
  kind `:abelian`) and the multiplicative group (`opt_mult` identity 1,
  `opt_div` secondary, primary `opt_mult`, kind `:ordered`). The
  `:abelian` algorithm partitions non-literal operands by effective sign
  and injects literals through a single combiner. The `:ordered`
  algorithm walks the chain left-to-right with a single literal
  accumulator, coalescing contiguous same-op literal runs (`* L1 * L2`
  or `/ L1 / L2`) but refusing to fold across a `*`/`/` boundary —
  required because Ruby integer `/` is floor-division, so
  `(a * L1) / L2 ≠ a * (L1 / L2)` in general. Reaches shapes
  const-fold cannot: `x + 1 + 2 + 3` → `x + 6`, `x + 1 - 2 + 3` → `x + 2`,
  `x * 2 * 3 * 4` → `x * 24`, `x + 1 - y + 2` → `x - y + 3`,
  `x / 2 / 3` → `x / 6`, `x * 2 * 3 / 4 / 5` → `x * 6 / 20`. Non-Integer
  literals, chains with <2 integer literals, results that would exceed
  the `ObjectTable#intern` range, additive chains where all non-literals
  have effective sign `-`, multiplicative chains with any `≤0` literal
  divisor, and multiplicative chains whose walk produces no fold are
  left alone (`:mixed_literal_types`, `:chain_too_short`,
  `:would_exceed_intern_range`, `:no_positive_nonliteral`,
  `:unsafe_divisor`, `:no_change`). An outer any-rewrite fixpoint wraps
  the per-group inner fixpoints so mult rewrites expose additive chains
  (e.g., `x + 2 * 3 - 4` → `x + 2`). `**` and exact-divisibility folds
  (e.g. `x * 6 / 2 → x * 3`) are out of scope; see follow-up plans.
- `Optimize::Passes::ConstFoldPass` — tier 1 constant folding. Folds
  Integer literal arithmetic (`+ - * / %`) and Integer literal
  comparison (`< <= > >= == !=`) triples within a basic block,
  iterating until no more folds fire. Division/modulo by zero and
  non-Integer literal operands are left alone and logged
  (`:would_raise`, `:non_integer_literal`). The default pipeline runs
  `ConstFoldPass` only; inlining, arithmetic specialization, and
  higher tiers of const-fold are future plans.
- `Optimize::Passes::IdentityElimPass` — strips arithmetic identities the
  upstream passes leave behind: `x * 1`, `1 * x`, `x + 0`, `0 + x`,
  `x - 0`, `x / 1`. Driven by the `IDENTITY_OPS` table, which encodes
  each operator's identity element and which sides are eligible
  (`:either` for commutative `+`/`*`, `:right` only for `-`/`/` since
  `0 - x = -x` and `1 / x ≠ x`). Fires only when the non-literal side
  is in `SAFE_PRODUCER_OPCODES` (shared with `ArithReassocPass`), so
  no potentially-side-effecting producer (a `send`, `invokesuper`,
  etc.) is ever elided. Integer-literal-only: `x * 1.0` is left alone
  (float identities have `-0.0` / `NaN` edge cases worth their own
  pass). The pass is *sound in practice, not sound in principle*: for
  a receiver whose class does not treat the operator as an identity
  (e.g. `"abc" + 0` raises `TypeError`; `[1,2] * 1` returns a copy),
  eliding the op changes observable behavior. We take the same bet
  CRuby's `opt_*` fast paths take — numeric operands, specialized
  shape. Completes the three-pass collapse for `2 * 3 / 6 * x` → `x`.

## Running tests

Tests run inside a Ruby 4.0.2 Docker container via the repo's MCP server
(see `mcp-server/`). From a Claude Code session, use the
`mcp__ruby-bytecode__run_optimizer_tests` tool.

Or, on a host with Ruby 4.0.2 and Docker:

    cd optimizer
    bundle install
    bundle exec rake test

## Layout

- `lib/optimize/codec/` — YARB binary surgery
- `lib/optimize/ir/` — `Function`, `Instruction`, `BasicBlock`, `CFG`
- `lib/optimize/pass.rb` — Pass base class + NoopPass
- `lib/optimize/pipeline.rb` — pass orchestration
- `lib/optimize/contract.rb` — the hardcoded ground rules
- `lib/optimize/log.rb` — structured optimizer log
- `lib/optimize/rbs_parser.rb` — inline `@rbs` extraction
- `lib/optimize/type_env.rb` — typed-environment queries
- `lib/optimize/harness.rb` — `load_iseq` override
- `test/` — minitest suites, fixtures under `test/harness_fixtures/`

## The round-trip contract

For any iseq produced by `RubyVM::InstructionSequence#to_binary`:

    encode(decode(bin)) == bin  (byte-identical)

Any input that doesn't round-trip is a codec bug. Modifications to the
decoded IR are applied on re-encode via IR-driven serialization of the
body record and data regions; length-changing edits cascade through the
header and object-table offsets automatically.
