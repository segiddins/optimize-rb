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

<!-- §3 YARV — TO BE DECOMPOSED -->

---

<!-- §4 optimizer — TO BE DECOMPOSED -->

---

<!-- §5 demos — TO BE DECOMPOSED -->

---

<!-- §6 tradeoffs — TO BE DECOMPOSED -->

---

<!-- §7 close — TO BE DECOMPOSED -->
