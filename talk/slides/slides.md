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

<!-- §2 contract — TO BE DECOMPOSED -->

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
