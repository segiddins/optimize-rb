# Spec: Codec — 9-byte `small_value` endianness + negative fixnum round-trip

**Part of:** [Ruby the Hard Way](2026-04-19-talk-structure-design.md)
**Retroactive:** This spec documents a fix that already shipped (commit `ylzpuusytuty`, 2026-04-21). It exists so the talk repo's "every change has a spec" invariant holds cleanly; the fix itself is unchanged.
**Depends on:** binary reader/writer (`read_small_value` / `write_small_value`), `ObjectTable` special-const encode/decode paths.

## Purpose

The 9-byte form of `ibf_dump_small_value` (used for any value that does not fit any of the shorter tag-packed forms) was encoded/decoded as little-endian in our codec, but CRuby encodes it big-endian. The bug stayed latent until `ObjectTable#intern` started pushing negative fixnum `VALUE`s (e.g. `-6` → `0xFFFF_FFFF_FFFF_FFF5`) through the 9-byte path during ArithReassocPass v3 development, which caused `load_from_binary` to reject the output.

## Scope

Two independent-but-coupled fixes, shipped in the same commit because the second is what actually exercises the first:

1. **Endianness of the 9-byte form.** Reader and writer both use `Q>` (big-endian) instead of `Q<`, matching the shift algorithm CRuby uses for every multi-byte form.
2. **Negative-fixnum round-trip through the special-const path.** `ObjectTable` encodes `(n << 1) | 1` masked to unsigned 64 bits on the write side, and re-signs the 64-bit value after reading (`value >= 2^63 ? value - 2^64 : value`) on the read side. Without this, `write_small_value` (which only accepts non-negative) would reject the `VALUE` for any negative Integer.

### Explicitly in

- `BinaryReader#read_small_value`: 9-byte branch unpacks with `Q>`.
- `BinaryWriter#write_small_value`: 9-byte branch packs with `Q>`.
- `ObjectTable.encode_special_const` (Integer branch): mask `(value << 1) | 1` with `0xFFFF_FFFF_FFFF_FFFF`.
- `ObjectTable.decode_special_const` (fixnum branch): interpret the `uint64` as signed before shifting right by 1.
- Tests:
  - `test_intern_negative_integer_round_trips` in `object_table_intern_test.rb` — interns `-6`, encodes, then `load_from_binary` must accept the output (this is the only test that actually hits the 9-byte path end-to-end).
  - `test_emit_negative_integer_is_readable` in `literal_value_test.rb` — `LiteralValue.emit(-6)` round-trips through `read`.

### Explicitly out

- Widening `INTERN_BIT_LENGTH_LIMIT` past 62. Still blocked by a separate bignum-digit codec issue (follow-up 1 in the v2 docs): `putobject <int>` with bit-length ≳ 30 segfaults CRuby on `load_from_binary`. That lives in the Bignum digit encoding (`object_table.rb` around line 373, using `write_u64`/`read_u64`), not in `small_value` framing.
- Signed variants of `read_u64`/`write_u64`. Those are used for Bignum digits and are correct as-is.

## Design

### Why `read_small_value` stays unsigned

`read_small_value` is the general reader for every compact integer in the IBF stream: object table indices, line numbers, instruction offsets, etc. All of those are non-negative. Only one caller — `decode_special_const`, and only on the fixnum branch — needs to reinterpret the result as a raw CRuby `VALUE` that may have bit 63 set. Re-signing inside that caller keeps every other call site correct without a new API.

### Symmetry with the writer

`write_small_value` only accepts non-negative integers. The encode-side fix masks the `(value << 1) | 1` word to 64 bits before calling it, producing exactly the unsigned `VALUE` the decoder will see after its symmetric re-signing step.

### Why the bug was latent

- Shorter forms (1-, 2-, 4-, 8-byte) pack the value into the tag byte plus continuation bytes using shifts, which are endianness-oblivious. The 9-byte form was the only one that hit a `pack("Q…")`.
- All positive fixnums with `|n| < 2^30` (roughly) fit the 8-byte-or-shorter forms, so the full test corpus written during codec bring-up never took the 9-byte path.
- The first negative `VALUE` (`(n << 1) | 1` for `n < 0`) has all high bits set, which forces the 9-byte form and simultaneously trips the "writer rejects negative" guard.

## Tests

Passing tests after the fix:

- `test_intern_negative_integer_round_trips` — end-to-end: intern `-6`, encode, `RubyVM::InstructionSequence.load_from_binary` must return an `InstructionSequence` (not segfault, not raise).
- `test_emit_negative_integer_is_readable` — `LiteralValue.emit(-6)` produces a `putobject` whose operand decodes back to `-6` via `LiteralValue.read`.

Regression coverage: all pre-existing codec round-trip tests remain green (no positive-fixnum encoding changed; short forms were unaffected).

## Non-goals for the talk

This fix does not get its own slide. It surfaces at most as a one-line aside in the "we found a codec bug while building ArithReassocPass v3" beat, because the interesting fact is that a dormant endianness bug was only reachable once the optimizer started synthesizing negative literals. If cut for time, the talk loses nothing.
