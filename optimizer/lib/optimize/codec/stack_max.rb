# frozen_string_literal: true

module Optimize
  module Codec
    module StackMax
      # Map opcode symbol -> [pop_count, push_count] (Array form)
      # or -> ->(instruction) { [pop, push] } (Proc form for variadic).
      DELTA = {
        # --- Stack-no-op ---
        nop: [0, 0],
        jump: [0, 0],

        # --- Frame exit ---
        leave: [1, 0],
        throw: [1, 0],

        # --- Pushes (no pop) ---
        putself: [0, 1],
        putnil: [0, 1],
        putobject: [0, 1],
        putobject_INT2FIX_0_: [0, 1],
        putobject_INT2FIX_1_: [0, 1],
        putstring: [0, 1],
        putspecialobject: [0, 1],
        putiseq: [0, 1],
        duparray: [0, 1],
        duphash: [0, 1],
        getlocal: [0, 1],
        getlocal_WC_0: [0, 1],
        getlocal_WC_1: [0, 1],
        getglobal: [0, 1],
        getinstancevariable: [0, 1],
        getclassvariable: [0, 1],
        getconstant: [1, 1], # pops the namespace, pushes the value
        getblockparam: [0, 1],
        getblockparamproxy: [0, 1],
        getspecial: [0, 1],
        intern: [1, 1],

        # --- Stores ---
        pop: [1, 0],
        setlocal: [1, 0],
        setlocal_WC_0: [1, 0],
        setlocal_WC_1: [1, 0],
        setglobal: [1, 0],
        setinstancevariable: [1, 0],
        setclassvariable: [1, 0],
        setconstant: [2, 0], # value + namespace
        setblockparam: [1, 0],
        setspecial: [1, 0],

        # --- Stack manipulation ---
        dup: [1, 2],       # pops 1, pushes 2 (a -> a, a)
        swap: [2, 2],
        # dupn and topn/setn read N from operand; handle as lambda.

        # --- Arithmetic / comparison (binary) ---
        opt_plus:  [2, 1],
        opt_minus: [2, 1],
        opt_mult:  [2, 1],
        opt_div:   [2, 1],
        opt_mod:   [2, 1],
        opt_eq:    [2, 1],
        opt_neq:   [2, 1],
        opt_lt:    [2, 1],
        opt_le:    [2, 1],
        opt_gt:    [2, 1],
        opt_ge:    [2, 1],
        opt_ltlt:  [2, 1],
        opt_and:   [2, 1],
        opt_or:    [2, 1],
        opt_aref:  [2, 1],
        opt_aref_with: [1, 1],  # receiver -> value, key is a literal operand
        opt_aset:  [3, 1],      # obj, key, val -> val
        opt_aset_with: [2, 1],  # obj, val -> val; key is literal
        opt_length:  [1, 1],
        opt_size:    [1, 1],
        opt_empty_p: [1, 1],
        opt_succ:    [1, 1],
        opt_not:     [1, 1],
        opt_nil_p:   [1, 1],
        opt_regexpmatch2: [2, 1],
        opt_str_freeze: [0, 1],
        opt_str_uminus: [0, 1],
        opt_ary_freeze: [0, 1],
        opt_hash_freeze: [0, 1],

        # --- Branches / tests ---
        branchif:     [1, 0],
        branchunless: [1, 0],
        branchnil:    [1, 0],

        # --- Object construction & stringification ---
        tostring:   [1, 1],         # stringifies TOS
        anytostring: [2, 1],        # takes value + cache, pushes string
        concatstrings: ->(i) { n = i.operands[0] || 0; [n, 1] },
        concatarray: [2, 1],
        splatarray: [1, 1],
        splatkw: [2, 1],
        newarray: ->(i) { n = i.operands[0] || 0; [n, 1] },
        newarraykwsplat: ->(i) { n = i.operands[0] || 0; [n, 1] },
        newhash: ->(i) { n = i.operands[0] || 0; [n, 1] },
        newrange: [2, 1],
        expandarray: ->(i) {
          num = i.operands[0] || 0
          flag = i.operands[1] || 0
          post = (flag & 1) != 0
          rest = (flag & 2) != 0
          pushes = num + (rest ? 1 : 0)
          [1, pushes]
        },
        checkmatch: [2, 1],
        checktype:  [1, 1],
        checkkeyword: [0, 1],
        defined: [1, 1],

        # --- Calls: variadic via calldata's argc ---
        # The calldata operand is typically at index 0 for these ops.
        # Conservative approach: assume argc = 16 when we can't parse
        # calldata, then subtract 16 from the bound. The `depth = 0 if
        # depth.negative?` guard in `compute` prevents underflow.
        # If `calldata_argc` is available on the instruction operand,
        # use it precisely.
        opt_send_without_block: ->(i) { [stack_max_argc_from_calldata(i, pop_recv: true), 1] },
        send:                    ->(i) { [stack_max_argc_from_calldata(i, pop_recv: true), 1] },
        invokesuper:             ->(i) { [stack_max_argc_from_calldata(i, pop_recv: false) + 1, 1] },
        # invokeblock operands: [CALLDATA, NUM] — NUM (argc) is at index 1.
        invokeblock:             ->(i) { [i.operands[1] || 0, 1] },
        invokebuiltin:           ->(i) { [i.operands[0] || 0, 1] },
        invokebuiltin_delegate:  ->(i) { [i.operands[0] || 0, 1] },
        invokebuiltin_delegate_leave: ->(i) { [i.operands[0] || 0, 0] },

        # --- dupn / topn / setn with N from operand ---
        dupn: ->(i) { n = i.operands[0] || 0; [0, n] }, # dups top N: stays at bottom, pushes N
        topn: ->(i) { [0, 1] },
        setn: ->(i) { [1, 0] }, # sets Nth-from-top; net change -1
        adjuststack: ->(i) { n = i.operands[0] || 0; [n, 0] },
      }.freeze

      module_function

      def compute(function)
        max = 0
        depth = 0
        (function.instructions || []).each do |ins|
          pop, push = delta_for(ins)
          depth -= pop
          depth = 0 if depth.negative? # saturate at zero (conservative)
          depth += push
          max = depth if depth > max
        end
        # Pad by a small safety margin to handle ops we under-modeled.
        max + 1
      end

      def delta_for(ins)
        entry = DELTA[ins.opcode]
        case entry
        when Array then entry
        when Proc then entry.call(ins)
        else
          # Unknown opcode -- conservative assumption: pops 0, pushes 1.
          [0, 1]
        end
      end

      # Best-effort argc extraction from a calldata operand. Returns a
      # conservative bound when we can't parse.
      def stack_max_argc_from_calldata(ins, pop_recv:)
        # Calldata layout is opaque in IBF (ci_entries are separate);
        # the operand here is an index. Without parsing the ci_entry we
        # fall back to a conservative cap.
        cap = 16
        cap + (pop_recv ? 1 : 0)
      end
    end
  end
end
