# Talk Blog Post Draft Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Multi-session:** This plan is designed to be executed across multiple sessions. Tick each `- [ ]` box as steps land and keep this file in sync with `post.md` on every commit. The progress tracker immediately below is the first thing a future session should read.

**Goal:** Draft the full RubyKaigi 2026 talk "Ruby the Hard Way" as a single long-form blog post at `post.md`, to be the source material from which speaker notes and slides are later derived.

**Architecture:** Outline-first, section-by-section drafting. Two research subagents run upfront (author voice; RubyKaigi 2026 schedule callbacks). Each talk section (§1–§7 plus intro) is a standalone task: load the relevant shipped artifacts into context, draft prose with the voice/callbacks in hand, self-edit, commit. Draft is prose-only; slide/notes extraction is a later plan.

**Tech Stack:** Markdown. No build step. Numbers cited from `docs/demo_artifacts/*.md` with `{TBD-N}` placeholders where the author plans to re-run benchmarks before publishing.

---

## Progress tracker

Update this block in every commit that changes plan state. Sections marked ✅ are drafted and committed to `post.md`; 🚧 means outlined but not drafted; ⬜ means untouched.

- ✅ Task 0: Setup — research subagents + style guide + `post.md` skeleton
- ✅ Task 1: Intro (title, TL;DR, about-me)
- ✅ Task 2: §1 Cold open
- ⬜ Task 3: §2 The contract
- ⬜ Task 4: §3 YARV, properly
- ⬜ Task 5: §4 Building a toy optimizer
- ⬜ Task 6: §5 Demos
- ⬜ Task 7: §6 Tradeoffs
- ⬜ Task 8: §7 Close
- ⬜ Task 9: Full read-through + consistency pass
- ⬜ Task 10: Benchmark-number freshness check (when author signals)

## Ground rules for every drafting task

These apply to every `§N` task below. Read them before drafting any section.

1. **Voice:** first-person singular ("I"). Follow `docs/talk/style-notes.md` (produced in Task 0). No "we", no royal plural.
2. **Tone:** "love letter to a bad idea." Jokes, asides, memes welcome. Profanity sparingly. No production war stories.
3. **Audience:** RubyKaigi 2026 attendees. They know Ruby. They don't necessarily know YARV internals. They've seen other perf talks on the schedule — use `docs/talk/kaigi-callbacks.md` (Task 0) to reference peer talks by name when the topic overlaps.
4. **Callbacks rule:** when a shipped RubyKaigi 2026 talk covers "the serious version" of something I'm doing for fun (YJIT, ZJIT, MJIT, prism, iseq persistence, type systems), name it in a sentence and link it. My talk is the amateur-hour counterpart; the callback is what earns the framing.
5. **Code blocks:** real code from the repo when it fits on one slide's worth of lines (≤20). Simplify with `# …` elisions when longer. iseq disasm uses `ruby-bytecode` MCP tools (`disasm`), not shelled-out `ruby`.
6. **iseq diff style:** for multi-pass walkthroughs, show the *original* disasm, then *diff-style* for each subsequent pass (`-` / `+` lines, or `(removed)` inline annotations). The user can click through these fast — favor many small slides over one dense one.
7. **Benchmark numbers:** cite numbers verbatim from `docs/demo_artifacts/<fixture>.md`. Wrap each in `{TBD-N}` (e.g. `{TBD-polynomial-ratio}`) so Task 10 can find-and-replace them. Every number gets a placeholder even if it looks stable.
8. **Self-contained:** no external links except RubyKaigi schedule callbacks and the repo's own GitHub URL at the end. No deep-link to specific files in this draft.
9. **Pacing target:** ≥2 slides/min in the talk ⇒ ~60 slides for 30 min. Each prose paragraph or code block roughly maps to one slide. Aim for prose that decomposes naturally into slide-sized chunks.
10. **Maintenance:** after each task's commit, update the progress tracker in this plan file in the same commit.

---

## Task 0: Setup — research + skeleton

**Files:**
- Create: `docs/talk/style-notes.md` (output of voice-research subagent)
- Create: `docs/talk/kaigi-callbacks.md` (output of schedule-research subagent)
- Create: `post.md` (top-level skeleton)
- Modify: `docs/superpowers/plans/2026-04-23-talk-blog-post-draft.md` (tick Task 0 boxes)

- [ ] **Step 0.1: Dispatch two subagents in parallel.**

Send one `Agent({subagent_type: "general-purpose", ...})` call per agent, in a single message, with `run_in_background: false` so their outputs come back together.

Agent A — **voice-research**:

> Research Samuel Giddins's writing voice from three sources: his blog at `blog.segiddins.me`, the travel blog at `traveling.engineer`, and his SpeakerDeck (`speakerdeck.com/segiddins`). Fetch at least five posts across the two blogs and skim at least three decks. Produce `docs/talk/style-notes.md` with: (a) 5–8 concrete stylistic tics (sentence length, comma usage, hedging, asides, footnote style, joke rhythm, typography, em-dash vs parentheses, etc.), each with a short verbatim quote; (b) 3 "don'ts" — things his writing does *not* do; (c) a 150-word pastiche paragraph on an unrelated topic ("my cat's opinion of the vacuum cleaner") that another drafter could use as a template. Return nothing in your reply beyond "done, saved to <path>".

Agent B — **schedule-research**:

> Research the RubyKaigi 2026 schedule (`rubykaigi.org/2026` or the latest published schedule page — verify the URL with a web search first). List every talk whose topic intersects with: YARV / iseq, any JIT (YJIT, ZJIT, MJIT, RJIT), prism parser, Ruby type systems (RBS, Sorbet, Steep), bytecode compilation, VM internals, benchmarking, Ractors if they touch codegen. For each, produce an entry in `docs/talk/kaigi-callbacks.md`: speaker, title, one-line summary, and a one-sentence "callback angle" — how Samuel's amateur-hour optimizer talk can honestly reference this one without stepping on it. Also note any talks that my talk should deliberately *avoid* duplicating. Return nothing beyond "done, saved to <path>".

- [ ] **Step 0.2: Review both research outputs.**

Read `docs/talk/style-notes.md` and `docs/talk/kaigi-callbacks.md`. If the style notes feel generic or the callbacks list is empty, re-dispatch with sharper instructions. Don't proceed until both feel usable.

- [ ] **Step 0.3: Create `post.md` skeleton.**

Write the following to `post.md`:

```markdown
# Ruby the Hard Way: Writing Bytecode to Optimize Plain Ruby

*A love letter to a bad idea. RubyKaigi 2026.*

## TL;DR

{TBD-intro-tldr}

## About me

{TBD-about-me}

## §1 — A love letter to a bad idea

{TBD-§1}

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
```

- [ ] **Step 0.4: Commit.**

```bash
jj commit -m "docs(talk): scaffold post.md + research voice + kaigi callbacks"
```

Then tick Task 0 in the progress tracker and squash the tick into the same commit:

```bash
# edit plan file to mark Task 0 ✅
jj squash -u
```

---

## Task 1: Intro — title, TL;DR, about-me

**Files:**
- Modify: `post.md` (replace `{TBD-intro-tldr}` and `{TBD-about-me}`)
- Modify: this plan file (progress tracker)

**Context to load before drafting:**
- `docs/superpowers/specs/2026-04-19-talk-structure-design.md` (thesis section)
- `docs/talk/style-notes.md`

- [ ] **Step 1.1: Draft TL;DR.**

Target 80–120 words, three paragraphs: (1) what the talk is about ("I wrote a peephole optimizer that rewrites YARV bytecode by hand, under a handful of rules Ruby-the-language can't assume but Ruby-the-programmer often can"); (2) the payoff shape ("three fixtures, real benchmark deltas, one Claude gag"); (3) the frame ("this is for fun and for understanding YARV end-to-end, not for production"). Replace `{TBD-intro-tldr}`.

- [ ] **Step 1.2: Draft about-me.**

Target 60–100 words. Cover: name, role at Persona (Principal Engineer — confirm current title from `~/.claude/CLAUDE.md` or signature), maintainer roles (Bundler, RubyGems), and a one-line "why this talk" that ties to the love-letter frame. Keep it short — one slide. Replace `{TBD-about-me}`.

- [ ] **Step 1.3: Self-edit for voice.**

Re-read both paragraphs against `docs/talk/style-notes.md`. If they read as generic "I built X" prose rather than Samuel's voice, rewrite. Target pastiche quality, not resume quality.

- [ ] **Step 1.4: Commit + tick tracker.**

```bash
jj commit -m "docs(post): intro — TL;DR and about-me"
# edit plan file: Task 1 ✅
jj squash -u
```

---

## Task 2: §1 — Cold open

**Files:**
- Modify: `post.md` (replace `{TBD-§1}`)
- Modify: this plan file (progress tracker)

**Context to load before drafting:**
- `docs/superpowers/specs/2026-04-19-talk-structure-design.md` (§1 notes, thesis)
- `docs/talk/style-notes.md`
- `docs/talk/kaigi-callbacks.md` (for the "serious perf talk" callbacks)

- [ ] **Step 2.1: Draft §1.**

Target 300–400 words, ~6–8 slides worth. Arc:

1. Open with a confession, not a war story. "I want to tell you about something I built this year, and I want to be honest up front: you should not do this in production." One to two paragraphs establishing the love-letter frame.
2. The contrast paragraph: name one or two RubyKaigi 2026 talks doing the *serious* version of performance work (pick from `kaigi-callbacks.md` — prefer YJIT/ZJIT/prism talks). "If you want to make Ruby faster for real, go see <speaker>'s talk at <time>. I am not doing that."
3. What I did instead, in one sentence: "I wrote a peephole optimizer that rewrites YARV bytecode by hand, under a handful of rules Ruby-the-language can't assume but Ruby-the-programmer often can."
4. The pitch: "By the end of this talk you will be able to read a YARV instruction stream, you will know why Ruby can't optimize code you obviously could, and you will have permission to go write your own terrible optimizer for a weekend."

- [ ] **Step 2.2: Self-edit.**

Check: voice matches style notes, callback to at least one real 2026 talk, no production framing, lands the invitation.

- [ ] **Step 2.3: Commit + tick tracker.**

```bash
jj commit -m "docs(post): §1 cold open"
# edit plan file: Task 2 ✅
jj squash -u
```

---

## Task 3: §2 — The contract

**Files:**
- Modify: `post.md` (replace `{TBD-§2}`)
- Modify: this plan file (progress tracker)

**Context to load before drafting:**
- `docs/superpowers/specs/2026-04-19-talk-structure-design.md` (§2 notes, "ground rules" list)
- `docs/todo.md` (for which rules each shipped pass actually exercises)
- `docs/talk/kaigi-callbacks.md` (RBS/Sorbet/Steep talks for the "truthful RBS" rule callback)

- [ ] **Step 3.1: Draft §2 framing paragraph.**

Target 100–150 words. Establish the observation: a general-purpose VM must assume the worst because any of the following might be true at runtime, but an application programmer usually knows none of them are. Introduce the framing question you'll keep returning to: *"why doesn't Ruby itself do this?"* Answer: "because it can't assume the rule holds."

- [ ] **Step 3.2: Draft each of 5 rules.**

One paragraph per rule (~80–120 words each). Format per rule: **Rule name in bold**, one-sentence statement, then two short paragraphs: **"What it unlocks:"** (which pass(es) in the shipped optimizer depend on it; name them) and **"Why Ruby can't assume it:"** (the specific hole — monkey-patching, `prepend` after load, unsound RBS, `ENV[]=` at runtime, `const_set`).

Rules, in this order:

1. **Core BOPs are not redefined.** Unlocks: `ConstFoldPass` (literal arithmetic), `ArithReassocPass` v1–v4.1 (`+ - * / %` reassociation). Why not: `Integer#+` can be monkey-patched at any time.
2. **No `prepend` after load into classes the optimizer inlined from.** Unlocks: `InliningPass`. Why not: `Module#prepend` inserts a link in the method resolution chain that invalidates a resolved receiver.
3. **RBS inline signatures are truthful.** Unlocks: `InliningPass` receiver resolution (`SlotTypeTable`). Callback: the several RubyKaigi 2026 talks on RBS/type systems treat this as a *goal*; I treat it as a *rule*. Why not: no enforcement — comments drift.
4. **`ENV` is read-only after load.** Unlocks: `ConstFoldEnvPass`. Why not: `ENV["X"] = "Y"` works at runtime.
5. **Top-level constants are not reassigned and `const_set` is not used after load.** Unlocks: `ConstFoldTier2Pass`. Why not: `X = 1; X = 2` only warns.

- [ ] **Step 3.3: Close §2 with the recurring-question line.**

Two to three sentences setting up §3: "Everything that follows is just cashing in the rules above. When you see a rewrite that feels illegal, that's correct — it *is* illegal in general. The contract is what makes it legal for us."

- [ ] **Step 3.4: Commit + tick tracker.**

```bash
jj commit -m "docs(post): §2 the contract"
# edit plan file: Task 3 ✅
jj squash -u
```

---

## Task 4: §3 — YARV, properly

**Files:**
- Modify: `post.md` (replace `{TBD-§3}`)
- Modify: this plan file (progress tracker)

**Context to load before drafting:**
- `docs/superpowers/specs/2026-04-19-talk-structure-design.md` (§3 notes)
- `docs/yarv-instructions.md`
- `docs/talk/kaigi-callbacks.md` (prism talks for the parser callback; iseq-persistence talks if any)
- An example iseq — use the `disasm` MCP tool on `def answer; 2 + 3; end` for the canonical toy

- [ ] **Step 4.1: Draft the pipeline overview.**

Target 200–250 words. Cover the `source → parse (prism) → compile → iseq → VM` pipeline at a high level, one paragraph. Name prism and callback to the RubyKaigi 2026 prism talk (if present in callbacks). One paragraph on what an iseq *is* — the top-level `RubyVM::InstructionSequence`, its array-of-arrays shape, nested child iseqs for blocks/methods.

- [ ] **Step 4.2: Walk through a minimal iseq.**

Use `def answer; 2 + 3; end`. Show the disasm output inline (from `disasm` MCP tool). Annotate line-by-line what each instruction does, with emphasis on: `putobject`, `opt_plus`, `leave`. This is the moment the reader learns to read iseq listings.

- [ ] **Step 4.3: Cover the specific instructions that appear later.**

One paragraph, not one-per-instruction. List and briefly describe: `send`/`opt_send_without_block`, `opt_plus`/`opt_mult`/`opt_minus`/`opt_div`/`opt_mod`, `getlocal`/`setlocal` (and mention EP levels briefly), `branchif`/`branchunless`/`branchnil`/`jump`, `putobject` / `putobject_INT2FIX_0_` / the shortcut opcodes. Don't overspend — the demos will surface the rest in context.

- [ ] **Step 4.4: Drop the codec paragraph.**

~100 words. "Between iseqs and bytes there's a round-trip — `InstructionSequence.to_binary` / `load_from_binary`. The optimizer uses it so the rewritten iseqs actually execute. The codec had a couple of bugs I had to fix along the way (backward branches decoded as enormous unsigned ints; bignum-digit encoding segfaults above 30 bits). It's not the talk's topic — mentioning it so you know it exists."

- [ ] **Step 4.5: Close §3.**

One-sentence bridge: "With a way to read and a way to write, the optimizer is just the thing that sits between."

- [ ] **Step 4.6: Commit + tick tracker.**

```bash
jj commit -m "docs(post): §3 YARV walkthrough"
# edit plan file: Task 4 ✅
jj squash -u
```

---

## Task 5: §4 — Building a toy optimizer

**This is the largest section (~10 min, ~20–25 slides). Allow multiple sub-sessions.**

**Files:**
- Modify: `post.md` (replace `{TBD-§4}`)
- Modify: this plan file (progress tracker)

**Context to load before drafting:**
- `docs/superpowers/specs/2026-04-19-talk-structure-design.md` (§4 notes — the peephole framing paragraph)
- `docs/superpowers/specs/2026-04-19-optimizer.md`
- `docs/superpowers/specs/2026-04-19-pass-inlining.md`, `…-pass-arith-specialization.md`, `…-pass-const-fold.md`
- `docs/superpowers/specs/2026-04-22-rbs-type-env-v1-design.md`
- `docs/superpowers/specs/2026-04-23-pipeline-fixed-point-iteration-design.md`
- `optimizer/lib/optimize/pipeline.rb` (for the real pass order in `Pipeline.default`)
- Per-pass source files under `optimizer/lib/optimize/passes/`

- [ ] **Step 5.1: Draft the architecture overview.**

Target 200 words. The shape: iseq → IR (our mutable representation) → chain of passes → IR → iseq binary → VM. Call out what IR is and isn't (it's the instruction stream plus annotations; it is *not* a CFG or SSA). Name the RBS type environment and fixed-point pipeline as the two non-pass pieces of infrastructure. This paragraph is where "weave peephole framing" starts — introduce the peephole idea here without capitalizing it yet.

- [ ] **Step 5.2: Draft the peephole subsection.**

Target 250 words. Name the shape explicitly: "Every shipped pass is a peephole — it scans a small sliding window of adjacent instructions and rewrites it in place. No control-flow graph, no dataflow. `while i < insts.size; match window at i; maybe splice; advance`." Give the three canonical window shapes: two-instruction (`lit; branch*`), three-instruction (`lit; lit; opt_op`), variable-length (the inliner's `send`-site). Say up front what this ceiling excludes (§6 will revisit): reachability analysis, def-use, real DCE.

- [ ] **Step 5.3: Draft the RBS-env micro-subsection.**

Target 150 words. Short by design. Explain: rbs-inline comments give me a type environment; `SlotTypeTable` maps `(slot, level) → type`; the inliner uses this to resolve `p.distance_to(q)` to a specific method. Callback to RBS/Sorbet/Steep RubyKaigi talks from `kaigi-callbacks.md` as "the serious version of what I'm using here as a rule." Note: I did not do much work here — it's an interesting *application* of typing, not novel typing work.

- [ ] **Step 5.4: Draft Pass 1 — const folding.**

Target 300 words + one iseq walkthrough. Introduce all four tiers in one paragraph (literal; frozen top-level constants; RBS-typed identity via IdentityElim; ENV). Then pick one tier for the walkthrough: **Tier 2 frozen constants**, because it cascades most visibly. Show `SCALE = 12; SCALE * 3` or equivalent pulled from the polynomial fixture — original iseq, post-Tier-2 iseq (diff style), commentary. Mention that Tier 2 depends on the "no const reassignment" rule from §2. Fold a short aside on `ConstFoldEnvPass` (two sentences).

- [ ] **Step 5.5: Draft Pass 2 — arithmetic reassociation + identity elim.**

Target 300 words + two iseq diffs. The payoff example is the polynomial chain `n * 2 * SCALE / 12 + 0`. Walk through: original → after Tier 2 (SCALE folds) → after ArithReassoc v4.1 (`12/12 → 1`) → after IdentityElim (`*1` and `+0` strip) → `n`. Four slides' worth; one diff per transition. Mention v4.1's exact-divisibility sub-case (`*6/2 → *3`). Call out explicitly: this multi-pass cascade is what the **fixed-point pipeline** is for (next subsection).

- [ ] **Step 5.6: Draft Pass 3 — inlining.**

Target 300 words + one iseq walkthrough. The payoff is `Point#distance_to`. One paragraph on the mechanism: resolve receiver via `SlotTypeTable`, splice callee body, shift local refs, stash `self` so `putself` in the callee body still means the *callee's* receiver (the aliasing-bug anecdote from the todo file is a candidate aside). Show the call-site disasm before and after inlining. Name what v3 handles (argc ≤ 1, typed receivers, FCALL) and what it doesn't (argc ≥ 2, ivar access, kwargs, blocks).

- [ ] **Step 5.7: Draft the fixed-point subsection.**

Target 150 words. Phase-ordering is a real problem: ArithReassoc runs before Tier 2 sees `SCALE = 12`, finds a non-literal, gives up. The dumb solution that works: wrap the per-function pass run in a loop that iterates until nothing rewrites. Cap at 8 iterations. Polynomial converges in 3. Fold in one sentence: "This retires a whole class of ordering bugs for the price of a loop."

- [ ] **Step 5.8: Draft the DeadBranchFold + DeadStashElim aside.**

Target 100 words. Two small peephole passes that earn their keep in the presence of the first three: DeadBranchFold collapses `lit; branch*` into a `jump` or nothing; DeadStashElim removes the `setlocal X; getlocal X` round-trip the inliner leaves behind. "Peepholes feeding peepholes" — this is where the architecture pays off.

- [ ] **Step 5.9: Close §4.**

One paragraph bridging to §5: "With the passes and the fixed-point loop, running the pipeline on a real Ruby file produces a rewritten iseq you can hand back to the VM. Three fixtures exercise the combination end-to-end."

- [ ] **Step 5.10: Commit + tick tracker.**

```bash
jj commit -m "docs(post): §4 building a toy optimizer"
# edit plan file: Task 5 ✅
jj squash -u
```

---

## Task 6: §5 — Demos

**Files:**
- Modify: `post.md` (replace `{TBD-§5}`)
- Modify: this plan file (progress tracker)

**Context to load before drafting:**
- `optimizer/examples/polynomial.rb`, `point_distance.rb`, `sum_of_squares.rb`
- `docs/demo_artifacts/polynomial.md`, `point_distance.md`, `sum_of_squares.md`

- [ ] **Step 6.1: Draft the demos intro.**

Target 100 words. "Three fixtures. Each lives in `optimizer/examples/`, each has a committed walkthrough artifact showing every pass's before/after iseq, and each has a benchmark number I'll be honest about." Name them: polynomial (payoff demo — full cascade), point_distance (inlining demo), sum_of_squares (peephole-ceiling demo).

- [ ] **Step 6.2: Draft polynomial demo.**

Target 250 words + staged iseq. The headline: `compute(n)` goes from ~8 instructions to ~2; benchmark ~`{TBD-polynomial-ratio}`x. Show the Ruby source (with the `SCALE` constant and the arithmetic chain), then the *final* collapsed iseq. Then a compressed cascade summary referencing §4's walkthrough (don't re-walk — gesture). Cite the fixed-point iteration count (`{TBD-polynomial-iters}`).

- [ ] **Step 6.3: Draft point_distance demo.**

Target 250 words + staged iseq. Headline: inlining the `distance_to` call site. Benchmark `{TBD-point-distance-ratio}`x. Show the Ruby source (`Point` class + the benchmark loop), the call site before and after inlining. Be honest: the benchmark ratio is small (~1.01x) because inlining shifts work rather than eliminating it — call this out as the "honest numbers" moment. Fold in a "why this is still worth doing" line: it unlocks folds that couldn't see across the call boundary.

- [ ] **Step 6.4: Draft sum_of_squares demo.**

Target 200 words. Headline: most passes report `(no change)`. Use this as the teaching moment: no shipped pass is loop-aware, and `while` is CFG-shaped. Cite the "Loop-aware passes" section of `docs/todo.md` as future work. This demo is where the peephole-ceiling framing from §4 comes home. Benchmark `{TBD-sum-of-squares-ratio}`x (likely ~1.0x).

- [ ] **Step 6.5: Draft the benchmark-methodology aside.**

Target 80 words. One paragraph: benchmark-ips, warmup, running under the ruby-bytecode MCP's Docker sandbox for reproducibility, caveats (single machine, not production). Honest-numbers frame: "these fixtures were chosen to make the optimizer look good; the sum_of_squares number is the honest counterweight."

- [ ] **Step 6.6: Commit + tick tracker.**

```bash
jj commit -m "docs(post): §5 demos"
# edit plan file: Task 6 ✅
jj squash -u
```

---

## Task 7: §6 — Tradeoffs (and when not to)

**Files:**
- Modify: `post.md` (replace `{TBD-§6}`)
- Modify: this plan file (progress tracker)

**Context to load before drafting:**
- `docs/superpowers/specs/2026-04-19-talk-structure-design.md` (§6 notes)

- [ ] **Step 7.1: Draft §6.**

Target 250 words, ~5 slides. Four beats:

1. **Debuggability.** Error backtraces reference the rewritten iseq. Line numbers still approximately work — iseqs carry line info — but if you're stepping through code, you're stepping through my rewrite, not yours.
2. **Ruby version drift.** The codec format is not stable across Ruby versions. Every minor version bump is a potential rewrite session. Contrast with YJIT's tight VM coupling — same problem, their problem is funded.
3. **A broken assumption is a miscompile.** If you monkey-patch `Integer#+` at runtime, your program does not slow down; it computes the wrong answer. "Miscompile, not slowdown" as a one-liner.
4. **The peephole ceiling.** Reachability, def-use, real DCE, loop-invariant hoisting — none of these fit in a sliding window. Real optimizers use IRs with CFGs and SSA. Callback: YJIT / ZJIT talks from `kaigi-callbacks.md` as "the tool you reach for when the peephole runs out."

- [ ] **Step 7.2: Commit + tick tracker.**

```bash
jj commit -m "docs(post): §6 tradeoffs"
# edit plan file: Task 7 ✅
jj squash -u
```

---

## Task 8: §7 — Close

**Files:**
- Modify: `post.md` (replace `{TBD-§7}`)
- Modify: this plan file (progress tracker)

**Context to load before drafting:**
- `docs/superpowers/specs/2026-04-23-claude-code-gag-pass-design.md`
- `docs/demo_artifacts/claude_gag.md`, `docs/demo_artifacts/claude_loop.md`
- `docs/superpowers/specs/2026-04-19-talk-structure-design.md` (§7 notes)

- [ ] **Step 8.1: Draft the invitation.**

Target 100 words. "Write a terrible optimizer for a weekend. You'll understand YARV better. You'll hit every bug I hit and some I didn't. You'll learn why real VMs make the choices they do by trying to avoid making them." Lands the love-letter frame.

- [ ] **Step 8.2: Draft the Claude gag.**

Target 300 words + one iseq. Setup: "Of course, this is 2026 — I didn't even write my own passes, I asked Claude Code to." Show `claude_loop.md`'s iteration 2 win: Claude took a 26-instruction `sum_of_squares` iseq and produced a 21-instruction one, semantically identical on 5 test inputs, by doing actual CFG-level dead-code elimination that my peephole pipeline explicitly can't. Show the before/after inline. Call the punchline: CFG-level DCE is out of scope for my passes; it's the first thing Claude did. "For fun. Not for production."

- [ ] **Step 8.3: Draft the close.**

Target 60 words. Links: repo URL, my blog, Persona careers if relevant. "Thanks. Questions." One sentence.

- [ ] **Step 8.4: Commit + tick tracker.**

```bash
jj commit -m "docs(post): §7 close"
# edit plan file: Task 8 ✅
jj squash -u
```

---

## Task 9: Full read-through + consistency pass

**Files:**
- Modify: `post.md` (in-place edits)
- Modify: this plan file (progress tracker)

- [ ] **Step 9.1: Read `post.md` top to bottom in one sitting.**

Note anywhere the voice slips, a callback is dropped, a paragraph repeats something earlier, or a technical detail contradicts another section. Fix inline as you read.

- [ ] **Step 9.2: Check slide-count math.**

Count slides-worth (paragraphs + code blocks) per section; target ≈ these per-section minimums to hit ≥60 total for 30 min at ≥2 slides/min:

- Intro: 3 slides
- §1: 5
- §2: 8 (framing + 5 rules + closer)
- §3: 8
- §4: 18 (the big one)
- §5: 10
- §6: 5
- §7: 6

Total target: 63. If short anywhere, expand. If long in §4 or §5, split paragraphs — slides are cheap.

- [ ] **Step 9.3: Grep for `{TBD-` placeholders.**

```bash
rg '\{TBD-' post.md
```

Every `{TBD-N}` that is a *benchmark number* stays until Task 10. Every other `{TBD-` must be replaced.

- [ ] **Step 9.4: Commit + tick tracker.**

```bash
jj commit -m "docs(post): consistency pass after full draft"
# edit plan file: Task 9 ✅
jj squash -u
```

---

## Task 10: Benchmark-number freshness check

**Triggered by author signal ("run the numbers"). Do not run unprompted.**

**Files:**
- Modify: `post.md` (replace `{TBD-*}` benchmark placeholders)
- Modify: this plan file (progress tracker)

- [ ] **Step 10.1: Re-run the three demo fixtures.**

For each of polynomial, point_distance, sum_of_squares: regenerate artifacts via `bin/demo <fixture>` (routed through the ruby-bytecode MCP so it stays sandboxed). Capture the benchmark ratio, instruction-count delta, and fixed-point iteration count from the refreshed `docs/demo_artifacts/<fixture>.md`.

- [ ] **Step 10.2: Replace placeholders in `post.md`.**

```bash
rg '\{TBD-' post.md
```

Replace each with the refreshed number. If a number changed from what the section's prose implies (e.g. polynomial ratio dropped below 1.1x, invalidating a claim), flag it for the author rather than silently rewriting.

- [ ] **Step 10.3: Commit + tick tracker.**

```bash
jj commit -m "docs(post): refresh benchmark numbers"
# edit plan file: Task 10 ✅
jj squash -u
```
