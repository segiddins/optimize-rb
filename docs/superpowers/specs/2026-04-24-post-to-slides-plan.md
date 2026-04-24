# Converting post.md to Slidev deck in ≤1 hour

Plan for turning a finalized `post.md` (≈3,700 words, 7 sections) into a Slidev deck for the RubyKaigi 2026 talk. Executed *after* the post is complete; this doc is the playbook to pick up then.

## Premise

Post.md at full length is about right for a 30-minute talk verbatim, so the post serves as **speaker notes**. Slides are visual support, not text replication. That's the lever that makes an hour feasible at the target cadence.

## Cadence

- 30-min talk, fast delivery. **Average ~20–30 s/beat, but non-uniform** — dense code listings hold 45–90 s while punchline/transition beats fly by in 5–10 s. Don't pad the fast beats to hit an average.
- Rough target: **60–90 beats total**. Implementation plan: **~30–40 slide files × ~2 `v-click` reveals each** on average. Hand-writing 70 distinct slide files in an hour is unrealistic; reveals are what make the arithmetic work.
- Slide text budget scales with beat duration: fast reveal beats are **3–8 words**; a slide you'll sit on for a minute can carry a full code block and a sentence of setup. Prose stays in speaker notes either way.

## Tool

- **Slidev**, committed in-repo at `talk/slides.md` alongside `post.md` and `talk/references.md`.
- Default or `seriph` theme; no custom theming.
- Monospace code font that renders YARV listings cleanly.
- Export to PDF as a backup artifact at the end.

## Beat budget (adjust after §5–7 prose lands)

| Section | Beats | Notes |
|---|---|---|
| Title + about | 3–5 | Repo URL, handle, one-line pitch |
| §1 framing | 6–8 | "love letter to a bad idea", what this isn't |
| §2 contract | 10–12 | One beat per clause + one beat per violation (RSpec mocks, APM `prepend`, Rails reload) |
| §3 YARV | 15–20 | `def add` listing alone is ~5 beats (one per line, one per call-out) |
| §4 optimizer | 12–15 | One beat per pass; cascading-rewrites paragraph = reveal-per-pass |
| §5 demos | 10–15 | Before/after iseq diffs are natively click-shaped |
| §6 tradeoffs | 5–7 | |
| §7 close | 2–3 | Repo URL, Q&A flag before Matz's keynote |

Total ≈ 63–85 beats.

## Hour allocation

- **00:00–00:05** — scaffold: `npm init slidev@latest talk/slides`, pick theme, commit skeleton.
- **00:05–00:15** — structural pass: split post.md on `##` into section dividers; every fenced code block becomes its own slide; produces ~30 slide files.
- **00:15–00:40** — **beat pass** (bulk of work): on each content slide add `v-click` around bullets; on each code slide add line-highlight steps (`{1|2|3-4|all}`). This is where beats multiply.
- **00:40–00:50** — speaker notes: every paragraph in `post.md` lands in the `<!-- -->` notes block of the slide (or first slide of the cluster) it decomposes into. No paragraph left un-mapped; no slide cluster without notes. See "Speaker notes" below.
- **00:50–00:55** — polish + `slidev export` to PDF.
- **00:55–01:00** — buffer.

## What to skip in the hour

- Custom themes, custom CSS, per-slide layout tweaks.
- SVG diagrams drawn from scratch (a first-try Mermaid block for the optimizer pipeline is fine; don't debug it).
- Animations beyond `v-click`.
- Revising prose — if a paragraph needs rewording, that happens in post.md, not in the deck.

## Workflow during execution

Collaboration model for the implementation session: **paragraph-by-paragraph decomposition with review-as-you-go.** For each paragraph in post.md, I propose a beat-by-beat decomposition (word count scaled to beat duration, reveal structure, any code-line highlights); user gives feedback; I write the slide *and* paste the source paragraph into its notes block in the same step; move on. Keeps editorial control with the user while offloading the mechanical chunking, and ensures speaker notes can't be forgotten at the end.

## Speaker notes

Non-optional — the deck without notes is unusable on stage given the fast delivery and the density of §3/§4. Rules:

- **Every paragraph in `post.md` maps to exactly one slide or slide cluster.** During the beat pass, tag each cluster with a comment like `<!-- from §3 ¶4 -->` so the mapping is mechanically checkable at the end.
- **Speaker notes = the source paragraph, verbatim or lightly trimmed.** Don't paraphrase into a bullet list — the prose in `post.md` is already the speaking script; rewriting it on the way in is wasted work and introduces drift.
- **Multi-slide clusters** (e.g., a paragraph that becomes a code slide + 3 reveal beats) get the full paragraph on the *first* slide of the cluster. Don't chop the paragraph across slides; that fragments the script during delivery.
- **Title slide, section dividers, and TOC slides** get short cue notes ("transition to §3 — 'before I can talk about rewriting YARV, you have to be able to read it'") so there's no dead air when switching contexts.
- **Checklist at the end of the hour** (~2 min of the polish window): scan `slides.md` for slide clusters missing notes; scan `post.md` for paragraphs not tagged to a cluster. Both should be empty.

## Pre-decisions (before the hour starts)

1. **§3 opening listing.** `def add` is the obvious choice for "first YARV the audience sees." Confirm or pick a shorter alternative.
2. **§5 demo selection.** Pick the 3–4 before/after pairs; have iseq dumps staged in `docs/demo_artifacts/` (or similar) so slide-building is paste-and-highlight, not re-running the optimizer.
3. **§2 clause ordering on slides.** Post.md lists five clauses; deck may want to reorder for reveal rhythm (e.g., land the most-commonly-violated clause last for the "reasonable isn't good enough" turn).

## Gate before starting the timer

`post.md` is complete and you'd ship it as-is. If §5–7 are still TBD when the hour starts, the hour balloons into writing, not converting. This plan assumes the writing is done.

## Risks

- **§5 demo iseqs not pre-captured.** If a demo needs the optimizer re-run mid-hour, that's easily 10 min lost per demo. Mitigation: pre-decision #2.
- **Slidev theme quirks.** First-time use of a reveal/layout combo can eat time on debugging. Mitigation: stick to primitives (`v-click`, line highlights, code blocks) already known to work in the chosen theme.
- **Cadence drift.** Without self-imposed beat counting during the beat pass, slides regress uniformly to one-idea-per-slide. The talk's rhythm relies on a *mix* of slow-dwell slides and fast reveals; losing the fast ones flattens delivery. Mitigation: target beats per section up front, count as you go, and mark which slides are intended as fast beats.
