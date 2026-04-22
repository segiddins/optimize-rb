# ConstFoldEnvPass — `ENV.fetch(LIT, default)` argc=2 fold — design

**Date:** 2026-04-28
**Pass:** ConstFoldEnvPass (Tier 4 const-fold)
**Scope:** New fold arm. Adds `ENV.fetch("LIT", <pure-default>)` argc=2 to the fold loop, alongside the existing `ENV[LIT]` and `ENV.fetch("LIT")` argc=1 arms.

## Motivation

After 2026-04-27 we fold `ENV.fetch("LIT")` argc=1: key present → `putobject <value>`; key absent → skip (logged `:fetch_key_absent`, preserves runtime `KeyError`). The argc=2 positional-default form (`ENV.fetch("LIT", "fallback")`) is a common idiom and the natural next step: when the key is present the default is discarded; when absent the default is the return value and the ENV machinery is pure overhead.

Folding argc=2 with a *positional* default requires a purity argument because Ruby evaluates positional arguments eagerly — `ENV.fetch("X", expensive_call)` runs `expensive_call` regardless of whether `"X"` is in ENV. That's why the block form `ENV.fetch("X") { expensive_call }` exists in the first place. So if we replace the 4-tuple with `putobject <value>` on a key hit, we must be sure the default expression had no side effects the program could observe.

## Design

### Fold window

For each ENV producer at index `i`, the argc=2 fold matches a 4-instruction window:

```
insts[i]     opt_getconstant_path ENV      (or getconstant ENV)
insts[i+1]   putstring | putchilledstring   — literal key
insts[i+2]   <pure default producer>        — see purity whitelist below
insts[i+3]   opt_send_without_block fetch   — cd.argc == 2, no kwargs/splat/block
```

### Purity whitelist for the default producer

The default producer at `insts[i+2]` is safe to drop iff it is *exactly one* of:

| Opcode | Notes |
|---|---|
| `putnil` | No operands; no effect. |
| `putobject` | Operand is an object-table index of a frozen immediate (Integer/Symbol/true/false/nil). Always pure. |
| `putstring` | Allocates a new mutable String; no user-observable effect beyond allocation. |
| `putchilledstring` | Same as putstring for our purposes. |
| `putself` | Pushes `self`; pure. (Rare but appears in tophevel `ENV.fetch("X", self)`-like shapes.) |

Explicitly **not** on the whitelist (v1 bails to preserve effects):

- `opt_getconstant_path` / `getconstant` — constant autoload can execute code.
- `getlocal`, `getinstancevariable`, `getglobal`, `getclassvariable` — pure reads, but v1 stays conservative; can be added later.
- `putspecialobject` — produces VM-internal objects; stay away.
- `duparray`, `duphash`, `newarray`, `newhash` — allocate container objects; defer (would also need multi-instruction window for non-empty forms).
- Any `*send*`, `invoke*`, arithmetic op, or anything that can raise — bail.

Single-instruction constraint: the default must be produced by one instruction at `insts[i+2]`. Multi-instruction defaults (e.g. `"a" + "b"` → `putstring; putstring; opt_plus`) would shift the send further down the stream and aren't matched by the fixed 4-window. Bail.

### Fold action

- **Key present in snapshot (`env_snapshot.key?(key)`):**
  - If the value is a `String`: intern it, replace the 4-tuple with `putobject <idx>`, log `:folded`. Default producer is dropped — safe because it was on the purity whitelist.
  - If the value is not a String (historical edge case for non-string snapshots): log `:env_value_not_string`, don't splice.
- **Key absent in snapshot:**
  - Replace the 4-tuple with a single instruction: a copy of `insts[i+2]` (the default producer). Log `:folded`. Preserves the exact object identity/semantics the runtime would have produced from the default.

### What we do NOT fold

- Default producer not on the purity whitelist → skip this fold site (no log entry needed; it just isn't a match). The classifier (already argc-generic post-v2) still treats `fetch` as a safe mid, so the site doesn't taint.
- Block form `ENV.fetch("X") { … }` — different opcode (`send` or `opt_send` with `ISEQ_BLOCK`), stays out.
- argc≥3 fetch calls — not legal Ruby (`Hash#fetch` arity is 1..2), so nothing to handle.
- kwargs/splat/blockarg — excluded by the same `cd.has_kwargs? || cd.has_splat? || cd.blockarg?` bail already used for argc=1 fetch.

### Interaction with the taint classifier

Classifier v2 (shipped 2026-04-28) already treats `fetch` argc=2 as a safe consumer — so `ENV.fetch("X", y)` in any sibling function doesn't taint the tree. This spec is purely about *folding* that site in its own function, not about taint.

### Interaction with other fold arms

Order matters in the existing loop body. Today the fold loop dispatches at `insts[i+2]`:

- `opt_aref` → argc-0 `ENV[LIT]` fold.
- `opt_send_without_block` with `fetch_send?` (argc=1) → argc=1 fold.

v2 adds a third dispatch: `opt_send_without_block` at `insts[i+3]` with a new `fetch_send_argc2?` predicate and a purity check on `insts[i+2]`. Check the 4-window *first*; if it matches, fold and `i += 1` (same cursor bump as other arms). Otherwise fall through to the existing 3-window checks.

## Test plan

| Test | Assertion |
|---|---|
| `test_folds_env_fetch_with_literal_default_when_key_present` | `ENV.fetch("A", "fallback")`, snapshot has `A="1"` → `putobject("1")`, default dropped. |
| `test_folds_env_fetch_with_literal_default_when_key_absent` | `ENV.fetch("MISSING", "fallback")`, snapshot does not have `MISSING` → `putstring("fallback")` (one instruction, the default). |
| `test_folds_env_fetch_with_putnil_default_when_key_absent` | `ENV.fetch("MISSING", nil)` → `putnil`. |
| `test_folds_env_fetch_with_integer_default_when_key_absent` | `ENV.fetch("MISSING", 42)` → `putobject(42)`. |
| `test_does_not_fold_env_fetch_with_impure_default` | `ENV.fetch("A", other_call)` — default is a send; site is not folded. `r.instructions` still contains the original `opt_send_without_block :fetch argc=2`. No taint (classifier v2 still allows it). |
| `test_does_not_fold_env_fetch_argc2_with_kwargs` / splat / block | Constructing this in Ruby source is awkward for argc=2; at minimum assert the predicate rejects via a unit-ish test (decode a program where we can confirm skip). If not expressible in clean source, drop this and rely on the inherited `fetch_send?`-style flag check being identical to argc=1. |

Existing tests kept green: every current ConstFoldEnvPass test, every classifier-v2 test added today.

## Implementation sketch

In `const_fold_env_pass.rb`:

```ruby
PURE_DEFAULT_OPCODES = %i[putnil putobject putstring putchilledstring putself].to_set.freeze

def fetch_send_argc2?(inst, object_table)
  cd = inst.operands[0]
  return false unless cd.is_a?(IR::CallData)
  return false unless cd.argc == 2
  return false if cd.has_kwargs? || cd.has_splat? || cd.blockarg?
  cd.mid_symbol(object_table) == :fetch
end

def pure_default?(inst)
  inst && PURE_DEFAULT_OPCODES.include?(inst.opcode)
end
```

In the fold loop (inside the existing `while i <= insts.size - 3` — widen to `- 4` for the new arm, but keep argc=1 handling which needs only 3):

```ruby
# argc=2 fetch(LIT, <pure default>) fold
d  = insts[i + 2]
op4 = insts[i + 3]
if d && op4 && op4.opcode == :opt_send_without_block && fetch_send_argc2?(op4, object_table) && pure_default?(d)
  key = LiteralValue.read(b, object_table: object_table)
  if env_snapshot.key?(key)
    value = env_snapshot[key]
    if value.is_a?(String)
      idx = object_table.intern(value)
      replacement = IR::Instruction.new(opcode: :putobject, operands: [idx], line: a.line)
      function.splice_instructions!(i..(i + 3), [replacement])
      log.skip(pass: :const_fold_env, reason: :folded, ...)
    else
      log.skip(pass: :const_fold_env, reason: :env_value_not_string, ...)
    end
  else
    # Key absent: return the default. Keep `d` as the sole instruction.
    function.splice_instructions!(i..(i + 3), [d])
    log.skip(pass: :const_fold_env, reason: :folded, ...)
  end
  i += 1
  next
end
```

Note the loop bound: widen the outer `while` to allow looking at `insts[i + 3]`. Safe because bounds are checked per-arm (`a`/`b` at i..i+1 still required for any match).

## Risks

- **Loop-bound widening.** Previously `i <= insts.size - 3` (three-instruction minimum window). Widen to `- 4` for the argc=2 arm *only* — don't weaken the existing arms' bound. Simplest: keep outer `while i <= insts.size - 3`; inside, guard the argc=2 check on `insts[i + 3]` presence. The guard `op4 && …` handles it naturally.
- **`putstring` / `putchilledstring` defaults allocate.** A program that relies on object identity of the allocated default (e.g. comparing via `equal?`) would see a change — but that's already true for `putstring` anywhere, and the user-visible contract of `Hash#fetch` doesn't expose identity across calls.
- **`putobject` default operand must resolve.** We copy the default instruction verbatim into the spliced result; the operand (object-table index) is preserved. No re-interning needed.

## Success criteria

- All new tests green. All prior ConstFoldEnvPass tests stay green.
- Full optimizer suite green.
- `docs/TODO.md`: Tier 4 status-table cell appended with argc=2 fetch-with-default; the matching follow-up line (if any) struck.
