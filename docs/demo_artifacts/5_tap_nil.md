# 5_tap_nil demo

Pipeline.default: **0.96x** vs unoptimized.

Converged in 2 iterations (max across functions).

## Source

```ruby
def my_tap
  yield self
  self
end
public :my_tap

5.my_tap { nil }
```

## Full-delta summary

`plain` = harness off; `optimized` = `Pipeline.default`.

```
Comparison:
  plain:   26732262.7 i/s
  optimized:   25715284.6 i/s - 1.04x  slower
```

## Walkthrough

### `inlining`

Replace `send` with the callee's body when the receiver is resolvable.

```diff
--- before inlining
+++ after  inlining
@@ -1,3 +1,4 @@
+[ 4] my_tap@0   [ 3] my_tap@1   [ 2] my_tap@2   [ 1] my_tap@3
 definemethod                           :my_tap, my_tap
 putself
 putobject                              :my_tap
@@ -4,11 +5,21 @@
 opt_send_without_block                 <calldata!mid:public, argc:1, FCALL|ARGS_SIMPLE>
 pop
 putobject                              5
-send                                   <calldata!mid:my_tap, argc:0>, block in <compiled>
-pop
-putobject                              5
-send                                   <calldata!mid:my_tap, argc:0>, block in <compiled>
-leave
+setlocal_WC_0                          my_tap@0[Li]
+getlocal_WC_0                          my_tap@0[Li]
+setlocal_WC_0                          my_tap@1[Li]
+putnil                                 [Li]
+pop                                    [Li]
+getlocal_WC_0                          my_tap@0[Li]
+pop                                    [Li]
+putobject                              5[Li]
+setlocal_WC_0                          my_tap@2[Li]
+getlocal_WC_0                          my_tap@2[Li]
+setlocal_WC_0                          my_tap@3[Li]
+putnil                                 [Li]
+pop                                    [Li]
+getlocal_WC_0                          my_tap@2[Li]
+leave                                  [Li]
 == block: my_tap@examples/5_tap_nil.rb:1 (1,0)-(4,3)
 putself
 invokeblock                            <calldata!argc:1, ARGS_SIMPLE>
@@ -15,10 +26,4 @@
 pop
 putself
 leave
-== block: block in <compiled
-putnil
-leave                                  [Br]
-== block: block in <compiled
-putnil
-leave                                  [Br]
 
```

### `dead_stash_elim`

Drop `setlocal X; getlocal X` pairs whose slot has no other refs.

```diff
--- before dead_stash_elim
+++ after  dead_stash_elim
@@ -5,21 +5,7 @@
 opt_send_without_block                 <calldata!mid:public, argc:1, FCALL|ARGS_SIMPLE>
 pop
 putobject                              5
-setlocal_WC_0                          my_tap@0[Li]
-getlocal_WC_0                          my_tap@0[Li]
-setlocal_WC_0                          my_tap@1[Li]
-putnil                                 [Li]
-pop                                    [Li]
-getlocal_WC_0                          my_tap@0[Li]
-pop                                    [Li]
-putobject                              5[Li]
-setlocal_WC_0                          my_tap@2[Li]
-getlocal_WC_0                          my_tap@2[Li]
-setlocal_WC_0                          my_tap@3[Li]
-putnil                                 [Li]
-pop                                    [Li]
-getlocal_WC_0                          my_tap@2[Li]
-leave                                  [Li]
+leave                                                            (  10)
 == block: my_tap@examples/5_tap_nil.rb:1 (1,0)-(4,3)
 putself
 invokeblock                            <calldata!argc:1, ARGS_SIMPLE>
```

## Appendix: full iseq dumps

### Before (no optimization)

```
== disasm: #<ISeq:<compiled>@examples/5_tap_nil.rb:1 (1,0)-(10,16)>
0000 definemethod                           :my_tap, my_tap           (   1)[Li]
0003 putself                                                          (   5)[Li]
0004 putobject                              :my_tap
0006 opt_send_without_block                 <calldata!mid:public, argc:1, FCALL|ARGS_SIMPLE>
0008 pop
0009 putobject                              5                         (   7)[Li]
0011 send                                   <calldata!mid:my_tap, argc:0>, block in <compiled>
0014 pop
0015 putobject                              5                         (  10)[Li]
0017 send                                   <calldata!mid:my_tap, argc:0>, block in <compiled>
0020 leave

== disasm: #<ISeq:my_tap@examples/5_tap_nil.rb:1 (1,0)-(4,3)>
0000 putself                                                          (   2)[LiCa]
0001 invokeblock                            <calldata!argc:1, ARGS_SIMPLE>
0003 pop
0004 putself                                                          (   3)[Li]
0005 leave                                                            (   4)[Re]

== disasm: #<ISeq:block in <compiled>@examples/5_tap_nil.rb:7 (7,9)-(7,16)>
0000 putnil                                                           (   7)[LiBc]
0001 leave                                  [Br]

== disasm: #<ISeq:block in <compiled>@examples/5_tap_nil.rb:10 (10,9)-(10,16)>
0000 putnil                                                           (  10)[LiBc]
0001 leave                                  [Br]
```

### After full `Pipeline.default`

```
== disasm: #<ISeq:<compiled>@examples/5_tap_nil.rb:1 (1,0)-(10,16)>
local table (size: 4, argc: 0 [opts: 0, rest: -1, post: 0, block: -1, kw: -1@-1, kwrest: -1])
[ 4] my_tap@0   [ 3] my_tap@1   [ 2] my_tap@2   [ 1] my_tap@3
0000 definemethod                           :my_tap, my_tap           (   1)[Li]
0003 putself                                                          (   5)[Li]
0004 putobject                              :my_tap
0006 opt_send_without_block                 <calldata!mid:public, argc:1, FCALL|ARGS_SIMPLE>
0008 pop
0009 putobject                              5
0011 leave                                                            (  10)

== disasm: #<ISeq:my_tap@examples/5_tap_nil.rb:1 (1,0)-(4,3)>
0000 putself                                                          (   2)[LiCa]
0001 invokeblock                            <calldata!argc:1, ARGS_SIMPLE>
0003 pop
0004 putself                                                          (   3)[Li]
0005 leave                                                            (   4)[Re]
```

## Raw benchmark output

```
ruby 4.0.2 (2026-03-17 revision d3da9fec82) +PRISM [arm64-darwin23]
Warming up --------------------------------------
               plain     2.708M i/100ms
Calculating -------------------------------------
               plain     26.732M (± 2.1%) i/s   (37.41 ns/i) -    135.415M in   5.067799s
ruby 4.0.2 (2026-03-17 revision d3da9fec82) +PRISM [arm64-darwin23]
Warming up --------------------------------------
           optimized     2.684M i/100ms
Calculating -------------------------------------
           optimized     25.715M (± 3.8%) i/s   (38.89 ns/i) -    128.847M in   5.018128s
Comparison:
  plain:   26732262.7 i/s
  optimized:   25715284.6 i/s - 1.04x  slower
```
