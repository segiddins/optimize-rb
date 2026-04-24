---
theme: default
title: "Ruby the Hard Way: Writing Bytecode to Optimize Plain Ruby"
info: |
  RubyKaigi 2026 — @segiddins
  Source: github.com/segiddins/optimize-rb
class: text-center
highlighter: shiki
lineNumbers: false
drawings:
  persist: false
transition: slide-left
mdc: true
---

# Ruby the Hard Way

## Writing Bytecode to Optimize Plain Ruby

Samuel Giddins · @segiddins · RubyKaigi 2026

<!--
TITLE slide. Cue: "A love letter to a bad idea." Move fast — the title and subtitle tell the story, don't narrate them. Tag (post.md title + subtitle, lines 1, 3).
-->

---
layout: default
---

# About me

<!--
Cue: ~30s total. Three facts, don't dwell:
- Samuel Giddins / @segiddins
- Past life: bugs for RubyGems & Bundler
- Now: Security Engineer at Persona, thinking about Ruby/Rails performance
- Closing line: "This is not the talk about any of that professional work."

Post.md lines 13–22.
-->

---
layout: cover
class: text-center
---

# §1

## A love letter to a bad idea

<!--
§1 title (post.md line 24), setup for ¶1 (line 26).

Cue: "Let me be honest with you up front about what this talk is, and — more importantly — about what it isn't." Move fast; this slide is a section divider. Budget ~5s.

Verbatim ¶1:
"I want to be honest with you up front about what this talk is, and — more importantly — about what it isn't."
-->

---
layout: default
---

# What this talk isn't

<v-clicks>

- Not a war story
- No 50%-improvement graph
- Not going into your codebase

</v-clicks>

<!--
§1 ¶2 (post.md line 28). Budget ~30s.

Verbatim:
"It isn't a war story. I don't have a production hotspot that refused to yield to profiling, I don't have a 50%-improvement graph, and I am not about to convince you to put any of this into your codebase."
-->

---
layout: default
---

# This is RubyKaigi

<v-clicks>

- You've already heard from the best people in the world doing serious work on Ruby performance
- *The design and implementation of ZJIT & the next five years* · *Lightning-Fast Method Calls with Ruby 4.1 ZJIT*
- This is not one of those talks

</v-clicks>

<!--
§1 ¶3 (post.md line 30). Budget ~40s.

Verbatim:
"This is RubyKaigi. You have already heard from some of the best people in the world doing serious work on Ruby performance. 'The design and implementation of ZJIT & the next five years' is doing all of this properly, at runtime, with an actual IR. 'Lightning-Fast Method Calls with Ruby 4.1 ZJIT' — earlier today — is the version of my inliner that comes with a deoptimization story and the last five years of engineering judgment attached. Those are the talks where 'make Ruby faster' is a real statement. This is not one of those talks."

Say both ZJIT talk titles. Name-checking them does real work — it signals this talk knows its place on the schedule.
-->

---
layout: default
---

# The whole talk, in one sentence

<div class="text-xl leading-relaxed max-w-4xl mt-8">
<span v-click="1">I hand-wrote a prompt or two,</span>
<span v-click="2"> and had Claude Code build me a compiler</span>
<span v-click="3"> that rewrites YARV bytecode</span>
<span v-click="4"> under a handful of rules Ruby-the-language can't assume</span>
<span v-click="5"> but Ruby-the-programmer almost always can.</span>
</div>

<div class="mt-16 italic opacity-80" v-click="6">

That's also, roughly, the whole talk.

</div>

<div class="mt-3 opacity-60" v-click="7">

You're welcome to leave and go get a good seat for Matz's keynote.

</div>

<!--
§1 ¶4 + ¶5 (post.md lines 32, 34). Budget ~45s — this is the thesis slide, let it breathe.

Verbatim ¶4:
"What I did instead, in one sentence: I hand-wrote a prompt or two, and had Claude Code build me a compiler that rewrites YARV bytecode under a handful of rules Ruby-the-language can't assume but Ruby-the-programmer almost always can."

Verbatim ¶5:
"(That sentence is also, roughly, the whole talk. If you're happy with just that, you're welcome to leave and get a good seat for Matz's closing keynote.)"

Delivery note: the sentence builds in 5 steps on the screen; read it at the pace the clicks advance. When click 6 appears pause half a beat before landing the "whole talk" line. Click 7 is the out — you're the last Day-3 talk before Matz, so the keynote line is a real aside, not a throwaway.
-->

---
layout: default
---

# By the end of the next 30 minutes

<v-clicks>

- You will be able to read a YARV instruction listing
- You will understand why your perfectly reasonable Ruby doesn't get optimized the way you think it should
- You will have permission to go write your own terrible optimizer for a weekend

</v-clicks>

<!--
§1 ¶6 (post.md line 36). Budget ~35s.

Verbatim:
"Anyways. This was, more than anything, an excuse to learn more about YARV bytecode and what actually goes into building an optimizing compiler. I am very aware of how bad an idea it is. I'm going to show it to you anyway, because by the end of the next thirty minutes: you will be able to read a YARV instruction listing. You will understand why your perfectly reasonable Ruby doesn't get optimized the way you obviously think it should. And — this is the actual pitch — you will have permission to go write your own terrible optimizer for a weekend, just to see what happens."

Delivery: the third reveal is the actual pitch — hit it harder than the other two.
-->

---
layout: cover
class: text-center
---

# §2

## The contract

<!--
§2 section divider (post.md line 38). Budget ~3s.
-->

---
layout: default
---

# Every compiler has a contract

<v-clicks>

- Ruby's own is almost *nothing* — any method could be redefined; any constant could have moved

- `1 + 2` compiles to `opt_plus` — a runtime check that `Integer#+` is still the original. Every `opt_*` is the contract, made concrete.

</v-clicks>

<!--
§2 ¶1 (post.md line 40). Budget ~60s.

Verbatim:
"Every optimizer operates under some contract with the program it's compiling. Ruby's own contract is almost nothing: the language has to assume that any method on any object could be redefined between now and the next call site, and that a constant you read a microsecond ago might point at a different object now. That's a real constraint, and it's visible in the bytecode. `1 + 2` doesn't compile to an integer add; it compiles to `opt_plus`, which checks at runtime whether `Integer#+` is still the original `Integer#+` before taking the fast path. Ruby already has a tiny contract — a handful of 'basic operations haven't been redefined' flags — and every `opt_*` instruction is that contract made concrete."

Delivery: "almost nothing" is the key beat; "every opt_* is the contract made concrete" is the bridge to the five clauses.
-->

---
layout: default
---

# Clause 1 — No BOP redefinition

<div class="text-lg mt-6">

`Integer#+`, `String#==`, `Array#[]`, `Hash#[]` mean what MRI shipped them meaning.

</div>

<div class="mt-8 text-gray-600" v-click>

→ `opt_plus`'s runtime check can be skipped.

</div>

<!--
§2 ¶2 clause 1 (post.md line 44) + ¶3 first sentence (line 50). Budget ~20s.

Verbatim (¶2 clause 1): "No BOP redefinition. Integer#+, String#==, Array#[], Hash#[] — the basic operations mean what MRI shipped them meaning."

From ¶3 (paired): "Stable method tables are what make inlining safe [...] Constants that don't get reassigned can be folded straight into the instruction stream [...]" — pull the BOP-specific line. The opt_plus check skipping is the point.
-->

---
layout: default
---

# Clause 2 — RBS signatures are truthful

<div class="text-lg mt-6">

Where an inline `# @rbs` says a method returns an `Integer`, it returns an `Integer`.

</div>

<div class="mt-8 text-gray-600" v-click>

→ a typed receiver binds statically at rewrite time — the hook the inliner actually uses.

</div>

<!--
§2 ¶2 clause 3 (post.md line 46) + ¶3 RBS sentence. Budget ~25s.

Verbatim (clause): "RBS signatures are truthful. Where an inline RBS annotation says a method returns an `Integer`, it returns an `Integer`."

Verbatim (¶3 on RBS): "A truthful RBS signature is the difference between 'this call returns something' and 'this call returns an Integer, so the next `+` can use the unchecked path.'"

The bit that matters: a call to point.translate(dx, dy) whose RBS types the receiver as Point can bind statically to Point#translate. That's how the inliner picks a callee.
-->

---
layout: default
---

# Clause 3 — `ENV` is read-only after load

<div class="text-lg mt-6">

`ENV["X"]` resolves to the same thing forever.

</div>

<div class="mt-8 text-gray-600" v-click>

→ `ENV["FEATURE_X"]` folds away like a literal — same file, configured differently across environments.

</div>

<!--
§2 ¶2 clause 4 (post.md line 47) + ¶3 ENV sentence. Budget ~20s.

Verbatim (clause): "`ENV` is read-only after load. `ENV['X']` resolves to the same thing forever."

Verbatim (¶3 on ENV): "A read-only `ENV` lets `ENV['FEATURE_X']` be read once at load time and folded away like a constant, while still letting the same source file be configured differently across environments."
-->

---
layout: default
---

# Clause 4 — No constant reassignment

<div class="text-lg mt-6">

Top-level constants are assigned exactly once. No `const_set`, no reopening to reassign.

</div>

<div class="mt-8 text-gray-600" v-click>

→ constants fold straight into the instruction stream, instead of a cache lookup per iteration.

</div>

<!--
§2 ¶2 clause 5 (post.md line 48) + ¶3 constants sentence. Budget ~20s.

Verbatim (clause): "No constant reassignment. Top-level constants are assigned exactly once; no `const_set`, no reopening to reassign."

Verbatim (¶3 on constants): "Constants that don't get reassigned can be folded straight into the instruction stream instead of going through a constant-cache lookup on every iteration."
-->

---
layout: default
---

# Clause 5 — No `prepend` after load

<div class="text-lg mt-6">

Method tables are stable once the program is loaded. Nothing is going to slip a module into the ancestor chain between call sites.

</div>

<div class="mt-8 text-gray-600" v-click>

→ a call site bound at compile time stays bound at run time. This is what makes inlining safe.

</div>

<!--
§2 ¶2 clause 2 (post.md line 45) + ¶3 method-tables sentence. Budget ~30s — this clause lands last because it's the most-violated, and the violations slide is next.

Verbatim (clause): "No `prepend` after load. Method tables are stable once the program is loaded; nothing is going to slip a module into the ancestor chain between call sites."

Verbatim (¶3 on method tables): "Stable method tables are what make inlining safe: if nothing can `prepend` into the ancestor chain, a call site bound at compile time stays bound at run time."

Delivery: land on "makes inlining safe" deliberately — set up the immediate turn.
-->

---
layout: default
---

# Reasonable Ruby violates every one of these

<v-clicks>

- **APM gems** `prepend` into `ActiveRecord`, `Net::HTTP`, and friends. *(New Relic · Datadog · Skylight)*
- **RSpec mocks** swap method entries mid-test. `allow(user).to receive(:name)` is the whole point.
- **Rails dev mode** reloads classes on every file change. Reassigning constants is a feature.

</v-clicks>

<!--
§2 ¶4 (post.md line 52). Budget ~50s.

Verbatim:
"These are reasonable assumptions for many programs. 'Many' is the important word: plenty of real Ruby violates every one of them deliberately and correctly. Every APM gem in wide use — New Relic, Datadog, Skylight — instruments `ActiveRecord`, `Net::HTTP`, and friends by `prepend`ing a module that wraps the original method. That's the entire point; it's also a load-time violation of clause two. Any test suite using RSpec mocks is redefining methods between examples by design — `allow(user).to receive(:name).and_return('Sam')` swaps out a method table entry for the duration of the test, which is exactly what 'method tables are stable' rules out. And every Rails developer running `bin/rails server` in development has the framework reloading classes on file changes so you can edit code without restarting the server. Reloading without restart is one of the best things about working in Rails, and it violates clause five every time the file watcher fires."

Delivery: this is the audience's room. Every person here either writes code that breaks these or relies on code that does. Name APM gems; the specific names land. Drop the RSpec `allow` shorthand — ~70% of the room will have typed it this month.
-->

---
layout: default
---

# `TracePoint` / `Coverage`: environment, not code

<div class="text-lg mt-6 leading-relaxed max-w-4xl">

Inlining erases the callee's `:call` and `:return` events. Dead-instruction elimination erases its `:line` events.

</div>

<div class="mt-8 italic" v-click>

The violation isn't a property of the code. It's a property of the environment.

</div>

<!--
§2 ¶5 (post.md line 54). Budget ~30s.

Verbatim:
"One more assumption sits underneath these — and it's about how the program gets *used*, not what it does. Nobody is watching through `TracePoint` or `Coverage`. Inlining a call erases the `:call` and `:return` events for the inlined callee; dead-instruction elimination erases the `:line` events for lines that got deleted. The violation isn't a property of the code, it's a property of the environment. That's exactly why the contract module can't express it."

Delivery: the click lands the key distinction — the contract is *about the code*, but this clause is about *how the code is being watched*. Different flavor of assumption.
-->

---
layout: default
---

# Reasonable isn't good enough — for the *language*

<div class="text-lg mt-6 leading-relaxed max-w-4xl">

A compiler that silently miscompiles `user.admin?` is worse than a slow one. And it isn't even close.

</div>

<div class="mt-8 italic opacity-80" v-click>

Maybe one day: a pragma. A sealed module. `# frozen_methods: true` at the top of a file.

</div>

<div class="mt-4 opacity-70" v-click>

Until then — a weekend project gets assumptions a language implementation can't.

</div>

<!--
§2 ¶6 (post.md line 56). Budget ~40s — the turn that justifies everything that follows.

Verbatim:
"Reasonable isn't good enough for the language itself. For Ruby, not breaking the language has to be the higher priority. A compiler that silently miscompiles `find_by_name_and_email` is worse than a slow one, and it isn't even close. That's why MRI's contract is so thin, and why `opt_plus` has to keep checking. Maybe one day there'll be a way to safely opt into this kind of optimization — a pragma, a sealed module, a `# frozen_methods: true` at the top of a file — and the VM can trust it the way I'm about to. Until then, a weekend project gets to make assumptions a language implementation can't."

Swap note: deck uses `user.admin?` instead of `find_by_name_and_email` — dynamic finders are Rails-specific and stale; a silent authz miscompile lands harder and is universally understood. When post.md is finalized for publication, mirror this change there too.

Delivery: don't rush the "and it isn't even close" — half-beat pause. The two follow-up clicks are the hopeful note; hit "weekend project" as the landing.
-->

---
layout: cover
class: text-center
---

# §3

## YARV, properly

<!--
§3 section divider (post.md line 58) + setup for ¶1 (line 60). Budget ~5s.

Verbatim ¶1: "Before I can talk about rewriting YARV, you have to be able to read it. If you've never stared at a `disasm` dump before, here's the decoder ring."
-->

---
layout: default
---

# YARV is a stack machine

<v-clicks>

- No register file, no `%rax`, no let-bindings
- Locals live off an **environment pointer** — `getlocal` / `setlocal` reach into it by index
- Exception handling and a handful of inline caches are the rest. Safely ignorable.

</v-clicks>

<!--
§3 ¶2 (post.md line 62). Budget ~45s.

Verbatim:
"YARV is a stack machine. There is no register file, no `%rax` equivalent, no let-bindings. Every instruction does some combination of pop-values-off-the-stack, read-operands-from-the-instruction-stream, and push-results-back. The per-frame state that isn't on the stack — locals, block parameter, `self` — lives in a block of slots hanging off an environment pointer, which `getlocal` / `setlocal` reach into by index. That's most of the machine. Exception handling and a handful of inline caches are the rest, and both are safely ignorable."
-->

---
layout: default
---

# Reading YARV: `def add(a, b); a + b; end`

```text {all|2-3|4-5|6|7|all}{lines:true}
== disasm: #<ISeq:add@(irb):1 (1,0)-(1,25)>
local table (size: 2, argc: 2 [opts: 0, rest: -1, ...])
[ 2] a@0<Arg>  [ 1] b@1<Arg>
0000 getlocal_WC_0          a@0
0002 getlocal_WC_0          b@1
0004 opt_plus               <calldata!mid:+, argc:1, ARGS_SIMPLE>
0006 leave
```

<div class="mt-4 text-base h-16">
<div v-click="[1,2]">The frame's slots, by name and index. Every later <code>x@N</code> refers back.</div>
<div v-click="[2,3]"><code>_WC_0</code> = level 0 (current frame), baked into the opcode. <code>setlocal_WC_0 x; getlocal_WC_0 x</code> is exactly what dead-stash sweeps away.</div>
<div v-click="[3,4]"><code>opt_plus</code> is §2's contract, made concrete — runtime-guarded <code>Integer#+</code>, C fast path if <code>Integer#+</code> hasn't been redefined.</div>
<div v-click="[4,5]"><code>leave</code> is not <code>ret</code>: pop TOS, handle pending interrupts, pop the frame.</div>
</div>

<!--
§3 ¶3 + listing + ¶4 (post.md lines 64–76). THE linger slide. Budget ~90s.

Verbatim ¶3: "The smallest useful example is probably `def add(a, b); a + b; end`:" (followed by the listing).

¶4 (the long paragraph) — full verbatim in notes for delivery:
"The `local table` header lists the frame's slots by name and index, and every `x@N` that shows up later in an operand column refers back to it. Three things in the body are worth noticing, and they recur in every listing from here on. First, `getlocal_WC_0` is `getlocal idx, 0` with the frame level operand baked in — the `_WC_N` suffix bakes the level in as `N`, and `_WC_0` (the current frame) is so overwhelmingly the common case that the interpreter gets its own specialized insn that skips decoding the level operand. You'll see `_WC_0` everywhere; `_WC_1` shows up when a nested scope reads a local from its parent. Its write-side partner is `setlocal_WC_0`, and the pair `setlocal_WC_0 x; getlocal_WC_0 x` — store and immediately reload — is exactly the shape the dead-stash pass sweeps away later. Second, `opt_plus` is not 'integer add.' It's a runtime-guarded call to `Integer#+` (or `Float#+`, or `String#+`) that takes a C fast path when the receiver is one of those core types *and* nobody has redefined `Integer#+` since the VM booted — otherwise it falls through to a generic `send`. The whole `opt_*` binop family works this way (`opt_minus`, `opt_mult`, `opt_div`, `opt_mod`, `opt_eq`, `opt_lt`, `opt_le`, `opt_gt`, `opt_ge`, `opt_ltlt`, and a few more), and that fallback is §2's contract, made concrete. Third, `leave` isn't `ret` — it's 'pop TOS as the return value, handle pending interrupts, pop the frame.' A small distinction, but it's the one that bites you the first time you try to splice two iseqs together and the result still runs `leave` in the middle."

Delivery: pace the clicks. Don't speed-read. After the 4th click, pause on the full listing for a beat — let them re-read with all the labels attached — before moving on to "iseqs nest."
-->

---
layout: default
---

# Iseqs nest

<div class="text-lg mt-6 leading-relaxed max-w-4xl">

Every `def`, every `do...end`, every `class Foo`, the top-level script — each compiles to its own child `rb_iseq_t`.

</div>

<div class="mt-6 text-base opacity-80" v-click>

That's why <code>disasm</code> keeps showing address <code>0000</code> more than once: one blob of output is several iseqs stacked on top of each other.

</div>

<!--
§3 ¶5 (post.md line 78). Budget ~25s.

Verbatim:
"Iseqs nest. Every `def`, every `do...end`, every `class Foo`, and the top-level script itself compile to their own child `rb_iseq_t`. `disasm` interleaves them with `== disasm:` separator lines, so one blob of output is really several iseqs stacked on top of each other — the reason you'll see the same address `0000` show up more than once in a listing."
-->

---
layout: default
---

# A few more names — the decoder ring

<div class="grid grid-cols-2 gap-x-8 gap-y-6 text-sm mt-4 leading-snug">

<div>

**Pushes**

<v-clicks>

- `putobject 6` — general immediate
- `putobject_INT2FIX_0_` / `_1_` — 0 and 1 got their own dispatch
- `putself` — current receiver

</v-clicks>

</div>

<div>

**Calls + constants**

<v-clicks>

- `opt_send_without_block` — common call-site shape
- `opt_getconstant_path` — fused `A::B::C` lookup + inline cache

</v-clicks>

</div>

<div>

**Stack + control**

<v-clicks>

- `swap` / `pop` — `swap; pop` after `opt_new` discards the class
- `branch*`: `branchunless` / `branchif` / `branchnil`, all PC-relative
- `jump`, `leave`

</v-clicks>

</div>

<div>

**The `opt_*` binops**

<v-clicks>

- `opt_plus`, `opt_minus`, `opt_mult`, `opt_div`, `opt_mod`
- `opt_eq`, `opt_lt`, `opt_le`, `opt_gt`, `opt_ge`, `opt_ltlt`
- All contract-guarded; miss falls through to generic `send`

</v-clicks>

</div>

</div>

<!--
§3 ¶6 + ¶7 merged (post.md lines 80, 82). Budget ~80s — eight click reveals across four columns.

Verbatim ¶6: "A few more names that look like typos until you've seen them. `putobject_INT2FIX_0_` pushes the integer `0`; `putobject_INT2FIX_1_` pushes `1`. Both are `putobject` with the operand baked in — pushing `0` or `1` shows up so often (loop counters, `+ 1`, default arguments, boolean-ish returns) that saving a single operand read per push was worth giving them their own dispatch entries. `putobject 6` — no suffix — is the general form with `6` as an immediate."

Verbatim ¶7: "`putself` pushes the current `self`, which is the implicit receiver for any unqualified method call. `opt_send_without_block` is a regular call site specialized for the (extremely common) case where no literal block is attached. `opt_getconstant_path` is the fused lookup for a full constant path like `SCALE` or `A::B::C`, with an inline cache hanging off it; when you see a diff quietly replace `opt_getconstant_path <ic:0 SCALE>` with `putobject 6`, that's constant folding — the cache lookup and its invalidation machinery both gone, because a contract-validated constant can't change. `swap` flips the top two stack values, `pop` discards TOS, and the `swap; pop` that appears right after an `opt_new` is cleaning up the extra stack slot `opt_new` leaves behind: the new instance and the class end up on the stack together, and `swap; pop` discards the class. The `branch*` family is exactly what it reads like: `branchunless dst` jumps to `dst` when TOS is falsy, `branchif` jumps when it's truthy, `branchnil` when it's `nil` — all PC-relative, all popping their one argument. The reason a `putobject true; branchunless 7` sequence can collapse into nothing is that the condition is knowable at rewrite time."

Delivery tip: call the <code>opt_getconstant_path → putobject</code> transformation out loud; it's the visual fingerprint of const-fold that'll recur in §5.
-->

---
layout: default
---

# Ignore the trailing brackets

<div class="text-lg mt-6 leading-relaxed max-w-4xl">

<code>[Li]</code>, <code>[Ca]</code>, <code>[Re]</code>, <code>[CcCr]</code> — event and coverage markers for <code>TracePoint</code> and <code>Coverage</code>.

</div>

<div class="mt-6 text-base opacity-80" v-click>

They don't change what the instruction does. Ignore them when you're reading diffs.

</div>

<!--
§3 ¶8 (post.md line 84). Budget ~15s.

Verbatim:
"One last thing. Every line of `disasm` output carries a trailing bracketed tag or two — `[Li]`, `[Ca]`, `[Re]`, `[CcCr]`, combinations thereof. These are event and coverage markers the disassembler annotates for `TracePoint` / `Coverage` wiring; they don't change what the instruction does, and you can ignore them for reading the diffs."

Delivery: throwaway line. Move fast.
-->

---
layout: default
---

# The shortlist

<div class="text-base mt-6 leading-relaxed max-w-5xl">

`getlocal_WC_0` · `setlocal_WC_0` · `putobject` (+ `putobject_INT2FIX_0_` / `_1_`) · `putself` · the `opt_*` binops · `opt_send_without_block` · `opt_getconstant_path` · `swap` · `pop` · `branch*` · `jump` · `leave`

</div>

<div class="mt-12 text-lg italic" v-click>

If those make sense, the diffs will too. The rest is picked up by context.

</div>

<!--
§3 ¶9 (post.md line 86). Budget ~25s.

Verbatim:
"That's roughly the grammar. There are about a hundred and ten instructions in total, and any real program calls in some long tail of them that I won't explain one by one. But the shortlist is short: `getlocal_WC_0`, `setlocal_WC_0`, `putobject` (and its `_INT2FIX_*` cousins), `putself`, the `opt_*` binops, `opt_send_without_block`, `opt_getconstant_path`, `swap`, `pop`, the `branch*` family, `jump`, and `leave`. If those make sense, the diffs will too, and the rest can be picked up by context."

Delivery: this is the cheat sheet for §5. Hit "the rest is picked up by context" as a reassurance before the demos.
-->

---
layout: cover
class: text-center
---

# §4

## Building a toy optimizer

<!--
§4 section divider (post.md line 88). Budget ~3s.
-->

---
layout: default
---

# Ruby hands you two methods

<v-clicks>

- `RubyVM::InstructionSequence#to_binary` — serializes a compiled iseq to the YARV binary format (bootsnap territory)
- `RubyVM::InstructionSequence.load_from_binary` — takes those bytes and returns a live iseq the VM runs *directly*: no re-parse, no re-compile

</v-clicks>

<div class="mt-12 text-lg italic" v-click>

Those two methods are the entire trick. Everything else goes between them.

</div>

<!--
§4 ¶1 (post.md line 90). Budget ~45s.

Verbatim:
"Ruby hands you two methods and looks the other way. `RubyVM::InstructionSequence#to_binary` serializes a compiled iseq to the YARV binary format — the undocumented-but-stable-ish blob MRI uses for on-disk iseq caches like bootsnap. `RubyVM::InstructionSequence.load_from_binary` takes those bytes and returns a live iseq the VM executes directly, no re-parse, no re-compile. Those two methods are the entire trick; everything else is what goes between them."

Delivery: land on "looks the other way" with a little smile — this IS a little bit of a trick.
-->

---
layout: default
---

# YARV is not an ABI

<v-clicks>

- Every minor Ruby adds, renames, reshapes, or retires instructions
- The loader checks an internal version stamp and rejects mismatches — no backward-compatibility window
- This optimizer targets Ruby 4.0. Porting to 4.1 is its own project.

</v-clicks>

<div class="mt-8 text-sm opacity-70" v-click>

Same pin on YJIT, ZJIT, anything that pattern-matches on opcodes.

</div>

<!--
§4 ¶2 (post.md line 92). Budget ~40s.

Verbatim:
"One caveat before the trick works. YARV's instruction set is not an ABI. Every minor Ruby release is free to add, rename, reshape, or retire instructions, and recent releases have done all four. The loader checks an internal version stamp on the way in and rejects anything that doesn't match exactly — no backward-compatibility window, no graceful degradation. That's by design; the format is a cache, not a promise. The binary `to_binary` emits on one Ruby is not loadable on another, and any tool that pattern-matches on opcodes — mine, ZJIT, YJIT's IR — is pinned the same way. The optimizer in this repo targets Ruby 4.0; porting it to a different minor version is its own project."

Delivery: this is a warning, not an apology. The format-is-a-cache-not-a-promise line is the crisp one.
-->

---
layout: default
---

# The shape

<div class="text-2xl mt-8 text-center">

decode &nbsp;→&nbsp; rewrite &nbsp;→&nbsp; encode

</div>

<div class="mt-12 text-base leading-relaxed max-w-4xl" v-click>

A naïve version is a flat `[opcode, *operands]` array with pattern matching.

Interesting rewrites — inlining, const-fold across a branch — want **basic blocks** and **where a value came from**. Maintaining either on a flat array after three passes is bookkeeping hell.

</div>

<!--
§4 ¶3 (post.md line 94). Budget ~40s.

Verbatim:
"The shape is unsurprising. Decode the binary into an in-memory IR, run a pipeline of local rewrites over it, encode back to the same format, hand the modified bytes to `load_from_binary`. A naïve version could do all of this with a flat array of `[opcode, *operands]` tuples and some pattern matching. I did not want to do that — the interesting rewrites (inlining, constant folding across a branch) want a notion of basic blocks and a notion of where a value came from, and maintaining either one on a flat array once you have more than three passes is bookkeeping hell."

Delivery: keep the three-word shape ("decode → rewrite → encode") on the first beat; the click adds the "why not flat" argument.
-->

---
layout: default
---

# IR: function per iseq, CFG per function

<v-clicks>

- **Function** = CFG of basic blocks. A block ends at a branch, a `jump`, or `leave`.
- **Children live on their parent function** — nested `def`, blocks passed to methods, `class Foo` bodies. That's how YARV stores them; flattening just means reconstructing the tree on the way out.

</v-clicks>

<!--
§4 ¶4 (post.md line 96). Budget ~35s.

Verbatim:
"So the IR is a function per iseq, each function holding a CFG of basic blocks — blocks end at branches, jumps, and `leave` — with an ordered list of instructions per block and a slot-type table threaded through so a pass can ask 'what do I know about `a@0` right here.' Children live on their parent function — nested `def`s, blocks passed to methods, `class Foo` bodies — because that's how YARV stores them, and flattening the tree would just mean reconstructing it on the way back out."
-->

---
layout: default
---

# Slot types come from RBS

<div class="text-lg mt-6 leading-relaxed max-w-4xl">

Inline `# @rbs (Integer, Integer) -> Integer` on the line above a `def`.

`TypeEnv` parses these at decode time and threads them into the slot-type table.

</div>

<div class="mt-8 italic opacity-80" v-click>

A call to `point.translate(dx, dy)` whose RBS types the receiver as `Point` binds statically to `Point#translate` at rewrite time. That's the hook the inliner uses to pick a callee.

</div>

<!--
§4 ¶5 (post.md line 98). Budget ~40s.

Verbatim:
"The slot-type table is fed partly by literals and assignments visible in the instruction stream and partly by inline RBS comments — `# @rbs (Integer, Integer) -> Integer` on the line above a `def` — which a `TypeEnv` built at decode time parses out. The contract's 'RBS signatures are truthful' clause is what lets the rewriter act on them: a call to `point.translate(dx, dy)` whose receiver the RBS types as `Point` binds statically to `Point#translate` at rewrite time, which is the hook the inliner actually uses to pick a callee."

Delivery: name-drop `TypeEnv` once, move on. The takeaway is the binding story, not the type table.
-->

---
layout: default
---

# The pipeline cascades

<v-clicks>

- **Inlining** exposes stash round-trips →
- **DeadStashElim** exposes producers →
- **ArithReassoc** exposes constant-only expressions →
- **ConstFold** exposes literal conditions →
- **DeadBranchFold** exposes unreachable blocks →
- ... feeding the next sweep.

</v-clicks>

<div class="mt-8 text-sm opacity-70" v-click>

Each pass manufactures the precondition for the next. Caps at 8 iterations — past that, a pass is either oscillating or reporting rewrites it didn't actually perform.

</div>

<!--
§4 ¶6 + ¶7 (post.md lines 100, 102). THE PAYOFF. Budget ~75s — don't rush.

Verbatim ¶6 (the pass list in pipeline order):
"Each pass is a class with an `apply` method that takes the function plus some context kwargs, walks a single function, recognizes a local pattern, and rewrites in place — logging every rewrite and every skipped opportunity so failure modes are visible instead of silent. Most iterate to a fixed point; only `InliningPass` is marked one-shot, since re-inlining an already-inlined site buys nothing. The default pipeline opens with `InliningPass` (splice the body of a visible `ARGS_SIMPLE`-shaped callee at the call site, stash arguments into local slots, drop the call), then `DeadStashElimPass` (delete the `setlocal_WC_0 x; getlocal_WC_0 x` pair when `x` isn't read afterwards), then `ArithReassocPass` (fold `(a + 1) + 2` shapes into `a + 3`). The rest is a fold-then-sweep cascade: three constant-folders run together — `ConstFoldTier2Pass` rewrites references to frozen top-level constants to their literal, `ConstFoldEnvPass` rewrites `ENV['FLAG']` to a `putstring` from a snapshot taken at install time, and `ConstFoldPass` collapses any all-literal arithmetic into its result — then `IdentityElimPass` catches `x && x`, `0 + n`, and `n * 1`, and `DeadBranchFoldPass` finishes with `putobject true; branchunless L` to nothing and `putobject false; branchunless L` to `jump L`."

Verbatim ¶7 (the cascade itself):
"The passes feed each other: inlining exposes a stash round-trip for dead-stash, dead-stash exposes the producer to arith, arith exposes a constant-only expression to const-fold, const-fold exposes a literal condition to dead-branch-fold, dead-branch-fold exposes new unreachable blocks for the next sweep. None of the individual moves is novel; what matters is that each manufactures the precondition for the next. The pipeline caps at eight iterations; past that, a pass is either oscillating or reporting rewrites it didn't actually perform."

Delivery: pace the clicks. The "→" between each is load-bearing — each arrow is a different pass winning. The final click ("feeding the next sweep") is the one that lands "this is actually a compiler." Don't hurry.
-->

---
layout: default
---

# The harness

```ruby {all|1|3|4}
require "optimize"

Optimize::Harness.install         # hook load_iseq process-wide
fast = Optimize.optimize(src)     # one-shot: source -> new iseq
```

<v-clicks>

- `.install` hooks the same `rb_iseq_load_iseq` path bootsnap's used for years — every subsequently-required file routes through the pipeline.
- Opt out per-file: `# rbs-optimize: false` in the first 5 lines.
- Any codec or pipeline failure returns `nil`. MRI falls back to the normal compile path. *A slow method is acceptable; a miscompiled one is not.*

</v-clicks>

<!--
§4 ¶8 + ¶9 (post.md lines 104, 106-111). Budget ~50s.

Verbatim ¶8:
"None of this runs unless you ask for it. `Optimize::Harness.install` defines `RubyVM::InstructionSequence.load_iseq(path)` — the same process-wide hook MRI calls from `rb_iseq_load_iseq` whenever it's about to load a file, and the same hook bootsnap has been using for years — and routes every subsequently-required file through the pipeline. Source files can opt out by putting `# rbs-optimize: false` in the first five lines. On any pipeline or codec failure the harness warns and returns `nil`, which tells MRI to fall back to the normal compile path. A slow method is acceptable; a miscompiled one is not."

Delivery: the `.install` / `.optimize` split: process-wide hook vs. one-shot. Hit the last click ("a slow method is acceptable") as a landing — that's the reliability contract, and it's what makes this harness safe to try.
-->

---

<!-- §5 demos — TO BE DECOMPOSED -->

---

<!-- §6 tradeoffs — TO BE DECOMPOSED -->

---

<!-- §7 close — TO BE DECOMPOSED -->
