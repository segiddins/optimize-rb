# sum_of_squares demo

Pipeline.default: **0.96x** vs unoptimized.

## Source

```ruby
# frozen_string_literal: true

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

## Full-delta summary

`plain` = harness off; `optimized` = `Pipeline.default`.

```
Comparison:
  plain:   437232.3 i/s
  optimized:   420803.8 i/s - 1.04x  slower
```

## Walkthrough

### `inlining`

Replace `send` with the callee's body when the receiver is resolvable.

```diff
(no change)
```

### `const_fold_tier2`

Rewrite frozen top-level constant references to their literal values.

```diff
(no change)
```

### `const_fold`

Fold literal-operand operations (Tier 1).

```diff
(no change)
```

### `identity_elim`

Remove identity operations: `x + 0`, `x * 1`, `x - 0`, `x / 1`.

```diff
(no change)
```

### `arith_reassoc`

Reassociate `+ - * /` chains of literal operands under the no-BOP-redef rule.

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
== disasm: #<ISeq:<compiled>@/w/examples/sum_of_squares.rb:4 (4,0)-(15,19)>
0000 definemethod                           :sum_of_squares, sum_of_squares(   4)[Li]
0003 putself                                                          (  15)[Li]
0004 putobject                              100
0006 opt_send_without_block                 <calldata!mid:sum_of_squares, argc:1, FCALL|ARGS_SIMPLE>
0008 leave

== disasm: #<ISeq:sum_of_squares@/w/examples/sum_of_squares.rb:4 (4,0)-(12,3)>
local table (size: 3, argc: 1 [opts: 0, rest: -1, post: 0, block: -1, kw: -1@-1, kwrest: -1])
[ 3] n@0<Arg>   [ 2] s@1        [ 1] i@2
0000 putobject_INT2FIX_0_                                             (   5)[LiCa]
0001 setlocal_WC_0                          s@1
0003 putobject_INT2FIX_1_                                             (   6)[Li]
0004 setlocal_WC_0                          i@2
0006 jump                                   31                        (   7)[Li]
0008 putnil
0009 pop
0010 jump                                   31
0012 getlocal_WC_0                          s@1                       (   8)[Li]
0014 getlocal_WC_0                          i@2
0016 getlocal_WC_0                          i@2
0018 opt_mult                               <calldata!mid:*, argc:1, ARGS_SIMPLE>[CcCr]
0020 opt_plus                               <calldata!mid:+, argc:1, ARGS_SIMPLE>[CcCr]
0022 setlocal_WC_0                          s@1
0024 getlocal_WC_0                          i@2                       (   9)[Li]
0026 putobject_INT2FIX_1_
0027 opt_plus                               <calldata!mid:+, argc:1, ARGS_SIMPLE>[CcCr]
0029 setlocal_WC_0                          i@2
0031 getlocal_WC_0                          i@2                       (   7)
0033 getlocal_WC_0                          n@0
0035 opt_le                                 <calldata!mid:<=, argc:1, ARGS_SIMPLE>[CcCr]
0037 branchif                               12
0039 putnil
0040 pop
0041 getlocal_WC_0                          s@1                       (  11)[Li]
0043 leave                                                            (  12)[Re]
```

### After full `Pipeline.default`

```
== disasm: #<ISeq:<compiled>@/w/examples/sum_of_squares.rb:4 (4,0)-(15,19)>
0000 definemethod                           :sum_of_squares, sum_of_squares(   4)[Li]
0003 putself                                                          (  15)[Li]
0004 putobject                              100
0006 opt_send_without_block                 <calldata!mid:sum_of_squares, argc:1, FCALL|ARGS_SIMPLE>
0008 leave

== disasm: #<ISeq:sum_of_squares@/w/examples/sum_of_squares.rb:4 (4,0)-(12,3)>
local table (size: 3, argc: 1 [opts: 0, rest: -1, post: 0, block: -1, kw: -1@-1, kwrest: -1])
[ 3] n@0<Arg>   [ 2] s@1        [ 1] i@2
0000 putobject_INT2FIX_0_                                             (   5)[LiCa]
0001 setlocal_WC_0                          s@1
0003 putobject_INT2FIX_1_                                             (   6)[Li]
0004 setlocal_WC_0                          i@2
0006 jump                                   31                        (   7)[Li]
0008 putnil
0009 pop
0010 jump                                   31
0012 getlocal_WC_0                          s@1                       (   8)[Li]
0014 getlocal_WC_0                          i@2
0016 getlocal_WC_0                          i@2
0018 opt_mult                               <calldata!mid:*, argc:1, ARGS_SIMPLE>[CcCr]
0020 opt_plus                               <calldata!mid:+, argc:1, ARGS_SIMPLE>[CcCr]
0022 setlocal_WC_0                          s@1
0024 getlocal_WC_0                          i@2                       (   9)[Li]
0026 putobject_INT2FIX_1_
0027 opt_plus                               <calldata!mid:+, argc:1, ARGS_SIMPLE>[CcCr]
0029 setlocal_WC_0                          i@2
0031 getlocal_WC_0                          i@2                       (   7)
0033 getlocal_WC_0                          n@0
0035 opt_le                                 <calldata!mid:<=, argc:1, ARGS_SIMPLE>[CcCr]
0037 branchif                               12
0039 putnil
0040 pop
0041 getlocal_WC_0                          s@1                       (  11)[Li]
0043 leave                                                            (  12)[Re]
```

## Raw benchmark output

```
ruby 4.0.2 (2026-03-17 revision d3da9fec82) +PRISM [aarch64-linux]
Warming up --------------------------------------
               plain    43.000k i/100ms
Calculating -------------------------------------
               plain    437.232k (± 3.9%) i/s    (2.29 μs/i) -      2.193M in   5.023423s
ruby 4.0.2 (2026-03-17 revision d3da9fec82) +PRISM [aarch64-linux]
Warming up --------------------------------------
           optimized    43.972k i/100ms
Calculating -------------------------------------
           optimized    420.804k (± 2.7%) i/s    (2.38 μs/i) -      2.111M in   5.019394s
Comparison:
  plain:   437232.3 i/s
  optimized:   420803.8 i/s - 1.04x  slower
```
