# polynomial demo

Pipeline.default: **1.11x** vs unoptimized.

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
end
```

## Full-delta summary

`plain` = harness off; `optimized` = `Pipeline.default`.

```
Comparison:
  optimized:   23612977.0 i/s
  plain:   21343689.4 i/s - 1.11x  slower
```

## Walkthrough

### `inlining`

Replace `send` with the callee's body when the receiver is resolvable.

```diff
--- before inlining
+++ after  inlining
@@ -1,4 +1,4 @@
-[ 1] poly@0
+[ 3] poly@0     [ 2] n@1        [ 1] n@2
 putobject                              6
 putspecialobject                       3
 setconstant                            :SCALE
@@ -19,8 +19,7 @@
 opt_getconstant_path                   <ic:1 SCALE>
 putobject                              6
 opt_eq                                 <calldata!mid:==, argc:1, ARGS_SIMPLE>[CcCr]
-branchunless                           46
-getlocal_WC_0                          poly@0
+branchunless                           61
 putobject                              42
 opt_send_without_block                 <calldata!mid:compute, argc:1, ARGS_SIMPLE>
 leave
@@ -22,7 +21,16 @@
 branchunless                           46
 getlocal_WC_0                          poly@0
 putobject                              42
-opt_send_without_block                 <calldata!mid:compute, argc:1, ARGS_SIMPLE>
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
 getlocal_WC_0                          poly@0
 putobject_INT2FIX_0_
@@ -24,7 +32,6 @@
 putobject                              42
 opt_send_without_block                 <calldata!mid:compute, argc:1, ARGS_SIMPLE>
 leave
-getlocal_WC_0                          poly@0
 putobject_INT2FIX_0_
 opt_send_without_block                 <calldata!mid:compute, argc:1, ARGS_SIMPLE>
 leave
@@ -26,7 +33,16 @@
 leave
 getlocal_WC_0                          poly@0
 putobject_INT2FIX_0_
-opt_send_without_block                 <calldata!mid:compute, argc:1, ARGS_SIMPLE>
+setlocal_WC_0                          n@2
+getlocal_WC_0                          n@1
+putobject                              2
+opt_mult                               <calldata!mid:*, argc:1, ARGS_SIMPLE>
+opt_getconstant_path                   <ic:3 SCALE>
+opt_mult                               <calldata!mid:*, argc:1, ARGS_SIMPLE>
+putobject                              12
+opt_div                                <calldata!mid:/, argc:1, ARGS_SIMPLE>
+putobject_INT2FIX_0_
+opt_plus                               <calldata!mid:+, argc:1, ARGS_SIMPLE>
 leave
 == block: <class:Polynomial
 definemethod                           :compute, compute
@@ -34,7 +50,7 @@
 leave
 == block: compute@/w/examples/polynomial.rb:7 (7,2)-(9,5)
 [ 1] n@0<Arg>
-getlocal_WC_0                          n@0
+getlocal_WC_0                          "!"@-1
 putobject                              2
 opt_mult                               <calldata!mid:*, argc:1, ARGS_SIMPLE>[CcCr]
 opt_getconstant_path                   <ic:0 SCALE>
```

### `const_fold_tier2`

Rewrite frozen top-level constant references to their literal values.

```diff
--- before const_fold_tier2
+++ after  const_fold_tier2
@@ -16,7 +16,6 @@
 swap
 pop
 setlocal_WC_0                          poly@0
-opt_getconstant_path                   <ic:1 SCALE>
 putobject                              6
 opt_eq                                 <calldata!mid:==, argc:1, ARGS_SIMPLE>[CcCr]
 branchunless                           61
@@ -18,6 +17,7 @@
 setlocal_WC_0                          poly@0
 opt_getconstant_path                   <ic:1 SCALE>
 putobject                              6
+putobject                              6
 opt_eq                                 <calldata!mid:==, argc:1, ARGS_SIMPLE>[CcCr]
 branchunless                           61
 putobject                              42
@@ -25,7 +25,7 @@
 getlocal_WC_0                          n@1
 putobject                              2
 opt_mult                               <calldata!mid:*, argc:1, ARGS_SIMPLE>
-opt_getconstant_path                   <ic:2 SCALE>
+putobject                              6
 opt_mult                               <calldata!mid:*, argc:1, ARGS_SIMPLE>
 putobject                              12
 opt_div                                <calldata!mid:/, argc:1, ARGS_SIMPLE>
@@ -37,7 +37,7 @@
 getlocal_WC_0                          n@1
 putobject                              2
 opt_mult                               <calldata!mid:*, argc:1, ARGS_SIMPLE>
-opt_getconstant_path                   <ic:3 SCALE>
+putobject                              6
 opt_mult                               <calldata!mid:*, argc:1, ARGS_SIMPLE>
 putobject                              12
 opt_div                                <calldata!mid:/, argc:1, ARGS_SIMPLE>
@@ -53,7 +53,7 @@
 getlocal_WC_0                          "!"@-1
 putobject                              2
 opt_mult                               <calldata!mid:*, argc:1, ARGS_SIMPLE>[CcCr]
-opt_getconstant_path                   <ic:0 SCALE>
+putobject                              6
 opt_mult                               <calldata!mid:*, argc:1, ARGS_SIMPLE>[CcCr]
 putobject                              12
 opt_div                                <calldata!mid:/, argc:1, ARGS_SIMPLE>[CcCr]
```

### `const_fold`

Fold literal-operand operations (Tier 1).

```diff
--- before const_fold
+++ after  const_fold
@@ -16,34 +16,32 @@
 swap
 pop
 setlocal_WC_0                          poly@0
-putobject                              6
-putobject                              6
-opt_eq                                 <calldata!mid:==, argc:1, ARGS_SIMPLE>[CcCr]
-branchunless                           61
-putobject                              42
-setlocal_WC_0                          n@1
-getlocal_WC_0                          n@1
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
-setlocal_WC_0                          n@2
-getlocal_WC_0                          n@1
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
+branchunless                           57[Li]
+putobject                              42[Li]
+setlocal_WC_0                          n@1[Li]
+getlocal_WC_0                          n@1[Li]
+putobject                              2[Li]
+opt_mult                               <calldata!mid:*, argc:1, ARGS_SIMPLE>[Li]
+putobject                              6[Li]
+opt_mult                               <calldata!mid:*, argc:1, ARGS_SIMPLE>[Li]
+putobject                              12[Li]
+opt_div                                <calldata!mid:/, argc:1, ARGS_SIMPLE>[Li]
+putobject_INT2FIX_0_                   [Li]
+opt_plus                               <calldata!mid:+, argc:1, ARGS_SIMPLE>[Li]
+leave                                  [Li]
+putobject_INT2FIX_0_                   [Li]
+setlocal_WC_0                          n@2[Li]
+getlocal_WC_0                          n@1[Li]
+putobject                              2[Li]
+opt_mult                               <calldata!mid:*, argc:1, ARGS_SIMPLE>[Li]
+putobject                              6[Li]
+opt_mult                               <calldata!mid:*, argc:1, ARGS_SIMPLE>[Li]
+putobject                              12[Li]
+opt_div                                <calldata!mid:/, argc:1, ARGS_SIMPLE>[Li]
+putobject_INT2FIX_0_                   [Li]
+opt_plus                               <calldata!mid:+, argc:1, ARGS_SIMPLE>[Li]
+leave                                  [Li]
 == block: <class:Polynomial
 definemethod                           :compute, compute
 putobject                              :compute
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
@@ -16,32 +16,30 @@
 swap
 pop
 setlocal_WC_0                          poly@0
-putobject                              true
-branchunless                           57[Li]
-putobject                              42[Li]
-setlocal_WC_0                          n@1[Li]
-getlocal_WC_0                          n@1[Li]
-putobject                              2[Li]
-opt_mult                               <calldata!mid:*, argc:1, ARGS_SIMPLE>[Li]
-putobject                              6[Li]
-opt_mult                               <calldata!mid:*, argc:1, ARGS_SIMPLE>[Li]
-putobject                              12[Li]
-opt_div                                <calldata!mid:/, argc:1, ARGS_SIMPLE>[Li]
-putobject_INT2FIX_0_                   [Li]
-opt_plus                               <calldata!mid:+, argc:1, ARGS_SIMPLE>[Li]
-leave                                  [Li]
-putobject_INT2FIX_0_                   [Li]
-setlocal_WC_0                          n@2[Li]
-getlocal_WC_0                          n@1[Li]
-putobject                              2[Li]
-opt_mult                               <calldata!mid:*, argc:1, ARGS_SIMPLE>[Li]
-putobject                              6[Li]
-opt_mult                               <calldata!mid:*, argc:1, ARGS_SIMPLE>[Li]
-putobject                              12[Li]
-opt_div                                <calldata!mid:/, argc:1, ARGS_SIMPLE>[Li]
-putobject_INT2FIX_0_                   [Li]
-opt_plus                               <calldata!mid:+, argc:1, ARGS_SIMPLE>[Li]
-leave                                  [Li]
+putobject                              42                        (  13)
+setlocal_WC_0                          n@1
+getlocal_WC_0                          n@1
+putobject                              2
+opt_mult                               <calldata!mid:*, argc:1, ARGS_SIMPLE>
+putobject                              6
+opt_mult                               <calldata!mid:*, argc:1, ARGS_SIMPLE>
+putobject                              12
+opt_div                                <calldata!mid:/, argc:1, ARGS_SIMPLE>
+putobject_INT2FIX_0_
+opt_plus                               <calldata!mid:+, argc:1, ARGS_SIMPLE>
+leave
+putobject_INT2FIX_0_
+setlocal_WC_0                          n@2
+getlocal_WC_0                          n@1
+putobject                              2
+opt_mult                               <calldata!mid:*, argc:1, ARGS_SIMPLE>
+putobject                              6
+opt_mult                               <calldata!mid:*, argc:1, ARGS_SIMPLE>
+putobject                              12
+opt_div                                <calldata!mid:/, argc:1, ARGS_SIMPLE>
+putobject_INT2FIX_0_
+opt_plus                               <calldata!mid:+, argc:1, ARGS_SIMPLE>
+leave
 == block: <class:Polynomial
 definemethod                           :compute, compute
 putobject                              :compute
```

## Appendix: full iseq dumps

### Before (no optimization)

```
== disasm: #<ISeq:<compiled>@/w/examples/polynomial.rb:3 (3,0)-(13,60)>
local table (size: 1, argc: 0 [opts: 0, rest: -1, post: 0, block: -1, kw: -1@-1, kwrest: -1])
[ 1] poly@0
0000 putobject                              6                         (   3)[Li]
0002 putspecialobject                       3
0004 setconstant                            :SCALE
0006 putspecialobject                       3                         (   5)[Li]
0008 putnil
0009 defineclass                            :Polynomial, <class:Polynomial>, 0
0013 pop
0014 opt_getconstant_path                   <ic:0 Polynomial>         (  12)[Li]
0016 putnil
0017 swap
0018 opt_new                                <calldata!mid:new, argc:0, ARGS_SIMPLE>, 25
0021 opt_send_without_block                 <calldata!mid:initialize, argc:0, FCALL|ARGS_SIMPLE>
0023 jump                                   28
0025 opt_send_without_block                 <calldata!mid:new, argc:0, ARGS_SIMPLE>
0027 swap
0028 pop
0029 setlocal_WC_0                          poly@0
0031 opt_getconstant_path                   <ic:1 SCALE>              (  13)[Li]
0033 putobject                              6
0035 opt_eq                                 <calldata!mid:==, argc:1, ARGS_SIMPLE>[CcCr]
0037 branchunless                           46
0039 getlocal_WC_0                          poly@0
0041 putobject                              42
0043 opt_send_without_block                 <calldata!mid:compute, argc:1, ARGS_SIMPLE>
0045 leave
0046 getlocal_WC_0                          poly@0
0048 putobject_INT2FIX_0_
0049 opt_send_without_block                 <calldata!mid:compute, argc:1, ARGS_SIMPLE>
0051 leave

== disasm: #<ISeq:<class:Polynomial>@/w/examples/polynomial.rb:5 (5,0)-(10,3)>
0000 definemethod                           :compute, compute         (   7)[LiCl]
0003 putobject                              :compute
0005 leave                                                            (  10)[En]

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
```

### After full `Pipeline.default`

```
== disasm: #<ISeq:<compiled>@/w/examples/polynomial.rb:3 (3,0)-(13,60)>
local table (size: 3, argc: 0 [opts: 0, rest: -1, post: 0, block: -1, kw: -1@-1, kwrest: -1])
[ 3] poly@0     [ 2] n@1        [ 1] n@2
0000 putobject                              6                         (   3)[Li]
0002 putspecialobject                       3
0004 setconstant                            :SCALE
0006 putspecialobject                       3                         (   5)[Li]
0008 putnil
0009 defineclass                            :Polynomial, <class:Polynomial>, 0
0013 pop
0014 opt_getconstant_path                   <ic:0 Polynomial>         (  12)[Li]
0016 putnil
0017 swap
0018 opt_new                                <calldata!mid:new, argc:0, ARGS_SIMPLE>, 25
0021 opt_send_without_block                 <calldata!mid:initialize, argc:0, FCALL|ARGS_SIMPLE>
0023 jump                                   28
0025 opt_send_without_block                 <calldata!mid:new, argc:0, ARGS_SIMPLE>
0027 swap
0028 pop
0029 setlocal_WC_0                          poly@0
0031 putobject                              42                        (  13)
0033 setlocal_WC_0                          n@1
0035 getlocal_WC_0                          n@1
0037 putobject                              12
0039 opt_mult                               <calldata!mid:*, argc:1, ARGS_SIMPLE>
0041 putobject                              12
0043 opt_div                                <calldata!mid:/, argc:1, ARGS_SIMPLE>
0045 putobject_INT2FIX_0_
0046 opt_plus                               <calldata!mid:+, argc:1, ARGS_SIMPLE>
0048 leave
0049 putobject_INT2FIX_0_
0050 setlocal_WC_0                          n@2
0052 getlocal_WC_0                          n@1
0054 putobject                              12
0056 opt_mult                               <calldata!mid:*, argc:1, ARGS_SIMPLE>
0058 putobject                              12
0060 opt_div                                <calldata!mid:/, argc:1, ARGS_SIMPLE>
0062 putobject_INT2FIX_0_
0063 opt_plus                               <calldata!mid:+, argc:1, ARGS_SIMPLE>
0065 leave

== disasm: #<ISeq:<class:Polynomial>@/w/examples/polynomial.rb:5 (5,0)-(10,3)>
0000 definemethod                           :compute, compute         (   7)[LiCl]
0003 putobject                              :compute
0005 leave                                                            (  10)[En]

== disasm: #<ISeq:compute@/w/examples/polynomial.rb:7 (7,2)-(9,5)>
local table (size: 1, argc: 1 [opts: 0, rest: -1, post: 0, block: -1, kw: -1@-1, kwrest: -1])
[ 1] n@0<Arg>
0000 getlocal_WC_0                          "!"@-1                    (   8)[LiCa]
0002 putobject                              12[LiCa]
0004 opt_mult                               <calldata!mid:*, argc:1, ARGS_SIMPLE>[LiCa]
0006 putobject                              12[LiCa]
0008 opt_div                                <calldata!mid:/, argc:1, ARGS_SIMPLE>[LiCa]
0010 putobject_INT2FIX_0_                   [LiCa]
0011 opt_plus                               <calldata!mid:+, argc:1, ARGS_SIMPLE>[LiCa]
0013 leave                                  [LiCa]
```

## Raw benchmark output

```
ruby 4.0.2 (2026-03-17 revision d3da9fec82) +PRISM [aarch64-linux]
Warming up --------------------------------------
               plain     2.158M i/100ms
Calculating -------------------------------------
               plain     21.344M (± 2.9%) i/s   (46.85 ns/i) -    107.911M in   5.060835s
ruby 4.0.2 (2026-03-17 revision d3da9fec82) +PRISM [aarch64-linux]
Warming up --------------------------------------
           optimized     2.364M i/100ms
Calculating -------------------------------------
           optimized     23.613M (± 1.9%) i/s   (42.35 ns/i) -    118.213M in   5.008081s
Comparison:
  optimized:   23612977.0 i/s
  plain:   21343689.4 i/s - 1.11x  slower
```
