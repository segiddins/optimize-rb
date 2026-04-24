# point_distance demo

Pipeline.default: **1.00x** vs unoptimized.

Converged in 1 iterations (max across functions).

## Source

```ruby
# frozen_string_literal: true

class Point
  attr_reader :x, :y

  # @rbs (Integer, Integer) -> void
  def initialize(x, y)
    @x = x
    @y = y
  end

  # @rbs (Point) -> Integer
  def distance_to(other)
    (x - other.x) + (y - other.y)
  end
end
```

## Full-delta summary

`plain` = harness off; `optimized` = `Pipeline.default`.

```
Comparison:
  plain:   21957041.4 i/s
  optimized:   21907893.3 i/s - 1.00x  slower
```

## Walkthrough

### `inlining`

Replace `send` with the callee's body when the receiver is resolvable.

```diff
--- before inlining
+++ after  inlining
@@ -1,4 +1,4 @@
-[ 2] p@0        [ 1] q@1
+[ 4] p@0        [ 3] q@1        [ 2] other@2    [ 1] other@3
 putspecialobject                       3
 putnil
 defineclass                            :Point, <class:Point>, 0
@@ -28,9 +28,21 @@
 pop
 setlocal_WC_0                          q@1
 getlocal_WC_0                          p@0
-getlocal_WC_0                          q@1
-opt_send_without_block                 <calldata!mid:distance_to, argc:1, ARGS_SIMPLE>
-leave
+getlocal_WC_0                          q@1[Li]
+setlocal_WC_0                          other@3[Li]
+setlocal_WC_0                          other@2[Li]
+getlocal_WC_0                          other@2[Li]
+opt_send_without_block                 <calldata!mid:x, argc:0, FCALL|VCALL|ARGS_SIMPLE>[Li]
+getlocal_WC_0                          other@3[Li]
+opt_send_without_block                 <calldata!mid:x, argc:0, ARGS_SIMPLE>[Li]
+opt_minus                              <calldata!mid:-, argc:1, ARGS_SIMPLE>[Li]
+getlocal_WC_0                          other@2[Li]
+opt_send_without_block                 <calldata!mid:y, argc:0, FCALL|VCALL|ARGS_SIMPLE>[Li]
+getlocal_WC_0                          other@3[Li]
+opt_send_without_block                 <calldata!mid:y, argc:0, ARGS_SIMPLE>[Li]
+opt_minus                              <calldata!mid:-, argc:1, ARGS_SIMPLE>[Li]
+opt_plus                               <calldata!mid:+, argc:1, ARGS_SIMPLE>[Li]
+leave                                  [Li]
 == block: <class:Point
 putself
 putobject                              :x
```

### `const_fold`

Fold literal-operand operations (Tier 1).

```diff
(no change)
```

### `dead_branch_fold`

Collapse `<literal>; branch*` into `jump` (taken) or a drop (not taken).

```diff
(no change)
```

## Appendix: full iseq dumps

### Before (no optimization)

```
== disasm: #<ISeq:<compiled>@examples/point_distance.rb:3 (3,0)-(21,16)>
local table (size: 2, argc: 0 [opts: 0, rest: -1, post: 0, block: -1, kw: -1@-1, kwrest: -1])
[ 2] p@0        [ 1] q@1
0000 putspecialobject                       3                         (   3)[Li]
0002 putnil
0003 defineclass                            :Point, <class:Point>, 0
0007 pop
0008 opt_getconstant_path                   <ic:0 Point>              (  18)[Li]
0010 putnil
0011 swap
0012 putobject_INT2FIX_1_
0013 putobject                              2
0015 opt_new                                <calldata!mid:new, argc:2, ARGS_SIMPLE>, 22
0018 opt_send_without_block                 <calldata!mid:initialize, argc:2, FCALL|ARGS_SIMPLE>
0020 jump                                   25
0022 opt_send_without_block                 <calldata!mid:new, argc:2, ARGS_SIMPLE>
0024 swap
0025 pop
0026 setlocal_WC_0                          p@0
0028 opt_getconstant_path                   <ic:1 Point>              (  19)[Li]
0030 putnil
0031 swap
0032 putobject                              4
0034 putobject                              6
0036 opt_new                                <calldata!mid:new, argc:2, ARGS_SIMPLE>, 43
0039 opt_send_without_block                 <calldata!mid:initialize, argc:2, FCALL|ARGS_SIMPLE>
0041 jump                                   46
0043 opt_send_without_block                 <calldata!mid:new, argc:2, ARGS_SIMPLE>
0045 swap
0046 pop
0047 setlocal_WC_0                          q@1
0049 getlocal_WC_0                          p@0                       (  21)[Li]
0051 getlocal_WC_0                          q@1
0053 opt_send_without_block                 <calldata!mid:distance_to, argc:1, ARGS_SIMPLE>
0055 leave

== disasm: #<ISeq:<class:Point>@examples/point_distance.rb:3 (3,0)-(16,3)>
0000 putself                                                          (   4)[LiCl]
0001 putobject                              :x
0003 putobject                              :y
0005 opt_send_without_block                 <calldata!mid:attr_reader, argc:2, FCALL|ARGS_SIMPLE>
0007 pop
0008 definemethod                           :initialize, initialize   (   7)[Li]
0011 definemethod                           :distance_to, distance_to (  13)[Li]
0014 putobject                              :distance_to
0016 leave                                                            (  16)[En]

== disasm: #<ISeq:initialize@examples/point_distance.rb:7 (7,2)-(10,5)>
local table (size: 2, argc: 2 [opts: 0, rest: -1, post: 0, block: -1, kw: -1@-1, kwrest: -1])
[ 2] x@0<Arg>   [ 1] y@1<Arg>
0000 getlocal_WC_0                          x@0                       (   8)[LiCa]
0002 setinstancevariable                    :@x, <is:0>
0005 getlocal_WC_0                          y@1                       (   9)[Li]
0007 dup
0008 setinstancevariable                    :@y, <is:1>
0011 leave                                                            (  10)[Re]

== disasm: #<ISeq:distance_to@examples/point_distance.rb:13 (13,2)-(15,5)>
local table (size: 1, argc: 1 [opts: 0, rest: -1, post: 0, block: -1, kw: -1@-1, kwrest: -1])
[ 1] other@0<Arg>
0000 putself                                                          (  14)[LiCa]
0001 opt_send_without_block                 <calldata!mid:x, argc:0, FCALL|VCALL|ARGS_SIMPLE>
0003 getlocal_WC_0                          other@0
0005 opt_send_without_block                 <calldata!mid:x, argc:0, ARGS_SIMPLE>
0007 opt_minus                              <calldata!mid:-, argc:1, ARGS_SIMPLE>[CcCr]
0009 putself
0010 opt_send_without_block                 <calldata!mid:y, argc:0, FCALL|VCALL|ARGS_SIMPLE>
0012 getlocal_WC_0                          other@0
0014 opt_send_without_block                 <calldata!mid:y, argc:0, ARGS_SIMPLE>
0016 opt_minus                              <calldata!mid:-, argc:1, ARGS_SIMPLE>[CcCr]
0018 opt_plus                               <calldata!mid:+, argc:1, ARGS_SIMPLE>[CcCr]
0020 leave                                                            (  15)[Re]
```

### After full `Pipeline.default`

```
== disasm: #<ISeq:<compiled>@examples/point_distance.rb:3 (3,0)-(21,16)>
local table (size: 4, argc: 0 [opts: 0, rest: -1, post: 0, block: -1, kw: -1@-1, kwrest: -1])
[ 4] p@0        [ 3] q@1        [ 2] other@2    [ 1] other@3
0000 putspecialobject                       3                         (   3)[Li]
0002 putnil
0003 defineclass                            :Point, <class:Point>, 0
0007 pop
0008 opt_getconstant_path                   <ic:0 Point>              (  18)[Li]
0010 putnil
0011 swap
0012 putobject_INT2FIX_1_
0013 putobject                              2
0015 opt_new                                <calldata!mid:new, argc:2, ARGS_SIMPLE>, 22
0018 opt_send_without_block                 <calldata!mid:initialize, argc:2, FCALL|ARGS_SIMPLE>
0020 jump                                   25
0022 opt_send_without_block                 <calldata!mid:new, argc:2, ARGS_SIMPLE>
0024 swap
0025 pop
0026 setlocal_WC_0                          p@0
0028 opt_getconstant_path                   <ic:1 Point>              (  19)[Li]
0030 putnil
0031 swap
0032 putobject                              4
0034 putobject                              6
0036 opt_new                                <calldata!mid:new, argc:2, ARGS_SIMPLE>, 43
0039 opt_send_without_block                 <calldata!mid:initialize, argc:2, FCALL|ARGS_SIMPLE>
0041 jump                                   46
0043 opt_send_without_block                 <calldata!mid:new, argc:2, ARGS_SIMPLE>
0045 swap
0046 pop
0047 setlocal_WC_0                          q@1
0049 getlocal_WC_0                          p@0                       (  21)[Li]
0051 getlocal_WC_0                          q@1[Li]
0053 setlocal_WC_0                          other@3[Li]
0055 setlocal_WC_0                          other@2[Li]
0057 getlocal_WC_0                          other@2[Li]
0059 opt_send_without_block                 <calldata!mid:x, argc:0, FCALL|VCALL|ARGS_SIMPLE>[Li]
0061 getlocal_WC_0                          other@3[Li]
0063 opt_send_without_block                 <calldata!mid:x, argc:0, ARGS_SIMPLE>[Li]
0065 opt_minus                              <calldata!mid:-, argc:1, ARGS_SIMPLE>[Li]
0067 getlocal_WC_0                          other@2[Li]
0069 opt_send_without_block                 <calldata!mid:y, argc:0, FCALL|VCALL|ARGS_SIMPLE>[Li]
0071 getlocal_WC_0                          other@3[Li]
0073 opt_send_without_block                 <calldata!mid:y, argc:0, ARGS_SIMPLE>[Li]
0075 opt_minus                              <calldata!mid:-, argc:1, ARGS_SIMPLE>[Li]
0077 opt_plus                               <calldata!mid:+, argc:1, ARGS_SIMPLE>[Li]
0079 leave                                  [Li]

== disasm: #<ISeq:<class:Point>@examples/point_distance.rb:3 (3,0)-(16,3)>
0000 putself                                                          (   4)[LiCl]
0001 putobject                              :x
0003 putobject                              :y
0005 opt_send_without_block                 <calldata!mid:attr_reader, argc:2, FCALL|ARGS_SIMPLE>
0007 pop
0008 definemethod                           :initialize, initialize   (   7)[Li]
0011 definemethod                           :distance_to, distance_to (  13)[Li]
0014 putobject                              :distance_to
0016 leave                                                            (  16)[En]

== disasm: #<ISeq:initialize@examples/point_distance.rb:7 (7,2)-(10,5)>
local table (size: 2, argc: 2 [opts: 0, rest: -1, post: 0, block: -1, kw: -1@-1, kwrest: -1])
[ 2] x@0<Arg>   [ 1] y@1<Arg>
0000 getlocal_WC_0                          x@0                       (   8)[LiCa]
0002 setinstancevariable                    :@x, <is:0>
0005 getlocal_WC_0                          y@1                       (   9)[Li]
0007 dup
0008 setinstancevariable                    :@y, <is:1>
0011 leave                                                            (  10)[Re]

== disasm: #<ISeq:distance_to@examples/point_distance.rb:13 (13,2)-(15,5)>
local table (size: 1, argc: 1 [opts: 0, rest: -1, post: 0, block: -1, kw: -1@-1, kwrest: -1])
[ 1] other@0<Arg>
0000 putself                                                          (  14)[LiCa]
0001 opt_send_without_block                 <calldata!mid:x, argc:0, FCALL|VCALL|ARGS_SIMPLE>
0003 getlocal_WC_0                          other@0
0005 opt_send_without_block                 <calldata!mid:x, argc:0, ARGS_SIMPLE>
0007 opt_minus                              <calldata!mid:-, argc:1, ARGS_SIMPLE>[CcCr]
0009 putself
0010 opt_send_without_block                 <calldata!mid:y, argc:0, FCALL|VCALL|ARGS_SIMPLE>
0012 getlocal_WC_0                          other@0
0014 opt_send_without_block                 <calldata!mid:y, argc:0, ARGS_SIMPLE>
0016 opt_minus                              <calldata!mid:-, argc:1, ARGS_SIMPLE>[CcCr]
0018 opt_plus                               <calldata!mid:+, argc:1, ARGS_SIMPLE>[CcCr]
0020 leave                                                            (  15)[Re]
```

## Raw benchmark output

```
ruby 4.0.2 (2026-03-17 revision d3da9fec82) +PRISM [arm64-darwin23]
Warming up --------------------------------------
               plain     2.212M i/100ms
Calculating -------------------------------------
               plain     21.957M (± 1.8%) i/s   (45.54 ns/i) -    110.594M in   5.038564s
ruby 4.0.2 (2026-03-17 revision d3da9fec82) +PRISM [arm64-darwin23]
Warming up --------------------------------------
           optimized     2.206M i/100ms
Calculating -------------------------------------
           optimized     21.908M (± 1.5%) i/s   (45.65 ns/i) -    110.313M in   5.036397s
Comparison:
  plain:   21957041.4 i/s
  optimized:   21907893.3 i/s - 1.00x  slower
```
