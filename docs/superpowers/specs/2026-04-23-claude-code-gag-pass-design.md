# Claude Code gag pass — design

**Status:** design
**Date:** 2026-04-23
**Talk section:** §7 (Close)
**Related spec:** `docs/superpowers/specs/2026-04-19-talk-structure-design.md`

## Purpose

§7 of the talk closes with a gag: a "pass" that shells out to Claude
Code and asks it to optimize an iseq. Self-deprecating, lands the "for
fun" frame, gestures at where tooling is going.

Concretely: we ship a real runnable demo driver that serializes an IR
function to a JSON array of YARV instructions, sends it to Claude via
`claude -p`, validates the response structurally and semantically, and
feeds validator errors back into Claude up to three times. The captured
transcript is committed as a demo artifact and projected during the
talk.

The pass lives **outside** `Pipeline.default`. It is not a production
optimizer pass; it is a single-purpose demo driver.

## Non-goals

- Being sound, useful, or performant as an optimizer.
- Being called from `Pipeline.default` or any production path.
- Live invocation during the talk. The talk projects the committed
  transcript; the live `claude -p` call happens at artifact-capture
  time only.

## Architecture

New namespace: `Optimize::Demo::Claude`. Driven by `bin/demo claude_gag`.

High-level flow:

1. Load fixture iseq via existing `Optimize::Harness`.
2. Serialize `IR::Function` to a JSON array of `[opcode_sym, *operands]`
   tuples.
3. Shell out to `claude -p --output-format json` with a prompt
   containing the IR JSON, the fixture source, and the expected return
   value.
4. Parse Claude's response, extract the JSON array, deserialize back
   into `IR::Function`.
5. Validate structurally (opcode exists in `RubyVM::INSTRUCTION_NAMES`,
   operand arity matches) then semantically (encode via codec, load
   into `RubyVM::InstructionSequence`, invoke, check return value).
6. On any failure: append the validator error to the conversation
   history, start a fresh `claude -p` call with the full history
   pasted into a single user message. Up to 3 total attempts.
7. Record every iteration (prompt, raw response, parsed IR, errors) in
   a transcript. Render to markdown.

## Components

| File | Responsibility |
|---|---|
| `optimizer/lib/optimize/demo/claude.rb` | Top-level orchestrator. Owns the retry loop. |
| `optimizer/lib/optimize/demo/claude/prompt.rb` | Builds initial + retry prompts. Holds opcode allowlist and JSON schema description. |
| `optimizer/lib/optimize/demo/claude/serializer.rb` | IR ↔ JSON array. Reuses locals/insns_info/line_entries from the original function. |
| `optimizer/lib/optimize/demo/claude/validator.rb` | `structural(ir)` and `semantic(ir, expected)`. Returns `[errors]`. |
| `optimizer/lib/optimize/demo/claude/invoker.rb` | `Open3.capture3("claude", "-p", "--output-format", "json", ...)`. Returns parsed JSON. Single responsibility: shell I/O. |
| `optimizer/lib/optimize/demo/claude/transcript.rb` | Append-only log. Renders markdown. |
| `optimizer/examples/claude_gag.rb` | Fixture: trivial method returning `2 + 3`. |
| `docs/demo_artifacts/claude_gag.md` | Committed transcript. |
| `docker/Dockerfile` | Installs `claude` CLI, accepts setup-token via env. |
| `Rakefile` | `demo:regenerate_claude` (opt-in, hits network). |

## Data flow

```
fixture.rb
  → Harness.compile
  → IR::Function (original)
  → Serializer#serialize → JSON array
  → Prompt#initial(ir_json, fixture_source, expected_return)
  ↓
  ┌─── Invoker.call(prompt_with_history) → raw JSON response
  │       ↓
  │     Serializer#deserialize → IR::Function (attempt)
  │       ↓
  │     Validator#structural(attempt) → [errors]
  │       ↓ (if clean)
  │     Validator#semantic(attempt, expected) → [errors]
  │       ↓
  │     Transcript.record(iteration, ...)
  │       ↓
  │   errors empty? ──yes──► SUCCESS
  │       │ no
  │       ↓
  │     Prompt#retry(errors) → append to history
  └────  iteration < 3? ──yes──► loop
          │ no
          ▼
        FAILURE: preserve original IR, mark transcript "gave up"
```

Each retry is a **fresh** `claude -p` call with the full conversation
pasted into a single user message. `claude -p` does not support
multi-turn input in one invocation; the loop lives in Ruby, not in a
Claude session.

## Serialization format

JSON array of tuples, one per instruction:

```json
[
  ["putobject", 2],
  ["putobject", 3],
  ["opt_plus", {"mid": "+", "argc": 1}],
  ["leave"]
]
```

- Opcode: string, corresponds to a `Symbol` in `RubyVM::INSTRUCTION_NAMES`.
- Operands: JSON-native values. Object-table indices (`TS_VALUE`/`TS_ID`)
  are resolved to their Ruby values during serialize; re-interned on
  deserialize. Call-data operands (`TS_CALLDATA`) become
  `{"mid": String, "argc": Integer, "flag": Integer}` objects.
  `TS_OFFSET`, `TS_LINDEX`, `TS_NUM` stay as integers.
- Locals, `insns_info`, line entries, catch table: **not** in the JSON.
  Carried over verbatim from the original function on deserialize.
  Claude does not get to rewrite iseq-level metadata.

## Prompt shape

Initial prompt (single user message):

```
You are given a YARV iseq as a JSON array of instructions. Emit a
semantically equivalent but optimized iseq.

Constraints:
- Output a single JSON array of [opcode_string, ...operands] tuples.
- Each opcode must be one of: <allowlist of ~30 common opcodes>.
- Preserve stack discipline: the iseq must end with a value on the
  stack consumed by `leave`.
- Do not add or remove locals; the local table is fixed.
- Do not emit call-data for sends you invent; only reuse call-data
  shapes present in the input.

Fixture source:
<ruby source of claude_gag.rb>

Expected return value: 5

Input iseq:
<JSON array>
```

Retry prompt (appended to initial + any prior retries, all sent as one
user message in the next `claude -p` call):

```
Your previous response was rejected:
<bullet list of validator errors>

Emit a corrected iseq as a JSON array.
```

The prompt builder has no conditional branches on iteration number —
every retry has the same shape.

## Error handling

Three failure classes:

**Tier 1 — CLI failures.** Missing `claude` binary, auth not configured,
timeout, network error. Invoker raises. Regeneration aborts with a
clear message. Not part of the gag. `demo:verify` never triggers this
path.

**Tier 2 — Parse failures.** Claude's output is not valid JSON, or does
not contain an IR array. Treated as a validator error. Fed back to
Claude. Counts as one iteration.

**Tier 3 — Validator failures.** The main loop:

- Unknown opcode: `"opcode :opt_fastmath at index 4 is not a known YARV opcode"`.
- Arity mismatch: `"opcode :opt_plus takes 1 operand (call_data), you provided 0"`.
- Semantic failure: `"your iseq ran but returned 7; expected 5"` or
  `"your iseq raised StackUnderflowError at instruction 3"`.

**Exhaustion.** After 3 failed iterations, preserve the original IR,
write `## Gave up after 3 attempts` to the transcript, exit 0. This is
a valid outcome of the gag.

## Determinism

Claude's output is non-deterministic. Two regenerations produce
different transcripts.

- `rake demo:verify` **never** calls `claude`. It checksums the
  committed `docs/demo_artifacts/claude_gag.md` the same way it does
  the other demo artifacts.
- `rake demo:regenerate_claude` is opt-in, requires a setup-token or
  `ANTHROPIC_API_KEY` env var, and prints a warning before running:
  "this will change the committed artifact; review the diff before
  committing."

## Docker changes

`docker/Dockerfile` gains:

- Installation of the `claude` CLI (official installer).
- An `ARG` for the setup-token, plumbed into
  `claude setup-token --token <arg>` during build, or mounted at
  runtime via `--secret`.
- `ENTRYPOINT`/`CMD` unchanged for normal iseq workflows.

The MCP ruby-bytecode server image gets the same treatment so the demo
driver can be invoked via MCP if convenient.

## Testing

**Unit tests** (`optimizer/test/demo/claude/`):

- `serializer_test.rb` — round-trip known IRs; feed known-bad JSON and
  assert `deserialize` raises a typed error.
- `validator_test.rb` — handcraft IRs tripping each failure class;
  assert error strings.
- `prompt_test.rb` — golden-file snapshot of initial + retry prompts.
- `transcript_test.rb` — golden-file snapshot of markdown render given
  a canned iteration array.

**Integration test** (`optimizer/test/demo/claude_integration_test.rb`):

- Scenario A: `Invoker` stub returns one structural-fail, one
  semantic-fail, one success. Loop runs 3 iterations, ends success.
- Scenario B: `Invoker` stub returns all failures. Loop ends
  "gave up," original IR preserved.

**Not tested in CI**: actual `claude -p` invocation. Exercised manually
during artifact capture, same pattern as other demo fixtures.

**Docker smoke test**: `docker run <image> which claude` returns 0.

## Fixture

`optimizer/examples/claude_gag.rb`:

```ruby
def answer
  2 + 3
end
```

Expected return: `5`. One call site, no locals, no branches. Minimal
surface for Claude to hallucinate against; maximal contrast with "3
iterations of an LLM loop."

## Out of scope

- Integrating `ClaudeCodePass` into `Pipeline.default`.
- Any form of caching between regenerations.
- Multi-fixture support. One fixture is enough for the §7 close.
- Live invocation during the talk itself.
- Any attempt to make Claude's output deterministic via
  temperature/seed. The non-determinism is part of the frame.
