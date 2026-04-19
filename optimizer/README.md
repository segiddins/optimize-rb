# optimizer

Talk-artifact Ruby optimizer. Companion to
`docs/superpowers/specs/2026-04-19-optimizer.md`.

## Status

- **Binary codec**: round-trippable decoder/encoder for YARB (YARV Binary
  Format) produced by `RubyVM::InstructionSequence#to_binary`. Identity
  round-trip (`encode(decode(bin)) == bin`) verified across a corpus of
  realistic snippets plus a semantic smoke test.
- **IR**: minimal — `IR::Function` per iseq, `IR::Instruction` per opcode.
  Sufficient for decoding and re-encoding; passes will consume this in
  the next plan.
- **Harness, optimizer core, passes**: to come (see
  `docs/superpowers/plans/` and companion specs).

## Running tests

Tests run inside a Ruby 4.0.2 Docker container via the repo's MCP server
(see `mcp-server/`). From a Claude Code session, use the
`mcp__ruby-bytecode__run_optimizer_tests` tool.

Or, on a host with Ruby 4.0.2 and Docker:

    cd optimizer
    bundle install
    bundle exec rake test

## Layout

- `lib/ruby_opt/codec/` — YARB binary surgery (reader, writer, header,
  object table, iseq list, iseq envelope, instruction stream)
- `lib/ruby_opt/ir/` — decoded IR (`Function`, `Instruction`)
- `test/codec/` — round-trip, corpus, and smoke tests
- `test/codec/corpus/` — Ruby snippet fixtures

## The round-trip contract

For any iseq produced by `RubyVM::InstructionSequence#to_binary`:

    encode(decode(bin)) == bin  (byte-identical)

Any input that doesn't round-trip is a codec bug. Modifications to the
decoded IR are not yet applied on re-encode (today: raw bytes are
re-emitted from `Function#misc`); wiring the IR-to-bytes path through
the encoder is a next-plan concern.
