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

Every optimizer operates under some contract with the program it's compiling. Ruby's own contract is almost nothing: the language has to assume that any method on any object could be redefined between now and the next call site, and that a constant you read a microsecond ago might point at a different object now. That's a real constraint, and it's visible in the bytecode. `1 + 2` doesn't compile to an integer add; it compiles to `opt_plus`, which checks at runtime whether `Integer#+` is still the original `Integer#+` before taking the fast path. Ruby already has a tiny contract — a handful of "basic operations haven't been redefined" flags — and every `opt_*` instruction is that contract made concrete.

My optimizer's contract is wider. It's five clauses:

- **No BOP redefinition.** `Integer#+`, `String#==`, `Array#[]`, `Hash#[]` — the basic operations mean what MRI shipped them meaning.
- **No `prepend` after load.** Method tables are stable once the program is loaded; nothing is going to slip a module into the ancestor chain between call sites.
- **RBS signatures are truthful.** Where an inline RBS annotation says a method returns an `Integer`, it returns an `Integer`.
- **`ENV` is read-only after load.** `ENV["X"]` resolves to the same thing forever.
- **No constant reassignment.** Top-level constants are assigned exactly once; no `const_set`, no reopening to reassign.

Stable method tables are what make inlining safe: if nothing can `prepend` into the ancestor chain, a call site bound at compile time stays bound at run time. Constants that don't get reassigned can be folded straight into the instruction stream instead of going through a constant-cache lookup on every iteration. A truthful RBS signature is the difference between "this call returns something" and "this call returns an Integer, so the next `+` can use the unchecked path." A read-only `ENV` lets `ENV["FEATURE_X"]` be read once at load time and folded away like a constant, while still letting the same source file be configured differently across environments.

These are reasonable assumptions for many programs. "Many" is the important word: plenty of real Ruby violates every one of them deliberately and correctly. Every APM gem in wide use — New Relic, Datadog, Skylight — instruments `ActiveRecord`, `Net::HTTP`, and friends by `prepend`ing a module that wraps the original method. That's the entire point; it's also a load-time violation of clause two. Any test suite using RSpec mocks is redefining methods between examples by design — `allow(user).to receive(:name).and_return("Sam")` swaps out a method table entry for the duration of the test, which is exactly what "method tables are stable" rules out. And every Rails developer running `bin/rails server` in development has the framework reloading classes on file changes so you can edit code without restarting the server. Reloading without restart is one of the best things about working in Rails, and it violates clause five every time the file watcher fires.

One more assumption sits underneath these — and it's about how the program gets *used*, not what it does. Nobody is watching through `TracePoint` or `Coverage`. Inlining a call erases the `:call` and `:return` events for the inlined callee; dead-instruction elimination erases the `:line` events for lines that got deleted. The violation isn't a property of the code, it's a property of the environment. That's exactly why the contract module can't express it.

Reasonable isn't good enough for the language itself. For Ruby, not breaking the language has to be the higher priority. A compiler that silently miscompiles `find_by_name_and_email` is worse than a slow one, and it isn't even close. That's why MRI's contract is so thin, and why `opt_plus` has to keep checking. Maybe one day there'll be a way to safely opt into this kind of optimization — a pragma, a sealed module, a `# frozen_methods: true` at the top of a file — and the VM can trust it the way I'm about to. Until then, a weekend project gets to make assumptions a language implementation can't.

## §3 — YARV, properly

Before I can talk about rewriting YARV, you have to be able to read it. If you've never stared at a `disasm` dump before, here's the decoder ring.

YARV is a stack machine. There is no register file, no `%rax` equivalent, no let-bindings. Every instruction does some combination of pop-values-off-the-stack, read-operands-from-the-instruction-stream, and push-results-back. The per-frame state that isn't on the stack — locals, block parameter, `self` — lives in a block of slots hanging off an environment pointer, which `getlocal` / `setlocal` reach into by index. That's most of the machine. Exception handling and a handful of inline caches are the rest, and both are safely ignorable.

The smallest useful example is probably `def add(a, b); a + b; end`:

```
== disasm: #<ISeq:add@(irb):1 (1,0)-(1,25)>
local table (size: 2, argc: 2 [opts: 0, rest: -1, ...])
[ 2] a@0<Arg>  [ 1] b@1<Arg>
0000 getlocal_WC_0          a@0
0002 getlocal_WC_0          b@1
0004 opt_plus               <calldata!mid:+, argc:1, ARGS_SIMPLE>
0006 leave
```

The `local table` header lists the frame's slots by name and index, and every `x@N` that shows up later in an operand column refers back to it. Three things in the body are worth noticing, and they recur in every listing from here on. First, `getlocal_WC_0` is `getlocal idx, 0` with the frame level operand baked in — the `_WC_N` suffix bakes the level in as `N`, and `_WC_0` (the current frame) is so overwhelmingly the common case that the interpreter gets its own specialized insn that skips decoding the level operand. You'll see `_WC_0` everywhere; `_WC_1` shows up when a nested scope reads a local from its parent. Its write-side partner is `setlocal_WC_0`, and the pair `setlocal_WC_0 x; getlocal_WC_0 x` — store and immediately reload — is exactly the shape the dead-stash pass sweeps away later. Second, `opt_plus` is not "integer add." It's a runtime-guarded call to `Integer#+` (or `Float#+`, or `String#+`) that takes a C fast path when the receiver is one of those core types *and* nobody has redefined `Integer#+` since the VM booted — otherwise it falls through to a generic `send`. The whole `opt_*` binop family works this way (`opt_minus`, `opt_mult`, `opt_div`, `opt_mod`, `opt_eq`, `opt_lt`, `opt_le`, `opt_gt`, `opt_ge`, `opt_ltlt`, and a few more), and that fallback is §2's contract, made concrete. Third, `leave` isn't `ret` — it's "pop TOS as the return value, handle pending interrupts, pop the frame." A small distinction, but it's the one that bites you the first time you try to splice two iseqs together and the result still runs `leave` in the middle.

Iseqs nest. Every `def`, every `do...end`, every `class Foo`, and the top-level script itself compile to their own child `rb_iseq_t`. `disasm` interleaves them with `== disasm:` separator lines, so one blob of output is really several iseqs stacked on top of each other — the reason you'll see the same address `0000` show up more than once in a listing.

A few more names that look like typos until you've seen them. `putobject_INT2FIX_0_` pushes the integer `0`; `putobject_INT2FIX_1_` pushes `1`. Both are `putobject` with the operand baked in — pushing `0` or `1` shows up so often (loop counters, `+ 1`, default arguments, boolean-ish returns) that saving a single operand read per push was worth giving them their own dispatch entries. `putobject 6` — no suffix — is the general form with `6` as an immediate.

`putself` pushes the current `self`, which is the implicit receiver for any unqualified method call. `opt_send_without_block` is a regular call site specialized for the (extremely common) case where no literal block is attached. `opt_getconstant_path` is the fused lookup for a full constant path like `SCALE` or `A::B::C`, with an inline cache hanging off it; when you see a diff quietly replace `opt_getconstant_path <ic:0 SCALE>` with `putobject 6`, that's constant folding — the cache lookup and its invalidation machinery both gone, because a contract-validated constant can't change. `swap` flips the top two stack values, `pop` discards TOS, and the `swap; pop` that appears right after an `opt_new` is cleaning up the extra stack slot `opt_new` leaves behind: the new instance and the class end up on the stack together, and `swap; pop` discards the class. The `branch*` family is exactly what it reads like: `branchunless dst` jumps to `dst` when TOS is falsy, `branchif` jumps when it's truthy, `branchnil` when it's `nil` — all PC-relative, all popping their one argument. The reason a `putobject true; branchunless 7` sequence can collapse into nothing is that the condition is knowable at rewrite time.

One last thing. Every line of `disasm` output carries a trailing bracketed tag or two — `[Li]`, `[Ca]`, `[Re]`, `[CcCr]`, combinations thereof. These are event and coverage markers the disassembler annotates for `TracePoint` / `Coverage` wiring; they don't change what the instruction does, and you can ignore them for reading the diffs.

That's roughly the grammar. There are about a hundred and ten instructions in total, and any real program calls in some long tail of them that I won't explain one by one. But the shortlist is short: `getlocal_WC_0`, `setlocal_WC_0`, `putobject` (and its `_INT2FIX_*` cousins), `putself`, the `opt_*` binops, `opt_send_without_block`, `opt_getconstant_path`, `swap`, `pop`, the `branch*` family, `jump`, and `leave`. If those make sense, the diffs will too, and the rest can be picked up by context.

## §4 — Building a toy optimizer

Ruby hands you two methods and looks the other way. `RubyVM::InstructionSequence#to_binary` serializes a compiled iseq to the YARV binary format — the undocumented-but-stable-ish blob MRI uses for on-disk iseq caches like bootsnap. `RubyVM::InstructionSequence.load_from_binary` takes those bytes and returns a live iseq the VM executes directly, no re-parse, no re-compile. Those two methods are the entire trick; everything else is what goes between them.

One caveat before the trick works. YARV's instruction set is not an ABI. Every minor Ruby release is free to add, rename, reshape, or retire instructions, and recent releases have done all four. The loader checks an internal version stamp on the way in and rejects anything that doesn't match exactly — no backward-compatibility window, no graceful degradation. That's by design; the format is a cache, not a promise. The binary `to_binary` emits on one Ruby is not loadable on another, and any tool that pattern-matches on opcodes — mine, ZJIT, YJIT's IR — is pinned the same way. The optimizer in this repo targets Ruby 4.0; porting it to a different minor version is its own project.

The shape is unsurprising. Decode the binary into an in-memory IR, run a pipeline of local rewrites over it, encode back to the same format, hand the modified bytes to `load_from_binary`. A naïve version could do all of this with a flat array of `[opcode, *operands]` tuples and some pattern matching. I did not want to do that — the interesting rewrites (inlining, constant folding across a branch) want a notion of basic blocks and a notion of where a value came from, and maintaining either one on a flat array once you have more than three passes is bookkeeping hell.

So the IR is a function per iseq, each function holding a CFG of basic blocks — blocks end at branches, jumps, and `leave` — with an ordered list of instructions per block and a slot-type table threaded through so a pass can ask "what do I know about `a@0` right here." Children live on their parent function — nested `def`s, blocks passed to methods, `class Foo` bodies — because that's how YARV stores them, and flattening the tree would just mean reconstructing it on the way back out.

The slot-type table is fed partly by literals and assignments visible in the instruction stream and partly by inline RBS comments — `# @rbs (Integer, Integer) -> Integer` on the line above a `def` — which a `TypeEnv` built at decode time parses out. The contract's "RBS signatures are truthful" clause is what lets the rewriter act on them: a call to `point.translate(dx, dy)` whose receiver the RBS types as `Point` binds statically to `Point#translate` at rewrite time, which is the hook the inliner actually uses to pick a callee.

Each pass is a class with an `apply` method that takes the function plus some context kwargs, walks a single function, recognizes a local pattern, and rewrites in place — logging every rewrite and every skipped opportunity so failure modes are visible instead of silent. Most iterate to a fixed point; only `InliningPass` is marked one-shot, since re-inlining an already-inlined site buys nothing. The default pipeline opens with `InliningPass` (splice the body of a visible `ARGS_SIMPLE`-shaped callee at the call site, stash arguments into local slots, drop the call), then `DeadStashElimPass` (delete the `setlocal_WC_0 x; getlocal_WC_0 x` pair when `x` isn't read afterwards), then `ArithReassocPass` (fold `(a + 1) + 2` shapes into `a + 3`). The rest is a fold-then-sweep cascade: three constant-folders run together — `ConstFoldTier2Pass` rewrites references to frozen top-level constants to their literal, `ConstFoldEnvPass` rewrites `ENV["FLAG"]` to a `putstring` from a snapshot taken at install time, and `ConstFoldPass` collapses any all-literal arithmetic into its result — then `IdentityElimPass` catches `x && x`, `0 + n`, and `n * 1`, and `DeadBranchFoldPass` finishes with `putobject true; branchunless L` to nothing and `putobject false; branchunless L` to `jump L`.

The passes feed each other: inlining exposes a stash round-trip for dead-stash, dead-stash exposes the producer to arith, arith exposes a constant-only expression to const-fold, const-fold exposes a literal condition to dead-branch-fold, dead-branch-fold exposes new unreachable blocks for the next sweep. None of the individual moves is novel; what matters is that each manufactures the precondition for the next. The pipeline caps at eight iterations; past that, a pass is either oscillating or reporting rewrites it didn't actually perform.

None of this runs unless you ask for it. `Optimize::Harness.install` defines `RubyVM::InstructionSequence.load_iseq(path)` — the same process-wide hook MRI calls from `rb_iseq_load_iseq` whenever it's about to load a file, and the same hook bootsnap has been using for years — and routes every subsequently-required file through the pipeline. Source files can opt out by putting `# rbs-optimize: false` in the first five lines. On any pipeline or codec failure the harness warns and returns `nil`, which tells MRI to fall back to the normal compile path. A slow method is acceptable; a miscompiled one is not.

```ruby
require "optimize"

Optimize::Harness.install         # hook load_iseq process-wide
fast = Optimize.optimize(src)     # one-shot: source -> new iseq
```

What any of this actually *does* to real code is a question you can only answer with a diff. Here are a few.

## §5 — Demos

Three fixtures, each with a committed walkthrough that shows the before-and-after iseq for every pass that fires. Polynomial is the payoff — where every pass in the pipeline fires and the cascade collapses an arithmetic chain to almost nothing. Point is the inlining case — where the number gets small and I have to explain why that's fine. `sum_of_squares` is where every pass shrugs `(no change)`, and that's the most useful demo of the three.

### Polynomial — the payoff

```ruby
SCALE = 6

class Polynomial
  # @rbs (Integer) -> Integer
  def compute(n)
    (n * 2 * SCALE / 12) + 0
  end

  # @rbs () -> Integer
  def run
    if SCALE == 6 then compute(42) else compute(0) end
  end
end
```

```
== disasm: #<ISeq:compute@polynomial.rb:7>
getlocal_WC_0        n@0
putobject            2
opt_mult             <calldata!mid:*, argc:1, ARGS_SIMPLE>
opt_getconstant_path <ic:0 SCALE>
opt_mult             <calldata!mid:*, argc:1, ARGS_SIMPLE>
putobject            12
opt_div              <calldata!mid:/, argc:1, ARGS_SIMPLE>
putobject_INT2FIX_0_
opt_plus             <calldata!mid:+, argc:1, ARGS_SIMPLE>
leave

== disasm: #<ISeq:run@polynomial.rb:12>
opt_getconstant_path <ic:0 SCALE>
putobject            6
opt_eq               <calldata!mid:==, argc:1, ARGS_SIMPLE>
branchunless         14
putself
putobject            42
opt_send_without_block <calldata!mid:compute, argc:1, FCALL|ARGS_SIMPLE>
leave
putself
putobject_INT2FIX_0_
opt_send_without_block <calldata!mid:compute, argc:1, FCALL|ARGS_SIMPLE>
leave
```

Ten instructions in `compute`, twelve in `run`, the usual bifurcated `if/else` in `run` where one arm leaves early and the other falls through. Nothing tricky. And now the pipeline runs.

**Pass 1 — `inlining`.** The inliner sees two `opt_send_without_block :compute` call sites in `run`, resolves both to the visible `Polynomial#compute`, and splices the body at each site:

```diff
--- before inlining
+++ after  inlining
 opt_getconstant_path <ic:0 SCALE>
 putobject            6
 opt_eq               <calldata!mid:==, argc:1, ARGS_SIMPLE>
-branchunless         14
-putself
+branchunless         30
 putobject            42
-opt_send_without_block <calldata!mid:compute, argc:1, FCALL|ARGS_SIMPLE>
+setlocal_WC_0        n@0
+getlocal_WC_0        n@0
+putobject            2
+opt_mult             <calldata!mid:*, argc:1, ARGS_SIMPLE>
+opt_getconstant_path <ic:1 SCALE>
+opt_mult             <calldata!mid:*, argc:1, ARGS_SIMPLE>
+putobject            12
+opt_div              <calldata!mid:/, argc:1, ARGS_SIMPLE>
+putobject_INT2FIX_0_
+opt_plus             <calldata!mid:+, argc:1, ARGS_SIMPLE>
 leave
```

Two things to notice. The new `setlocal_WC_0 n@0; getlocal_WC_0 n@0` pair at the top of the spliced body is the arg-stash — the inliner drops the argument `42` into the callee's local slot, then the very next instruction reads it back out. That's what "call with one argument" *is*, at the bytecode level, once you've erased the call. The `putself` that used to receive the `send` is gone; so is the `send` itself. The `branchunless` target shifts from `14` to `30` because the body between it and the now-inlined code got longer. Same thing happens at the second call site (the `compute(0)` arm); I've only shown one.

**Pass 2 — `dead_stash_elim`.** The stash pairs the inliner just created are dead the instant they land:

```diff
--- before dead_stash_elim
+++ after  dead_stash_elim
 putobject            42
-setlocal_WC_0        n@0
-getlocal_WC_0        n@0
 putobject            2
 opt_mult             <calldata!mid:*, argc:1, ARGS_SIMPLE>
```

This pass is ninety lines of code. It matches `setlocal X; getlocal X` where `X` has no other references, deletes both. That's the whole pass. It exists because the inliner creates exactly this shape, every time, and the pass that fires next needs the stream compacted before it can see the operand pairs it cares about.

**Pass 3 — `const_fold_tier2`.** The frozen-constant scanner sees `SCALE = 6` at the top of the file, confirms nothing reassigns it, and rewrites every `opt_getconstant_path <ic:N SCALE>` to `putobject 6`:

```diff
--- before const_fold_tier2
+++ after  const_fold_tier2
 putobject            42
 putobject            2
 opt_mult             <calldata!mid:*, argc:1, ARGS_SIMPLE>
-opt_getconstant_path <ic:1 SCALE>
+putobject            6
 opt_mult             <calldata!mid:*, argc:1, ARGS_SIMPLE>
 putobject            12
 opt_div              <calldata!mid:/, argc:1, ARGS_SIMPLE>
```

Both the `if SCALE == 6` condition at the top of `run` and the `SCALE` reference inside each inlined `compute` body get rewritten. The inline cache is gone; the path-lookup is gone; the instruction stream is now all-literal on both branches.

**Pass 4 — `const_fold`.** Tier 1 const-fold walks the stream looking for operations whose operands are all literals. It has several of those:

```diff
--- before const_fold
+++ after  const_fold
-putobject            6
-putobject            6
-opt_eq               <calldata!mid:==, argc:1, ARGS_SIMPLE>
-branchunless         26
-putobject            42
-putobject            2
-opt_mult             <calldata!mid:*, argc:1, ARGS_SIMPLE>
-putobject            6
-opt_mult             <calldata!mid:*, argc:1, ARGS_SIMPLE>
-putobject            12
-opt_div              <calldata!mid:/, argc:1, ARGS_SIMPLE>
-putobject_INT2FIX_0_
-opt_plus             <calldata!mid:+, argc:1, ARGS_SIMPLE>
-leave
-putobject_INT2FIX_0_
-putobject            2
-opt_mult             <calldata!mid:*, argc:1, ARGS_SIMPLE>
-putobject            6
-opt_mult             <calldata!mid:*, argc:1, ARGS_SIMPLE>
-putobject            12
-opt_div              <calldata!mid:/, argc:1, ARGS_SIMPLE>
-putobject_INT2FIX_0_
-opt_plus             <calldata!mid:+, argc:1, ARGS_SIMPLE>
-leave
+putobject            true
+branchunless         7
+putobject            42
+leave
+putobject_INT2FIX_0_
+leave
```

Twenty-four instructions on the minus side, six on the plus side. `6 == 6` folds to `true`. `42 * 2 * 6 / 12 + 0` folds to `42`. `0 * 2 * 6 / 12 + 0` folds to `0`. Every operation in those chains has two literals on its operand stack; each one collapses; the results cascade up. This is the single most visible pass in the pipeline, and it runs in a couple hundred lines.

**Pass 5 — `identity_elim`.** Reports `(no change)`. Identity-elim is looking for `x + 0`, `x * 1`, `x / 1` shapes where one operand is still non-literal; by this point const-fold has already eaten everything that had a literal operand, and the remaining runs of code have no identity shapes in them.

**Pass 6 — `dead_branch_fold`.** The `branchunless` from the const-fold output has a literal condition sitting immediately above it. That's exactly this pass's window:

```diff
--- before dead_branch_fold
+++ after  dead_branch_fold
-putobject            true
-branchunless         7
-putobject            42
-leave
-putobject_INT2FIX_0_
-leave
+putobject            42
+leave
+putobject_INT2FIX_0_
+leave
```

`putobject true; branchunless 7` collapses to nothing — the branch can't be taken — and the `putobject 42; leave` that was right after it is now the entire taken arm. The `putobject_INT2FIX_0_; leave` that used to be the `else` arm is now unreachable from anywhere, and persists in the byte stream only because the pipeline is still a peephole optimizer and doesn't excise basic blocks.

**End state.** `Pipeline#run` converges in `{TBD-polynomial-iters}` iterations. `compute` has gone from ten instructions to two:

```
getlocal_WC_0 n@0
leave
```

`run` has gone from twelve to four (two live, two unreachable):

```
putobject     42
leave
putobject_INT2FIX_0_   # unreachable
leave                  # unreachable
```

Benchmark: `{TBD-polynomial-ratio}`x vs. harness-off.

### Point — the honest number

```ruby
class Point
  attr_reader :x, :y

  # @rbs (Integer, Integer) -> void
  def initialize(x, y); @x = x; @y = y; end

  # @rbs (Point) -> Integer
  def distance_to(other)
    (x - other.x) + (y - other.y)
  end
end

p = Point.new(3, 5); q = Point.new(4, 6)
1_000_000.times { p.distance_to(q) }
```

The benchmark's inner loop is three instructions in starting form — `getlocal p@0; getlocal q@1; opt_send_without_block :distance_to`. The RBS annotation on `distance_to` types its receiver as `Point`, which lets the inliner statically resolve `p.distance_to(q)` and splice the body. Here's the diff:

```diff
--- before inlining
+++ after  inlining
 getlocal_WC_0        p@0
-getlocal_WC_0        q@1
-opt_send_without_block <calldata!mid:distance_to, argc:1, ARGS_SIMPLE>
-leave
+getlocal_WC_0        q@1
+setlocal_WC_0        other@3
+setlocal_WC_0        other@2
+getlocal_WC_0        other@2
+opt_send_without_block <calldata!mid:x, argc:0, FCALL|VCALL|ARGS_SIMPLE>
+getlocal_WC_0        other@3
+opt_send_without_block <calldata!mid:x, argc:0, ARGS_SIMPLE>
+opt_minus            <calldata!mid:-, argc:1, ARGS_SIMPLE>
+getlocal_WC_0        other@2
+opt_send_without_block <calldata!mid:y, argc:0, FCALL|VCALL|ARGS_SIMPLE>
+getlocal_WC_0        other@3
+opt_send_without_block <calldata!mid:y, argc:0, ARGS_SIMPLE>
+opt_minus            <calldata!mid:-, argc:1, ARGS_SIMPLE>
+opt_plus             <calldata!mid:+, argc:1, ARGS_SIMPLE>
+leave
```

The two `setlocal other@3; setlocal other@2` at the top are the self-stash and the arg-stash together (the inliner grew two new slots in the local table to hold the receiver and the argument from the erased call). Then the body of `distance_to`: four attr-reader sends, two subtractions, an addition.

After that, every subsequent pass reports `(no change)`. No constants fold because there aren't any. No branches fold because there aren't any. No identities apply because `- 0` and `+ 0` don't show up. The benchmark: `{TBD-point-distance-ratio}`x.

That is not a typo. Inlining shifted work from a call-and-return into the caller's instruction stream, but it didn't *delete* any of it — the six attr-reader sends still run, the two `opt_minus` still run, the `opt_plus` still runs. Plus the two stash-instructions the inliner just added. Inlining on its own rarely makes a microbenchmark faster; it makes the *next* pass possible. On this fixture no next pass applies, because there's no typed arithmetic folder yet and no `attr_reader`-through-`getinstancevariable` folder yet. The diff is visible, the benchmark isn't, and the right conclusion is that the inliner is waiting for its consumers to show up.

### `sum_of_squares` — the peephole ceiling

```ruby
# @rbs (Integer) -> Integer
def sum_of_squares(n)
  s = 0
  i = 1
  while i <= n
    s += i * i
    i += 1
  end
  s
end
```

I am going to show you the entire walkthrough:

```
### inlining           → (no change)
### const_fold_tier2   → (no change)
### const_fold         → (no change)
### identity_elim      → (no change)
### arith_reassoc      → (no change)
### dead_branch_fold   → (no change)
```

Benchmark: `{TBD-sum-of-squares-ratio}`x. Converged in one iteration, which is a nicer way of saying nothing fired.

This is the most useful demo of the three. The starting iseq is twenty-six instructions of loop preamble, header, body, increment, backedge, and `leave` — and none of it is literal-foldable, because everything interesting is loop-carried across the backedge. `s` starts at `0` but is immediately clobbered inside the body; `i` starts at `1` but is incremented every iteration; `i <= n` has an unknown RHS. And none of it is inlinable, because there's no `send` to inline.

The passes don't fire for a structural reason. Every pass in the pipeline is a peephole: a short window walking forward through a straight-line basic block. `while` is CFG-shaped — the interesting transformations are the backedge itself, the loop invariants, the relationship between the `<=` guard and the increment — and no peephole window can see a backedge without crossing it, which none of them do. Loop-invariant hoisting wants to lift work above the loop header. Zero-trip elimination wants to notice `while false`. Bounds-reasoning wants to notice that `i` only increases. All three want a CFG analysis the pipeline does not have.

This is the honest ceiling of a peephole optimizer. The roadmap has loop-aware passes on the "exploratory, not yet on any roadmap" list for a reason — the *first* loop-aware pass is strictly more infrastructure than everything I've built so far combined. §6 will come back to this.

### A note on numbers

All three fixtures run under `benchmark-ips` with the standard 2s warmup and 5s measurement, on a single machine, inside the ruby-bytecode MCP's Docker sandbox so nothing external can interfere mid-run. Ratios are harness-off vs. `Pipeline.default` on the same Ruby 4.0 binary — no JIT, no YJIT, no ZJIT. These fixtures were chosen to make the optimizer look good; the `sum_of_squares` number is the counterweight that keeps me honest about that. None of these is a production number and nothing about the methodology pretends otherwise.

## §6 — Tradeoffs (and when not to)

A violated contract clause is a miscompile.

Reassign `SCALE = 12` halfway through a run and `Polynomial#run` returns `42` forever — §5 folded the whole `42 * 2 * SCALE / 12 + 0` chain down to `putobject 42` at install time, so there is no `opt_getconstant_path`, no `opt_mult`, no `opt_div` left in the iseq for the reassignment to invalidate. A JIT would deoptimize on a guard failure; the stamped iseq has no guards to deoptimize from. The `42` is a literal now; it has forgotten where it came from. Late-`prepend` an override of `Integer#*` and the BOP flag does invalidate on cue — but the `opt_mult` that flag was guarding has been folded away, and with it any chance of the override running. Lie in an RBS signature — claim an `Integer` return that's sometimes `nil` — and an inlined `+` crashes on a receiver the optimizer proved couldn't exist. Every one of those is a bug in the program, not in the optimizer, but none of them existed before the optimizer ran.

Inlining erases the callee's frame from the backtrace — splice `point.translate(dx, dy)` into its caller and a `NoMethodError` inside the body surfaces in the caller's line range, on an instruction the caller didn't write. `TracePoint` stops seeing the inlined `:call` and `:return` events. `Coverage` stops marking the inlined lines. Dead-branch elimination drops the eliminated arm entirely, so `Coverage.result` reports its lines unexecuted and a coverage-gated CI pipeline fails the build for a branch the source still contains. Nothing here is a miscompile — the rewritten program is exactly what the contract said was legal — but every tool that reaches for the iseq sees a program the `.rb` file doesn't match.

The iseq binary format is pinned to one Ruby minor. A pass that matches on `opt_plus` and `setlocal_WC_0` is pinned to whatever 4.0 called those and whatever operands they took; 4.1 is free to rename, reshape, or retire any of them, and the loader rejects a stale binary immediately rather than running it wrong. YJIT and ZJIT pay this cost at boot, from source. A pipeline that stamps binaries pays it by hand, every minor.

The loop that got nothing in §5 is the ceiling. The first pass that would change the `sum_of_squares` number — loop-invariant hoisting, zero-trip elimination, any analysis that reasons across a backedge — needs a CFG and a notion of def-use strictly larger than everything else in the optimizer combined, which is why it stays on the roadmap and not in the pipeline.

"When not to" falls out of the list. If the program reloads code in development, not for you. If an APM is `prepend`ing into `ActiveRecord` so every query ends up in a flamegraph, not for you. If the coverage gate is load-bearing and an inlined test suite surprises it, not for you. If you're on Ruby `master` tracking the VM week by week, not for you. What's left is a non-trivial slice — a background worker pinned to a Ruby version, a long-running daemon, a CLI tool, a benchmark harness — and for most of that slice the honest recommendation is still YJIT, which has spent five years earning the guards I didn't write.

## §7 — Close

{TBD-§7}

---

*Source: [github.com/segiddins/ruby-the-hard-way-bytecode-talk]({TBD-repo-url})*
