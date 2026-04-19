# Talk Structure: Ruby the Hard Way

**Talk:** *Ruby the Hard Way: Writing Bytecode to Optimize Plain Ruby*
**Venue:** RubyKaigi 2026
**Length:** 30 minutes
**Speaker:** Samuel Giddins

## Thesis

Ruby the language cannot assume its core is stable, its types are known,
or its methods aren't being monkey-patched. Ruby the programmer often
can. This talk is a love letter to a bad idea: taking those assumptions
and cashing them in by rewriting YARV bytecode ourselves.

It is explicitly not a "you should do this in production" talk. It is a
celebration of how much Ruby hands us, and an invitation to go break
things for a weekend and understand the VM better because of it.

## Audience takeaway

A mix, weighted roughly:
- Wonder — Ruby is more malleable than you realized
- Education — you now understand how YARV works end-to-end
- Invitation — go write your own terrible optimizer

Not a takeaway: "here is a production technique you should adopt."

## The artifact

A prewritten multi-pass optimizer (~400–600 LOC) operating on
`RubyVM::InstructionSequence` output. Three passes:

1. **Inlining** — replace a `send` with the callee's body, given a
   resolvable receiver
2. **Arithmetic specialization** — elide basic-operation redefinition
   guards under the "no core redef" rule
3. **Constant folding** — fold expressions the compiler won't, often
   only exposed *after* inlining

RBS inline signatures provide the type information that makes inlining
and specialization safe. Without them the optimizer falls back to
conservative rules; with them it can resolve polymorphic call sites.

No live coding. Code shown as commented excerpts.

## Demo targets

Two contrasting examples, both benchmarked:

- **Numeric kernel** (e.g. `sum_of_squares`) — showcases arithmetic
  specialization and constant folding
- **Object-y method** on user-defined classes (e.g. `Point#distance_to`)
  — showcases cross-class inlining guided by RBS types

## The contract (ground rules)

Presented as a slide early in the talk, framing everything that
follows:

- Core class basic operations (`Integer#+`, etc.) are not redefined
- No `prepend` into classes the optimizer has inlined from, after load
- RBS inline signatures are truthful
- (Likely one more — to be finalized during implementation)

Each rule is paired with what it unlocks. The framing question we keep
returning to is *"why doesn't Ruby itself do this?"* — and the answer is
always "because it can't assume this rule holds."

## Structure (30 min)

| # | Section | Minutes | Purpose |
|---|---------|---------|---------|
| 1 | Cold open — "a love letter to a bad idea" | 2 | Set tone: for fun and understanding, not production |
| 2 | The contract | 3 | Thesis up front: what we're assuming and what we win |
| 3 | YARV, properly | 5 | Compilation pipeline, iseq shape, the instructions we'll touch |
| 4 | Building a toy optimizer | 10 | Pipeline as architecture: IR, type env from RBS, three passes |
| 5 | Demos | 5 | Numeric + object-y examples, benchmarks, honest numbers |
| 6 | Tradeoffs & when not to | 2 | Debuggability, version drift, cost of a broken assumption |
| 7 | Close — invitation | 2 | "Write your own… or ask Claude Code to." Links. |

### Section notes

**§1 Cold open.** No production war story. No dramatic hook. A quiet,
honest confession: this talk is a love letter to a bad idea. It's
awesome that Ruby gives us everything we need to do this ourselves,
even if we probably shouldn't.

**§2 The contract.** This is the thesis slide. The whole talk hangs
off the observation that general-purpose VMs must be paranoid, but
application programmers often know more than the VM does.

**§3 YARV.** Teach it properly, not just in passing. By the end of this
section the audience can read an iseq listing. Covers: the `parse →
compile → iseq` pipeline at a high level, iseq internal shape, and the
specific instructions used later (`send`, `opt_plus`, `getlocal`,
`setlocal`, `leave`, plus whatever the demos surface).

**§4 Building the optimizer.** Architecture, not line-by-line code:
- iseq → IR (our own representation we can manipulate)
- Parse RBS inline signatures into a type environment
- Pass 1: inlining — call graph construction, receiver resolution via
  RBS, splicing callee instructions with local/stack fixup
- Pass 2: arithmetic specialization — using the "no BOP redef" rule
- Pass 3: constant folding — often only enabled by the inlining pass
- IR → iseq — hand back to the VM

**§5 Demos.** Two examples, with benchmarks. Called out honestly: these
are chosen to make the optimizer look good, and the measurement
methodology is shown.

**§6 Tradeoffs.** Short. Debuggability suffers. Ruby version drift
breaks us. A wrong assumption is a miscompile, not a slowdown.

**§7 Close.** "Write a terrible optimizer for a weekend — you'll
understand Ruby better." Then the gag: a pass that shells out to
Claude Code and asks it to optimize an iseq. Self-deprecating, lands
the "for fun" frame, gestures at where tooling is going. Links, QR,
done.

## What we are explicitly not covering

- **`InstructionSequence.load_from_binary` / persistence.** Mentioned
  in one sentence at most. It's cool but orthogonal to the optimizer
  story.
- **Production hotspot war stories.** We don't have one, and making
  one up would undercut the honest framing.
- **A comparison with YJIT / MJIT.** Tempting but off-thesis; we'd
  lose time explaining those for a takeaway that isn't ours.

## Open questions for implementation planning

- Exact numeric kernel and object-y method for the demos
- Final list of ground rules on the contract slide (currently ~3, may
  end at 4)
- Whether RBS is parsed from inline comments (via `rbs-inline`) or
  from sidecar `.rbs` files
- Benchmark harness — `benchmark-ips` is already wired via the MCP
  server; confirm it's what we present
- The Claude Code gag — scripted output or live-ish? (Probably
  scripted, given no live coding.)
