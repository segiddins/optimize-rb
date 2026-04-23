# RubyKaigi 2026 — callback opportunities

Source: <https://rubykaigi.org/2026/schedule/> (day1–day3, presentations/\*.html), confirmed via web search.

Context: Samuel's talk is "Ruby the Hard Way: Writing Bytecode to Optimize Plain Ruby" (Day 3), a peephole-optimizer demo that hand-writes / rewrites YARV iseqs to speed up plain Ruby hot paths. It is deliberately amateur-hour next to the compiler and type-system talks listed below. Use these callbacks to point the audience at the "serious" versions of the same problem while framing this talk as the one where you allow yourself to enjoy the bad idea.

## Core intersecting talks (JIT / iseq / VM / compiler)

### tekknolagi — "The design and implementation of ZJIT & the next five years" (Day 1)
Tour of ZJIT's current optimizations (constant folding, VN, escape analysis, scalar replacement, register allocation) and where it's going.
Callback angle: "ZJIT is doing all of this properly at runtime with IR; this talk is the opposite approach — do some of it once, ahead of time, by hand, at the bytecode level, for the 5% of hot code where you know more than any JIT can."

### jacob-shops — "Whose Memory is it Anyway" (Day 2)
New side-effect analysis in ZJIT enabling statement reordering and dead-code elimination.
Callback angle: "My peephole passes include a hand-rolled dead-stash eliminator that only works because I cheat and assume no side effects; Jacob's talk is what it looks like when you stop cheating and build a real effect system."

### k0kubun — "Lightning-Fast Method Calls with Ruby 4.1 ZJIT" (Day 3)
ZJIT's Lightweight Frames plus method inlining to make call overhead near-zero, and the YJIT→ZJIT story for 4.1.
Callback angle: "My inliner just splices callee iseqs into the caller and hopes; k0kubun is doing the real thing with frames, deopt, and call-site specialization — watch his talk if you want to know what I was pretending to do."

### s_isshiki1969 — "Invariants in my own Ruby: some things must never change" (Day 2)
Monoruby's JIT design, invariants, deoptimization, written in Rust from scratch.
Callback angle: "Invariants are exactly what my bytecode-level rewrites silently assume and can't defend; this is a good framing for 'what does a real JIT have to do that I skipped?'"

### ko1 — "The AST Galaxy to the Virtual Machine Blues" (Day 2)
ASTro: AST-level optimization framework, reimplementing parts of Ruby to compile AST to C.
Callback angle: "Ko1 is optimizing above YARV at the AST; I'm optimizing below source at YARV — same philosophy (optimize an IR Ruby already has), different altitude. Opens room for a 'pick your layer' joke."

### makenowjust — "(Re)make Regexp in Ruby: Democratizing internals for the JIT" (Day 3)
Pure-Ruby regexp engine so JITs can see through it; exposing Onigmo parser/char-class to Ruby.
Callback angle: "Another 'write it in Ruby so the JIT can eat it' story — rhymes with 'write the bytecode so the VM executes exactly what you meant.'"

### headius — "Twenty Years of JRuby" (Day 2)
JRuby retrospective: first Ruby JIT, threading, current state.
Callback angle: Light historical callback only — "people have been doing this seriously for 20 years; I did it for six months in my spare time."

### tagomoris — "The Journey of Box Building" (Day 1)
"Ruby Box" experimental feature introduced at Ruby 4.0; runtime determination of boxes.
Callback angle: Skim-relevant to value representation / VM internals. Worth referencing only if the box abstraction touches instruction semantics the peephole passes care about — otherwise skip.

## Type systems / static analysis (RBS / type inference)

### soutaro — "Making the RBS Parser Faster" (Day 2)
Profiling and rewriting the new RBS parser in C after a 10%–5× regression.
Callback angle: "Parser perf is a real engineering discipline; my 'optimizer' wouldn't survive a soutaro-grade profiling session and that's fine."

### mametter — "Practical TypeProf: Lessons from Analyzing Optcarrot" (Day 2)
TypeProf run against a real codebase (Optcarrot) to expose gaps in the analyzer.
Callback angle: Only a light nod — "The serious people are doing type inference on Optcarrot; I'm micro-optimizing a made-up polynomial."

### riseshia — "Good Enough Types: Heuristic Type Inference for Ruby" (Day 3, same day as Samuel)
LSP-based duck-typing heuristic: "these methods were called, it must be this class."
Callback angle: "Both of us are doing 'good enough' versions of a hard problem — riseshia for types, me for optimization. Pair them in the audience's head."

### _dak2_ — "No Types Needed, Just Callable Method Check" (Day 2)
Method-Ray: a Rust-backed tool that catches NoMethodError without type annotations.
Callback angle: Tangential — mention only if you want to riff on "pragmatic vs principled."

### Morriar — "Blazing-fast Code Indexing for Smarter Ruby Tools" (Day 3)
Rubydex: unified static-analysis indexer powering RubyLSP/Tapioca/Spoom.
Callback angle: Skip unless you need an example of "the tools that could one day tell my optimizer when it's safe to rewrite."

## Parser / compiler pipeline

### ydah_ — "Liberating Ruby's Parser from Lexer Hacks" (Day 1)
PSLR(1) in Lrama — parser tells lexer which tokens are valid.
Callback angle: Parser-level, not iseq-level. Skip unless framing "Ruby has many IRs and each gets its own rewrite story."

### spikeolaf — "Kingdom of the Machine: The Tale of Operators and Commands" (Day 1)
Foundational parsing problems (precedence, reductions).
Callback angle: Skip — too far from iseq.

## Benchmarking / profiling / performance-research

### osyoyu — "ext/profile, or How to Make Profilers Tell the Truth" (Day 1)
Why external Ruby profilers mislead (sampling bias, JIT'd-away methods, M:N); case for a VM-integrated profiler.
Callback angle: "Every 'x2 faster' slide in my talk is one osyoyu would rightly ask hard questions about; my benchmarks are benchmark-ips on toy iseqs, not production signal."

### nateberkopec — "Autoresearching Ruby Performance with LLMs" (Day 3)
LLM agents in a benchmark/try/verify loop to improve Ruby perf.
Callback angle: "Nate automates the loop I ran by hand for six months. If this talk is a love letter to a bad idea, his is a love letter to not doing it by hand."

### White_Green2525 — "Chasing Real-Time Observability for CRuby" (Day 2)
rrtrace: C-extension streaming TracePoint events to external process.
Callback angle: Skip unless you want an "observability vs. transformation" framing.

## Ractors touching codegen / concurrency-relevant

### eregontp — "Making Hash Parallel, Thread-Safe and Fast!" (Day 3)
Reimplementing Hash with a new lock for parallel reads/writes; NES emulator demo.
Callback angle: Skip for the bytecode framing — relevant only as "serious perf work elsewhere in the VM."

### TonsOfFun — "Million-Agent Ruby: Ractor-Local GC in the Age of AI" (Day 1)
Ractor-local GC, M:N threading.
Callback angle: Skip — GC/concurrency, not codegen.

### maciejmensfeld — "Thread-Coordinated Ractors: The Pattern That Delivers" (Day 2)
Production Ractor pattern in Karafka.
Callback angle: Skip — usage pattern, not codegen.

## Deliberately do NOT duplicate

- **k0kubun** (ZJIT method inlining) — Samuel's inliner is a toy version of the real thing. Call it out once, then get out of the way; do not spend stage time claiming his territory.
- **jacob-shops** (side-effect analysis for DCE / reordering in ZJIT) — Samuel's dead-stash pass is a simplistic DSE. Acknowledge jacob-shops has the grown-up version and move on.
- **tekknolagi** (ZJIT overall) — Do not explain ZJIT. Point at his talk.
- **osyoyu** (profilers) — Do not defend the benchmarking methodology as rigorous; concede upfront and point at osyoyu's talk for the real conversation.
- **s_isshiki1969** (invariants / deopt) — Do not pretend the peephole optimizer handles method redefinition, eval, Binding, etc. Wave at his talk when someone asks "what about `Integer#+` being redefined?"

## Same-day (Day 3) — be especially aware

segiddins, riseshia, k0kubun, makenowjust, Morriar, eregontp, jhawthorn, and yhara are all Day 3. The "serious JIT story" and the "good-enough heuristic" bracket this talk on the same day; lean into that — Samuel is neither, and that's the point.
