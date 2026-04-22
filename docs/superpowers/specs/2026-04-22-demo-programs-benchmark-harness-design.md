# Demo programs wired with benchmark harness

**Status:** design
**Date:** 2026-04-22
**Roadmap item:** `docs/todo.md` §"Roadmap gap, ranked by talk-ROI" #2
**Talk section:** `2026-04-19-talk-structure-design.md` §5 "Demos"

## Purpose

Wire the two talk fixtures (`sum_of_squares` numeric kernel and
`Point#distance_to` object-y method) through an end-to-end pipeline
that produces committed slide-ready artifacts: unified iseq diffs
per curated pass and `benchmark-ips` numbers comparing harness-off
vs. `Pipeline.default`.

No live execution on stage. Artifacts are generated offline, reviewed
in PRs, and pasted into slides.

## Non-goals

- Live or pre-recorded stage execution. §5 is static slides only.
- Full-pipeline walkthrough on slides. Only a hand-curated subset per
  fixture reaches the walkthrough section; the full `Pipeline.default`
  is the benchmark comparand but not slide content.
- Improving pass coverage of `Range#sum`-style idiomatic code. The
  `sum_of_squares` fixture uses an explicit `while` loop precisely
  because our passes don't cross block iseqs.
- A YAML-agnostic sidecar format. We accept the `psych` stdlib dep.

## Contract

The artifact story rests on two claims:

1. **Benchmark number honesty.** Iter/sec comparison runs the fixture
   through `Pipeline.default` — every shipped pass, not a curated
   subset. The "5x faster" headline matches what a user would see
   with the harness on.
2. **Walkthrough pedagogy honesty.** Walkthrough slides show a
   curated subset of passes chosen because they visibly change the
   iseq for that fixture. Framing on slides is "here are the three
   passes that most mattered on this code," not "here is every pass."

## Artifacts

Per fixture, one committed markdown file at
`docs/demo_artifacts/<stem>.md` with five sections, in order:

1. **Source** — fenced Ruby source of the fixture.
2. **Full-delta summary** — one paragraph stating plain iter/sec vs
   optimized iter/sec, followed by the `benchmark-ips` comparison
   block (the "x.xx slower" line).
3. **Walkthrough** — one subsection per pass in the curated
   `walkthrough` list, each with:
   - pass name + one-sentence description
   - unified diff of iseq text (`-`/`+`/context lines) showing the
     delta introduced by this pass on top of the prefix before it
4. **Appendix: full iseq dumps** — "before" (unoptimized) and
   "after full `Pipeline.default`" as fenced blocks.
5. **Raw benchmark output** — full `benchmark-ips` stdout.

## File layout

```
optimizer/
  bin/
    demo                             # driver script, executable
  examples/
    point_distance.rb                # fixture (modified; see §Fixtures)
    point_distance.walkthrough.yml
    sum_of_squares.rb                # new fixture
    sum_of_squares.walkthrough.yml
docs/
  demo_artifacts/
    point_distance.md                # generated, committed
    sum_of_squares.md                # generated, committed
```

## Walkthrough sidecar format

```yaml
# examples/point_distance.walkthrough.yml
fixture: point_distance.rb
entry_setup: |
  p = Point.new(1, 2)
  q = Point.new(4, 6)
entry_call: p.distance_to(q)
walkthrough:
  - inlining
  - const_fold_tier1
  - dead_branch_fold
```

- `fixture` is a filename relative to `examples/`.
- `entry_setup` is evaluated once per `benchmark-ips` run, outside the
  timing block.
- `entry_call` is the per-iteration expression under measurement.
- `walkthrough` is an ordered list of symbolic pass names that must
  match `pass.name` for passes present in `Pipeline.default`.

Unknown names fail loudly at driver startup via the sidecar
validation test (§Testing).

## Driver (`optimizer/bin/demo`)

Invocation: `bin/demo <stem>` (single fixture) or `bin/demo --all`.

Flow per fixture:

1. **Load YAML sidecar.** Validate `walkthrough` names against
   `Pipeline.default.map(&:name)`.
2. **Generate "before" iseq.** Compile the fixture via
   `RubyVM::InstructionSequence.compile_file` with the harness
   *not* installed. Disasm to text; store as `before_iseq`.
3. **Generate "after full pipeline" iseq.** Same source compiled
   with `RubyOpt::Harness` installed and `Pipeline.default`. Disasm;
   store as `after_full_iseq`.
4. **Per-pass snapshots.** For each prefix of `walkthrough` with
   length 1..N, construct `Pipeline.new(passes: <prefix>)`, re-parse
   fresh IR from the fixture, run, disasm. Store
   `snapshots[pass_name]`. N ≤ 5, so re-parsing N times is trivial
   offline.
5. **Run `benchmark-ips`.** Using the `benchmark-ips` gem
   in-process (`Benchmark.ips do |x| ...; x.compare!; end`). Two
   labeled reports:
   - `"plain"` — harness off
   - `"optimized"` — harness on, `Pipeline.default`

   Setup: `require_relative "<abspath to fixture>"` + `entry_setup`.
   Timed block: `entry_call`. `x.compare!` stdout captured via a
   tee'd `StringIO`.

   The driver script itself is run *through* the ruby-bytecode MCP
   `benchmark_ips` / `run_ruby` tools during development (per the
   project's sandboxed-execution convention), but the script's
   own benchmarking uses the gem directly.
6. **Render markdown.** Plain ERB or heredoc template; assemble the
   §Artifacts structure.
7. **Write** `docs/demo_artifacts/<stem>.md`.

### Disasm normalization for diffs

Raw disasm strings include PC-offset columns and iseq-header blocks
that shift on every rewrite. Diffing raw disasm would produce
bookkeeping noise that drowns the opcode changes.

The driver normalizes disasm before diffing: strip the leading PC
column and the iseq header. The normalized form shows opcode lines
only. Un-normalized "before"/"after full" dumps go in the
§Artifacts appendix for context.

### Dependencies

- `diff-lcs` — add to `optimizer/Gemfile`. ~Zero-cost gem, common.
- `benchmark-ips` — confirm present in `optimizer/Gemfile`; add if
  not. The ruby-bytecode MCP server wires it for its own
  `benchmark_ips` tool, but the driver script loads the gem
  in-process.
- `psych` — stdlib; no new dep.

## Fixtures

### `examples/point_distance.rb`

Modify existing. Strip the trailing
`p = Point.new(...); q = Point.new(...); 1_000_000.times { ... }`
block. File ends at the `end` of class `Point`. RBS inline comments
stay — RBS-v1 relies on them for receiver-resolving inlining.

### `examples/sum_of_squares.rb`

New file:

```ruby
# frozen_string_literal: true

# @rbs (Integer) -> Integer
def sum_of_squares(n)
  s = 0
  i = 1
  while i <= n
    s += i * i
    i += 1
  end
  s
end
```

No trailing call; the driver provides the entry expression via the
walkthrough sidecar.

### Walkthrough pass picks (tentative)

- `point_distance`: `inlining`, `const_fold_tier1`, `dead_branch_fold`
- `sum_of_squares`: `arith_reassoc`, `identity_elim`, `const_fold_tier1`

These are guesses based on `docs/todo.md`'s coverage claims. Actual
picks are locked during implementation by running each pass against
each fixture and picking the three with the largest visible iseq
delta. The design locks the *mechanism* for declaring picks, not the
picks themselves.

### Honest-numbers caveat

The `sum_of_squares` while-loop body is
`opt_mult; opt_plus; setlocal; getlocal; opt_plus; setlocal; opt_le;
branch*`. Our passes rewrite arithmetic operands but do not kill the
getlocal/setlocal churn that dominates the loop. The benchmark delta
will likely be modest (single-digit %). `point_distance` will
probably carry the larger delta thanks to inlining eliminating
method-call overhead. This is on-thesis for §5 ("honest numbers")
and §6 ("tradeoffs"); improving the `sum_of_squares` payoff is out
of scope for this spec and tracked as a possible follow-up.

## Testing

Three layers, in increasing cost:

1. **Driver unit test** (`optimizer/test/demo_driver_test.rb`).
   Runs driver logic against a tiny synthetic fixture defined inline
   in the test. Asserts: markdown has all five §Artifacts sections;
   walkthrough produces N snapshot subsections; YAML validation
   rejects an unknown pass name. Part of default `rake test`.
2. **Sidecar validation test.** Iterates `examples/*.walkthrough.yml`
   and asserts each declared `walkthrough` pass name exists in
   `Pipeline.default.map(&:name)`. Catches drift when a pass is
   renamed or removed. Part of default `rake test`.
3. **Artifact freshness check.** Opt-in `rake demo:verify`, also
   wired as a CI job on PRs that touch `optimizer/lib/` or
   `examples/`. Regenerates the committed artifacts in a tempdir
   and diffs against the committed files. Fails if they differ.
   Slow (runs `benchmark-ips`); not part of default `rake test`.

### Freshness check: masking nondeterministic output

`benchmark-ips` iter/sec numbers vary run-to-run. The freshness
diff masks the raw-benchmark section (§Artifacts #5) — the block is
replaced with `<benchmark output>` on both sides before diffing.
The comparison multiplier in §2 is stable enough across runs to
diff strictly. All iseq sections are deterministic and diffed
strictly.

Rationale: iseq diffs are the teaching artifact. A pass change that
moves opcodes must fail CI so the author re-runs `bin/demo --all`
and commits the regenerated markdown. The iter/sec number is
scenery; eyeballing it on the regenerated output during PR review is
sufficient.

## Out of scope (this spec)

- Improving the optimizer's pass coverage to raise the
  `sum_of_squares` benchmark delta. Tracked as open follow-up.
- Alternative fixtures beyond the two the talk names.
- A general-purpose "step through a pipeline" harness exposed as a
  library API. The driver is a demo-specific script, not a reusable
  debugging tool.
- Slide rendering. Driver outputs markdown; slide assembly happens
  elsewhere by hand.
