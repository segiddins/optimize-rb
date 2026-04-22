# ObjectTable#intern for frozen strings — design

Date: 2026-04-24
Status: proposed
Scope: codec-level refinement; unblocks Tier 4 ENV fold for the canonical
`ENV["FLAG"]` shape.

## Motivation

`ConstFoldEnvPass` (shipped 2026-04-23) folds the 3-tuple
`opt_getconstant_path ENV; putchilledstring KEY; opt_aref` into a single
`putobject <idx>` / `putnil`. When the snapshot value is a String, the
pass currently requires that string to already live in the object table
(it calls `object_table.index_for(value)`). When the lookup misses, the
pass logs `:env_value_not_interned` and skips the fold.

The lookup misses whenever the folded value isn't reused as a literal
elsewhere in the program. The canonical `ENV["FLAG"] == "true"` demo
works today only because `"true"` appears as the `==` RHS. A plain
`def f; ENV["X"]; end` — nothing to compare against — doesn't fold.

`ObjectTable#intern` is the gatekeeper. It already appends new entries
(integers, true/false/nil), re-grows the offset array on encode, and
round-trips through `load_from_binary`. The only thing stopping string
interning is an explicit `special_const?` guard at
`object_table.rb:206-208`.

## Design

Two surgical changes, symmetric to the existing
integer/true/false/nil path.

### 1. Relax `intern`'s guard

`intern` currently raises `ArgumentError` for non-special-const values.
Extend it to also accept `String`. On append, duplicate and freeze the
string so the table's stored value is immutable (consistent with how
decoded strings are produced — they come back from `decode_string` as
freshly materialised strings; we freeze explicitly here so the
in-memory table matches the on-disk "frozen" header bit we'll set).

Non-string, non-special-const values still raise.

### 2. Emit a T_STRING payload in the encode-append loop

The append loop in `encode` (`object_table.rb:151-155`) currently calls
`write_special_const(writer, value)` for every appended object. Split
the dispatch:

```
case value
when Integer, true, false, nil
  write_special_const(writer, value)
when String
  write_string(writer, value)
else
  raise ArgumentError, "cannot encode #{value.inspect}"
end
```

`write_string` mirrors `decode_string` (`object_table.rb:286-293`):

- Header byte: T_STRING (5) | frozen (0x40). No special_const bit.
  → `0x45`.
- `small_value` encindex — derived from the Ruby string's encoding:
  - `Encoding::UTF_8` → 1
  - `Encoding::ASCII_8BIT` → 0
  - `Encoding::US_ASCII` → 2
  - else → 1 (UTF-8 fallback, since the decoder eventually `.encode`s
    to UTF-8 and silently falls back to raw bytes).
- `small_value` byte length (`value.b.bytesize`).
- Raw bytes (`value.b`).

The decoder already handles T_STRING on the read path, so round-trip
works without decoder changes. The encoder currently never emits
T_STRING through the append path (only through the verbatim
`@raw_object_region` bytes), so this is a strictly additive branch.

## Downstream effects

- `ConstFoldEnvPass`'s `:env_value_not_interned` skip path becomes dead
  on any ENV snapshot value that's a String. The defensive branch stays
  (intern could still refuse non-string non-special-const values in
  principle), but the `String` leg now calls `intern` instead of
  returning `nil`. One test — `test_skips_fold_when_snapshot_value_not_in_object_table`
  — changes meaning: the fold now *succeeds*, so the test updates from
  "asserts skip log" to "asserts folded and round-trips".
- A new canonical demo — `def f; ENV["X"]; end; f` with snapshot
  `{"X" => "hello"}` — now folds to `putobject <idx of "hello">`.
- TODO.md's Refinements entry moves from "not yet shipped" to "shipped";
  the `:env_value_not_interned` log-reason note gets updated.

## Out of scope

- **ENV taint classifier narrowing** (whitelisting `fetch`/`to_h`/`key?`).
  Unblocked by this work but a separate slice.
- **Frozen-constant fold (Tier 2)**. Still needs a constant-assignment
  scanner; interning strings doesn't change that story.
- **Non-string literal objects** (Arrays, Hashes, Symbols via this
  append path). No current caller needs them; `intern` continues to
  raise for those.

## Risks

- **Encoding round-trip fidelity.** The decoder re-encodes to UTF-8 and
  falls back to `bytes.dup`, so ASCII-only or UTF-8 ENV values
  round-trip cleanly. Non-UTF-8 ENV values would re-encode at decode
  time. This matches the existing behaviour for T_STRING payloads
  originally emitted by CRuby, so we're not introducing a new
  divergence — we're matching the existing read path.
- **Codec regression surface.** A new branch in `encode`'s append loop
  — covered by the new round-trip test plus the existing
  `test_unmodified_round_trip_still_byte_identical` guard (which only
  exercises the fast path and stays green since nothing is appended
  when the test doesn't call `intern`).

## Test plan

1. `test_intern_appends_string_and_binary_round_trips` — `intern("hello")`
   on a small iseq, encode, `load_from_binary`, eval, assert the value
   comes back through a `putobject <intern_idx>` rewrite (or just
   assert the string is present at `objects[idx]` after a decode of
   the re-encoded binary).
2. `test_intern_string_returns_existing_index` — the usual idempotence
   guard (string literal already in the table).
3. `test_intern_rejects_non_string_non_special_const` — unchanged
   behaviour: Arrays, Hashes etc. still raise.
4. Update `test_skips_fold_when_snapshot_value_not_in_object_table` →
   rename to `test_folds_env_to_interned_string_value`. Asserts the
   fold happens, the binary round-trips, and eval returns the snapshot
   string.
5. A new ConstFoldEnvPass integration test covering the minimal shape
   `def f; ENV["X"]; end; f` with snapshot `{"X" => "hello"}` — eval
   returns `"hello"`.
