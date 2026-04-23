# polynomial demo

Pipeline.default: **2.16x** vs unoptimized.

Converged in 3 iterations (max across functions).

## Source

```ruby
# frozen_string_literal: true

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

## Full-delta summary

`plain` = harness off; `optimized` = `Pipeline.default`.

```
Comparison:
  optimized:   35727594.7 i/s
  plain:   16523702.6 i/s - 2.16x  slower
```

## Walkthrough

### `inlining`

Replace `send` with the callee's body when the receiver is resolvable.

```diff
--- before inlining
+++ after  inlining
@@ -37,6 +37,7 @@
 opt_plus                               <calldata!mid:+, argc:1, ARGS_SIMPLE>[CcCr]
 leave
 == block: run@/w/examples/polynomial.rb:12 (12,2)-(14,5)
+[ 2] n@0        [ 1] n@1
 opt_getconstant_path                   <ic:0 SCALE>
 putobject                              6
 opt_eq                                 <calldata!mid:==, argc:1, ARGS_SIMPLE>[CcCr]
@@ -40,8 +41,7 @@
 opt_getconstant_path                   <ic:0 SCALE>
 putobject                              6
 opt_eq                                 <calldata!mid:==, argc:1, ARGS_SIMPLE>[CcCr]
-branchunless                           14
-putself
+branchunless                           30
 putobject                              42
 opt_send_without_block                 <calldata!mid:compute, argc:1, FCALL|ARGS_SIMPLE>
 leave
@@ -43,7 +43,16 @@
 branchunless                           14
 putself
 putobject                              42
-opt_send_without_block                 <calldata!mid:compute, argc:1, FCALL|ARGS_SIMPLE>
+setlocal_WC_0                          n@0
+getlocal_WC_0                          n@0
+putobject                              2
+opt_mult                               <calldata!mid:*, argc:1, ARGS_SIMPLE>
+opt_getconstant_path                   <ic:1 SCALE>
+opt_mult                               <calldata!mid:*, argc:1, ARGS_SIMPLE>
+putobject                              12
+opt_div                                <calldata!mid:/, argc:1, ARGS_SIMPLE>
+putobject_INT2FIX_0_
+opt_plus                               <calldata!mid:+, argc:1, ARGS_SIMPLE>
 leave
 putself                                                          (  13)
 putobject_INT2FIX_0_
@@ -45,7 +54,6 @@
 putobject                              42
 opt_send_without_block                 <calldata!mid:compute, argc:1, FCALL|ARGS_SIMPLE>
 leave
-putself                                                          (  13)
 putobject_INT2FIX_0_
 opt_send_without_block                 <calldata!mid:compute, argc:1, FCALL|ARGS_SIMPLE>
 leave
@@ -47,6 +55,15 @@
 leave
 putself                                                          (  13)
 putobject_INT2FIX_0_
-opt_send_without_block                 <calldata!mid:compute, argc:1, FCALL|ARGS_SIMPLE>
+setlocal_WC_0                          n@1
+getlocal_WC_0                          n@1
+putobject                              2
+opt_mult                               <calldata!mid:*, argc:1, ARGS_SIMPLE>
+opt_getconstant_path                   <ic:2 SCALE>
+opt_mult                               <calldata!mid:*, argc:1, ARGS_SIMPLE>
+putobject                              12
+opt_div                                <calldata!mid:/, argc:1, ARGS_SIMPLE>
+putobject_INT2FIX_0_
+opt_plus                               <calldata!mid:+, argc:1, ARGS_SIMPLE>
 leave
 
```

### `dead_stash_elim`

Drop `setlocal X; getlocal X` pairs whose slot has no other refs.

```diff
--- before dead_stash_elim
+++ after  dead_stash_elim
@@ -15,9 +15,7 @@
 opt_send_without_block                 <calldata!mid:new, argc:0, ARGS_SIMPLE>
 swap
 pop
-setlocal_WC_0                          poly@0
-getlocal_WC_0                          poly@0
-opt_send_without_block                 <calldata!mid:run, argc:0, ARGS_SIMPLE>
+opt_send_without_block                 <calldata!mid:run, argc:0, ARGS_SIMPLE>(  18)
 leave
 == block: <class:Polynomial
 definemethod                           :compute, compute
@@ -41,7 +39,7 @@
 opt_getconstant_path                   <ic:0 SCALE>
 putobject                              6
 opt_eq                                 <calldata!mid:==, argc:1, ARGS_SIMPLE>[CcCr]
-branchunless                           30
+branchunless                           26
 putobject                              42
 setlocal_WC_0                          n@0
 getlocal_WC_0                          n@0
@@ -43,8 +41,6 @@
 opt_eq                                 <calldata!mid:==, argc:1, ARGS_SIMPLE>[CcCr]
 branchunless                           30
 putobject                              42
-setlocal_WC_0                          n@0
-getlocal_WC_0                          n@0
 putobject                              2
 opt_mult                               <calldata!mid:*, argc:1, ARGS_SIMPLE>
 opt_getconstant_path                   <ic:1 SCALE>
@@ -55,8 +51,6 @@
 opt_plus                               <calldata!mid:+, argc:1, ARGS_SIMPLE>
 leave
 putobject_INT2FIX_0_
-setlocal_WC_0                          n@1
-getlocal_WC_0                          n@1
 putobject                              2
 opt_mult                               <calldata!mid:*, argc:1, ARGS_SIMPLE>
 opt_getconstant_path                   <ic:2 SCALE>
```

### `const_fold_tier2`

Rewrite frozen top-level constant references to their literal values.

```diff
--- before const_fold_tier2
+++ after  const_fold_tier2
@@ -27,7 +27,7 @@
 getlocal_WC_0                          n@0
 putobject                              2
 opt_mult                               <calldata!mid:*, argc:1, ARGS_SIMPLE>[CcCr]
-opt_getconstant_path                   <ic:0 SCALE>
+putobject                              6
 opt_mult                               <calldata!mid:*, argc:1, ARGS_SIMPLE>[CcCr]
 putobject                              12
 opt_div                                <calldata!mid:/, argc:1, ARGS_SIMPLE>[CcCr]
@@ -36,7 +36,6 @@
 leave
 == block: run@/w/examples/polynomial.rb:12 (12,2)-(14,5)
 [ 2] n@0        [ 1] n@1
-opt_getconstant_path                   <ic:0 SCALE>
 putobject                              6
 opt_eq                                 <calldata!mid:==, argc:1, ARGS_SIMPLE>[CcCr]
 branchunless                           26
@@ -38,6 +37,7 @@
 [ 2] n@0        [ 1] n@1
 opt_getconstant_path                   <ic:0 SCALE>
 putobject                              6
+putobject                              6
 opt_eq                                 <calldata!mid:==, argc:1, ARGS_SIMPLE>[CcCr]
 branchunless                           26
 putobject                              42
@@ -43,7 +43,7 @@
 putobject                              42
 putobject                              2
 opt_mult                               <calldata!mid:*, argc:1, ARGS_SIMPLE>
-opt_getconstant_path                   <ic:1 SCALE>
+putobject                              6
 opt_mult                               <calldata!mid:*, argc:1, ARGS_SIMPLE>
 putobject                              12
 opt_div                                <calldata!mid:/, argc:1, ARGS_SIMPLE>
@@ -53,7 +53,7 @@
 putobject_INT2FIX_0_
 putobject                              2
 opt_mult                               <calldata!mid:*, argc:1, ARGS_SIMPLE>
-opt_getconstant_path                   <ic:2 SCALE>
+putobject                              6
 opt_mult                               <calldata!mid:*, argc:1, ARGS_SIMPLE>
 putobject                              12
 opt_div                                <calldata!mid:/, argc:1, ARGS_SIMPLE>
```

### `const_fold`

Fold literal-operand operations (Tier 1).

```diff
--- before const_fold
+++ after  const_fold
@@ -36,28 +36,10 @@
 leave
 == block: run@/w/examples/polynomial.rb:12 (12,2)-(14,5)
 [ 2] n@0        [ 1] n@1
-putobject                              6
-putobject                              6
-opt_eq                                 <calldata!mid:==, argc:1, ARGS_SIMPLE>[CcCr]
-branchunless                           26
-putobject                              42
-putobject                              2
-opt_mult                               <calldata!mid:*, argc:1, ARGS_SIMPLE>
-putobject                              6
-opt_mult                               <calldata!mid:*, argc:1, ARGS_SIMPLE>
-putobject                              12
-opt_div                                <calldata!mid:/, argc:1, ARGS_SIMPLE>
-putobject_INT2FIX_0_
-opt_plus                               <calldata!mid:+, argc:1, ARGS_SIMPLE>
-leave
-putobject_INT2FIX_0_
-putobject                              2
-opt_mult                               <calldata!mid:*, argc:1, ARGS_SIMPLE>
-putobject                              6
-opt_mult                               <calldata!mid:*, argc:1, ARGS_SIMPLE>
-putobject                              12
-opt_div                                <calldata!mid:/, argc:1, ARGS_SIMPLE>
-putobject_INT2FIX_0_
-opt_plus                               <calldata!mid:+, argc:1, ARGS_SIMPLE>
-leave
+putobject                              true
+branchunless                           7[LiCa]
+putobject                              42[LiCa]
+leave                                  [LiCa]
+putobject_INT2FIX_0_                   [LiCa]
+leave                                  [LiCa]
 
```

### `identity_elim`

Remove identity operations: `x + 0`, `x * 1`, `x - 0`, `x / 1`.

```diff
(no change)
```

### `dead_branch_fold`

Collapse `<literal>; branch*` into `jump` (taken) or a drop (not taken).

```diff
--- before dead_branch_fold
+++ after  dead_branch_fold
@@ -36,10 +36,8 @@
 leave
 == block: run@/w/examples/polynomial.rb:12 (12,2)-(14,5)
 [ 2] n@0        [ 1] n@1
-putobject                              true
-branchunless                           7[LiCa]
-putobject                              42[LiCa]
-leave                                  [LiCa]
-putobject_INT2FIX_0_                   [LiCa]
-leave                                  [LiCa]
+putobject                              42                        (  13)
+leave
+putobject_INT2FIX_0_
+leave
 
```

## Appendix: full iseq dumps

### Before (no optimization)

```
== disasm: #<ISeq:<compiled>@/w/examples/polynomial.rb:3 (3,0)-(18,8)>
local table (size: 1, argc: 0 [opts: 0, rest: -1, post: 0, block: -1, kw: -1@-1, kwrest: -1])
[ 1] poly@0
0000 putobject                              6                         (   3)[Li]
0002 putspecialobject                       3
0004 setconstant                            :SCALE
0006 putspecialobject                       3                         (   5)[Li]
0008 putnil
0009 defineclass                            :Polynomial, <class:Polynomial>, 0
0013 pop
0014 opt_getconstant_path                   <ic:0 Polynomial>         (  17)[Li]
0016 putnil
0017 swap
0018 opt_new                                <calldata!mid:new, argc:0, ARGS_SIMPLE>, 25
0021 opt_send_without_block                 <calldata!mid:initialize, argc:0, FCALL|ARGS_SIMPLE>
0023 jump                                   28
0025 opt_send_without_block                 <calldata!mid:new, argc:0, ARGS_SIMPLE>
0027 swap
0028 pop
0029 setlocal_WC_0                          poly@0
0031 getlocal_WC_0                          poly@0                    (  18)[Li]
0033 opt_send_without_block                 <calldata!mid:run, argc:0, ARGS_SIMPLE>
0035 leave

== disasm: #<ISeq:<class:Polynomial>@/w/examples/polynomial.rb:5 (5,0)-(15,3)>
0000 definemethod                           :compute, compute         (   7)[LiCl]
0003 definemethod                           :run, run                 (  12)[Li]
0006 putobject                              :run
0008 leave                                                            (  15)[En]

== disasm: #<ISeq:compute@/w/examples/polynomial.rb:7 (7,2)-(9,5)>
local table (size: 1, argc: 1 [opts: 0, rest: -1, post: 0, block: -1, kw: -1@-1, kwrest: -1])
[ 1] n@0<Arg>
0000 getlocal_WC_0                          n@0                       (   8)[LiCa]
0002 putobject                              2
0004 opt_mult                               <calldata!mid:*, argc:1, ARGS_SIMPLE>[CcCr]
0006 opt_getconstant_path                   <ic:0 SCALE>
0008 opt_mult                               <calldata!mid:*, argc:1, ARGS_SIMPLE>[CcCr]
0010 putobject                              12
0012 opt_div                                <calldata!mid:/, argc:1, ARGS_SIMPLE>[CcCr]
0014 putobject_INT2FIX_0_
0015 opt_plus                               <calldata!mid:+, argc:1, ARGS_SIMPLE>[CcCr]
0017 leave                                                            (   9)[Re]

== disasm: #<ISeq:run@/w/examples/polynomial.rb:12 (12,2)-(14,5)>
0000 opt_getconstant_path                   <ic:0 SCALE>              (  13)[LiCa]
0002 putobject                              6
0004 opt_eq                                 <calldata!mid:==, argc:1, ARGS_SIMPLE>[CcCr]
0006 branchunless                           14
0008 putself
0009 putobject                              42
0011 opt_send_without_block                 <calldata!mid:compute, argc:1, FCALL|ARGS_SIMPLE>
0013 leave                                                            (  14)[Re]
0014 putself                                                          (  13)
0015 putobject_INT2FIX_0_
0016 opt_send_without_block                 <calldata!mid:compute, argc:1, FCALL|ARGS_SIMPLE>
0018 leave                                                            (  14)[Re]
```

### After full `Pipeline.default`

```
== disasm: #<ISeq:<compiled>@/w/examples/polynomial.rb:3 (3,0)-(18,8)>
local table (size: 1, argc: 0 [opts: 0, rest: -1, post: 0, block: -1, kw: -1@-1, kwrest: -1])
[ 1] poly@0
0000 putobject                              6                         (   3)[Li]
0002 putspecialobject                       3
0004 setconstant                            :SCALE
0006 putspecialobject                       3                         (   5)[Li]
0008 putnil
0009 defineclass                            :Polynomial, <class:Polynomial>, 0
0013 pop
0014 opt_getconstant_path                   <ic:0 Polynomial>         (  17)[Li]
0016 putnil
0017 swap
0018 opt_new                                <calldata!mid:new, argc:0, ARGS_SIMPLE>, 25
0021 opt_send_without_block                 <calldata!mid:initialize, argc:0, FCALL|ARGS_SIMPLE>
0023 jump                                   28
0025 opt_send_without_block                 <calldata!mid:new, argc:0, ARGS_SIMPLE>
0027 swap
0028 pop
0029 opt_send_without_block                 <calldata!mid:run, argc:0, ARGS_SIMPLE>(  18)
0031 leave

== disasm: #<ISeq:<class:Polynomial>@/w/examples/polynomial.rb:5 (5,0)-(15,3)>
0000 definemethod                           :compute, compute         (   7)[LiCl]
0003 definemethod                           :run, run                 (  12)[Li]
0006 putobject                              :run
0008 leave                                                            (  15)[En]

== disasm: #<ISeq:compute@/w/examples/polynomial.rb:7 (7,2)-(9,5)>
local table (size: 1, argc: 1 [opts: 0, rest: -1, post: 0, block: -1, kw: -1@-1, kwrest: -1])
[ 1] n@0<Arg>
0000 getlocal_WC_0                          n@0                       (   8)[LiCa]
0002 leave                                  [LiCa]

== disasm: #<ISeq:run@/w/examples/polynomial.rb:12 (12,2)-(14,5)>
local table (size: 2, argc: 0 [opts: 0, rest: -1, post: 0, block: -1, kw: -1@-1, kwrest: -1])
[ 2] n@0        [ 1] n@1
0000 putobject                              42                        (  13)
0002 leave
0003 putobject_INT2FIX_0_
0004 leave
```

## Raw benchmark output

```
ruby 4.0.2 (2026-03-17 revision d3da9fec82) +PRISM [aarch64-linux]
Warming up --------------------------------------
               plain     1.623M i/100ms
Calculating -------------------------------------
               plain     16.524M (± 2.1%) i/s   (60.52 ns/i) -     82.764M in   5.010996s
ruby 4.0.2 (2026-03-17 revision d3da9fec82) +PRISM [aarch64-linux]
Warming up --------------------------------------
           optimized     3.532M i/100ms
Calculating -------------------------------------
           optimized     35.728M (± 1.4%) i/s   (27.99 ns/i) -    180.143M in   5.043091s
Comparison:
  optimized:   35727594.7 i/s
  plain:   16523702.6 i/s - 2.16x  slower
```
