# Ruby the Hard Way: Writing Bytecode to Optimize Plain Ruby

*A love letter to a bad idea. RubyKaigi 2026.*

## TL;DR

As many talks this week have focused on, MRI is a stack-based bytecode VM implementation of Ruby. That bytecode is what _actually_ runs when you feed ruby source into MRI.
Dozens of people at this conference have put in real work to improve ruby performance for everyone, at every level of the stack. I am not one of them.
After looking at a bunch of `ISEQ`s (bytecode instruction sequences), I had a terrible idea: what if I made my ruby faster by hand-optimizing the ISEQs that ruby itself compiles to? Of course, I went way overboard — instead of making some edits by hand, I hand-wrote a prompt or two and had Claude build an entire ISEQ-optimizing compiler.

You should not do this in production. I'm not going to pretend otherwise. But if you want to know what YARV actually does, and why your perfectly reasonable Ruby doesn't get optimized the way you think it should — this is, to use an overloaded term, a love letter to a bad idea.

## About me

Hi, my name is Samuel Giddins, and you can find me as `@segiddins` almost everywhere on the internet.

In a past life, I wrote bugs for RubyGems & Bundler.

I'm currently a Security Engineer at Persona, wearing many many hats (even though my head really only fits one),
but the tl;dr is I fix stuff that's broken, and I build systems to help keep the company & our customers' data safe.

Since I joined Persona, I've been fortunate to help the team prepare to scale for some really big customer launches, and as a result I've spent a lot of time thinking about ruby & rails performance. This is not the talk about any of that professional work.

## §1 — A love letter to a bad idea

I want to be honest with you up front about what this talk is, and — more importantly — about what it isn't.

It isn't a war story. I don't have a production hotspot that refused to yield to profiling, I don't have a 50%-improvement graph, and I am not about to convince you to put any of this into your codebase.

This is RubyKaigi. You are about to watch, or you have already watched, some of the best people in the world doing serious work on Ruby performance. "The design and implementation of ZJIT & the next five years" is doing all of this properly, at runtime, with an actual IR. "Lightning-Fast Method Calls with Ruby 4.1 ZJIT" — earlier today — is the version of my inliner that comes with a deoptimization story and the last five years of engineering judgment attached. Those are the talks where "make Ruby faster" is a real statement. This is not one of those talks.

What I did instead, in one sentence: I hand-wrote a prompt or two, and had Claude Code build me a compiler that rewrites YARV bytecode under a handful of rules Ruby-the-language can't assume but Ruby-the-programmer almost always can.

(That sentence is also, roughly, the whole talk. If you're happy with just that, you're welcome to leave — but Matz's closing keynote is right after this, so you'd be coming back anyway. Save yourself the walk.)

Anyways. This was, more than anything, an excuse to learn more about YARV bytecode and what actually goes into building an optimizing compiler. I am very aware of how bad an idea it is. I'm going to show it to you anyway, because by the end of the next thirty minutes: you will be able to read a YARV instruction listing. You will understand why your perfectly reasonable Ruby doesn't get optimized the way you obviously think it should. And — this is the actual pitch — you will have permission to go write your own terrible optimizer for a weekend, just to see what happens.

## §2 — The contract

{TBD-§2}

## §3 — YARV, properly

{TBD-§3}

## §4 — Building a toy optimizer

{TBD-§4}

## §5 — Demos

{TBD-§5}

## §6 — Tradeoffs (and when not to)

{TBD-§6}

## §7 — Close

{TBD-§7}

---

*Source: [github.com/segiddins/ruby-the-hard-way-bytecode-talk]({TBD-repo-url})*
