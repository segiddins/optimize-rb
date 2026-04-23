# frozen_string_literal: true
require "set"
require "ruby_opt/pass"
require "ruby_opt/passes/literal_value"
require "ruby_opt/ir/cfg"
require "ruby_opt/ir/instruction"

module RubyOpt
  module Passes
    # Arithmetic reassociation within a basic block, driven by REASSOC_GROUPS.
    # See docs/superpowers/specs/2026-04-21-pass-arith-reassoc-v3-design.md.
    class ArithReassocPass < RubyOpt::Pass
      # Each entry describes one commutative-associative group of operators:
      #   ops:        opcode => Symbol method used to combine that op's RHS
      #               literal into the running accumulator. Insertion-ordered.
      #   identity:   neutral element for the group (0 for +, 1 for *).
      #   primary_op: opcode used to emit the single literal-carrying trailing
      #               op after a rewrite. Must be a key in `ops`.
      #   kind:       selects the rewrite algorithm. :abelian uses v3's
      #               partition-by-combiner + inject-reduce (valid when all
      #               ops in the group commute and associate, e.g. +/-).
      #               :ordered walks the chain left-to-right with a single
      #               literal accumulator, used when the group contains a
      #               non-commutative op like opt_div.
      #   associative:
      #               true:  same-op literal runs fold anywhere in the chain.
      #                      Sound when `(a op b) op c = a op (b op c)` — e.g.
      #                      `*` on Integer, and `/` on positive Integer (via
      #                      the `a/b/c = a/(b*c)` identity using the primary
      #                      op's combiner `:*`).
      #               false: same-op literal runs fold ONLY in the pure-literal
      #                      prefix, before any non-literal has been emitted.
      #                      Required for `%`: `(y%b)%c ≠ y%b` in general, so
      #                      `x % 7 % 3` must NOT fold, only `7 % 3 % x → 1%x`.
      #   commutative:
      #               true:  the walker can keep accumulating literals past a
      #                      same-op non-literal (`2*3*x*4 → x*24`). Sound for
      #                      `*` (commutative) and `/` on positive Integer
      #                      (`(a/b)/c = (a/c)/b`).
      #               false: commit the pending literal accumulator before
      #                      emitting any non-literal. Required for `%`, which
      #                      neither commutes nor satisfies a cross-non-literal
      #                      identity.
      REASSOC_GROUPS = [
        { ops: { opt_plus: :+, opt_minus: :- }, identity: 0, primary_op: :opt_plus, kind: :abelian },
        { ops: { opt_mult: :*, opt_div: :/    }, identity: 1, primary_op: :opt_mult, kind: :ordered,
          associative: true,  commutative: true },
        { ops: { opt_mod:  :% },                identity: nil, primary_op: :opt_mod,  kind: :ordered,
          associative: false, commutative: false },
      ].freeze

      # ObjectTable#intern accepts integers with bit_length < 62
      # (i.e. values in -(2^61)..(2^61)-1). Results outside this range
      # cannot be interned and must be skipped.
      INTERN_BIT_LENGTH_LIMIT = 62

      # Opcodes that each push exactly one value, pop zero, and have no
      # side effects relevant to reordering literals past them. Shared across
      # all REASSOC_GROUPS entries. Widening this list without re-examining the
      # "all entries are side-effect-free w.r.t. each other" invariant would
      # break the non-literal reordering rule used by the additive group.
      SINGLE_PUSH_OPERAND_OPCODES = (
        LiteralValue::LITERAL_OPCODES + %i[
          getlocal
          getlocal_WC_0
          getlocal_WC_1
          getinstancevariable
          getclassvariable
          getglobal
          putself
        ]
      ).freeze

      def name = :arith_reassoc

      def apply(function, type_env:, log:, object_table: nil, **_extras)
        _ = type_env
        return unless object_table
        insts = function.instructions
        return unless insts

        # Outer any-rewrite fixpoint: a rewrite in one group can expose chains
        # in another group (e.g. mult folding `2 * 3 → 6` exposes a + chain
        # that plus missed on its first visit). See spec "Two-level fixpoint".
        loop do
          any_outer = false
          REASSOC_GROUPS.each do |group|
            loop do
              break unless rewrite_once(insts, function, log, object_table, group: group)
              any_outer = true
            end
          end
          break unless any_outer
        end
      end

      private

      def rewrite_once(insts, function, log, object_table, group:)
        any = false
        leader_set = Set.new(IR::CFG.compute_leaders(insts))
        i = 0
        while i < insts.size
          if group[:ops].key?(insts[i].opcode)
            chain = detect_chain(insts, i, leader_set, group: group)
            if chain && try_rewrite_chain(insts, chain, function, log, object_table, group: group)
              any = true
              i = chain[:first_idx]
              leader_set = Set.new(IR::CFG.compute_leaders(insts))
            else
              i += 1
            end
          else
            i += 1
          end
        end
        any
      end

      def detect_chain(insts, end_idx, leader_set, group:)
        prod_indices = []
        op_positions = [{ idx: end_idx, opcode: insts[end_idx].opcode }]
        j = end_idx - 1
        return nil unless j >= 0 && single_push?(insts[j])
        prod_indices.unshift(j)

        loop do
          op_j = j - 1
          prod_j = j - 2
          break if op_j < 0 || prod_j < 0
          break unless group[:ops].key?(insts[op_j].opcode)
          break unless single_push?(insts[prod_j])
          op_positions.unshift({ idx: op_j, opcode: insts[op_j].opcode })
          prod_indices.unshift(prod_j)
          j = prod_j
        end

        first_candidate = prod_indices.first - 1
        return nil if first_candidate < 0
        return nil unless single_push?(insts[first_candidate])
        prod_indices.unshift(first_candidate)

        chain_start = prod_indices.first
        breaker = nil
        (chain_start + 1..end_idx).each do |k|
          if leader_set.include?(k)
            breaker = k
            break
          end
        end
        if breaker
          new_first = prod_indices.find { |p| p >= breaker }
          return nil unless new_first
          keep_from = prod_indices.index(new_first)
          prod_indices = prod_indices[keep_from..]
          op_positions = op_positions.last(prod_indices.size - 1) if prod_indices.size >= 1
        end

        return nil if prod_indices.size < 2
        {
          first_idx: prod_indices.first,
          producer_indices: prod_indices,
          op_positions: op_positions,
          end_idx: end_idx,
        }
      end

      def single_push?(inst)
        SINGLE_PUSH_OPERAND_OPCODES.include?(inst.opcode)
      end

      def try_rewrite_chain(insts, chain, function, log, object_table, group:)
        case group[:kind]
        when :abelian
          try_rewrite_chain_abelian(insts, chain, function, log, object_table, group: group)
        when :ordered
          try_rewrite_chain_ordered(insts, chain, function, log, object_table, group: group)
        else
          raise "unknown REASSOC_GROUPS kind: #{group[:kind].inspect}"
        end
      end

      def try_rewrite_chain_ordered(insts, chain, function, log, object_table, group:)
        producer_insts = chain[:producer_indices].map { |k| insts[k] }

        # Build the op-tagged stream. The leading producer has no preceding op
        # in source, so we tag it with the group's primary op.
        stream = producer_insts.each_with_index.map do |p, k|
          op =
            if k == 0
              group[:primary_op]
            else
              chain[:op_positions][k - 1][:opcode]
            end
          v = LiteralValue.read(p, object_table: object_table)
          { op: op, value: v, is_literal: LiteralValue.literal?(p), inst: p }
        end

        chain_line = insts[chain[:op_positions].first[:idx]].line || function.first_lineno

        # Pre-scan 1: unsafe divisor (0, negative, or non-Integer literal on a
        # / or %). Both opt_div and opt_mod raise ZeroDivisionError on 0; we
        # also reject negatives/non-Integer to keep the identity proofs simple.
        if stream.any? { |e| %i[opt_div opt_mod].include?(e[:op]) && e[:is_literal] && !(e[:value].is_a?(Integer) && e[:value] > 0) }
          log.skip(pass: :arith_reassoc, reason: :unsafe_divisor,
                   file: function.path, line: chain_line)
          return false
        end

        # Pre-scan 2: non-Integer literal anywhere else (e.g. Float/String on a *).
        if stream.any? { |e| e[:is_literal] && !e[:value].is_a?(Integer) }
          log.skip(pass: :arith_reassoc, reason: :mixed_literal_types,
                   file: function.path, line: chain_line)
          return false
        end

        # Pre-scan 3: coarse chain-too-short filter.
        if stream.count { |e| e[:is_literal] && e[:value].is_a?(Integer) } < 2
          log.skip(pass: :arith_reassoc, reason: :chain_too_short,
                   file: function.path, line: chain_line)
          return false
        end

        # Walk. Maintain an `emitted` list of entries with the same shape as
        # `stream`, and a pending literal accumulator (acc: Integer or nil).
        emitted = []
        acc = nil
        acc_op = nil

        commit = lambda do
          next if acc.nil?
          emitted << { op: acc_op, value: acc, inst: nil }
          acc = nil
          acc_op = nil
        end

        # The same-op literal run combiner is the primary op's method. For the
        # mult/div group this is `:*` (since `a/b/c = a/(b*c)`); for the mod
        # group it is `:%` (left-applied, and only in the literal prefix).
        run_combiner = group[:ops].fetch(group[:primary_op])
        associative = group.fetch(:associative, true)
        commutative = group.fetch(:commutative, true)

        stream.each do |e|
          if e[:is_literal]
            if acc.nil?
              acc = e[:value]
              acc_op = e[:op]
            elsif acc_op == e[:op] && (associative || emitted.empty?)
              # Same-op literal run: combine into the accumulator using the
              # group's run combiner. For non-associative groups this branch
              # is gated on `emitted.empty?` — once a non-literal has been
              # emitted, `(y op lit1) op lit2 ≠ y op (lit1 combiner lit2)`
              # and we must commit each literal on its own.
              acc = acc.send(run_combiner, e[:value])
            else
              # Cross-op boundary between literals, or post-non-literal run in
              # a non-associative group: commit and start fresh.
              commit.call
              acc = e[:value]
              acc_op = e[:op]
            end
          else
            # Non-literal. For commutative groups we can keep accumulating
            # past a same-op non-literal (so `2*3*x*4 → x*24`); we only need
            # to commit when the op differs. For non-commutative groups we
            # MUST commit any pending accumulator first — otherwise
            # `7 % 3 % x` would emit as `x % 1` (wrong).
            if !acc.nil? && (acc_op != e[:op] || !commutative)
              commit.call
            end
            emitted << e
          end
        end
        commit.call

        # Fits-intern check on every committed literal (inst: nil entries).
        if emitted.any? { |e| e[:inst].nil? && !fits_intern_range?(e[:value]) }
          log.skip(pass: :arith_reassoc, reason: :would_exceed_intern_range,
                   file: function.path, line: chain_line)
          return false
        end

        # No-change check: if we emitted the same number of literals as we
        # started with, nothing folded — preserve idempotence.
        input_literal_count  = stream.count  { |e| e[:is_literal] }
        output_literal_count = emitted.count { |e| e[:inst].nil? }
        if input_literal_count == output_literal_count
          log.skip(pass: :arith_reassoc, reason: :no_change,
                   file: function.path, line: chain_line)
          return false
        end

        first_op_inst = insts[chain[:op_positions].first[:idx]]

        # Emit. The leading entry's op is implicit (just the push). Every
        # subsequent entry emits `push; op`. Committed literals have inst: nil
        # and are reconstructed via LiteralValue.emit; non-literals carry the
        # original inst.
        replacement = []
        emitted.each_with_index do |e, idx|
          push_inst =
            if e[:inst].nil?
              LiteralValue.emit(e[:value], line: first_op_inst.line, object_table: object_table)
            else
              e[:inst]
            end
          replacement << push_inst

          next if idx == 0
          replacement << IR::Instruction.new(
            opcode: e[:op],
            operands: first_op_inst.operands,
            line: first_op_inst.line,
          )
        end

        range = chain[:first_idx]..chain[:end_idx]
        function.splice_instructions!(range, replacement)
        log.rewrite(pass: :arith_reassoc, reason: :reassociated,
                    file: function.path, line: chain_line)
        true
      end

      def try_rewrite_chain_abelian(insts, chain, function, log, object_table, group:)
        producer_insts = chain[:producer_indices].map { |k| insts[k] }

        # Combiner for each producer is the combiner of the op immediately to
        # its left in the chain. The leftmost producer uses the primary op's
        # combiner (equivalent to being preceded by an identity-friendly op).
        primary_combiner = group[:ops].fetch(group[:primary_op])
        producer_combiners = producer_insts.each_with_index.map do |_p, k|
          if k == 0
            primary_combiner
          else
            op_opcode = chain[:op_positions][k - 1][:opcode]
            group[:ops].fetch(op_opcode)
          end
        end

        classified = producer_insts.each_with_index.map do |p, k|
          v = LiteralValue.read(p, object_table: object_table)
          is_lit = LiteralValue.literal?(p)
          { inst: p, value: v, is_literal: is_lit, combiner: producer_combiners[k] }
        end

        integer_literals = classified.select { |c| c[:is_literal] && c[:value].is_a?(Integer) }
        non_integer_literals = classified.select { |c| c[:is_literal] && !c[:value].is_a?(Integer) }
        non_literals = classified.reject { |c| c[:is_literal] }

        chain_line = insts[chain[:op_positions].first[:idx]].line || function.first_lineno

        unless non_integer_literals.empty?
          log.skip(pass: :arith_reassoc, reason: :mixed_literal_types,
                   file: function.path, line: chain_line)
          return false
        end
        if integer_literals.size < 2
          log.skip(pass: :arith_reassoc, reason: :chain_too_short,
                   file: function.path, line: chain_line)
          return false
        end

        reduced = integer_literals.inject(group[:identity]) do |acc, c|
          acc.send(c[:combiner], c[:value])
        end
        unless fits_intern_range?(reduced)
          log.skip(pass: :arith_reassoc, reason: :would_exceed_intern_range,
                   file: function.path, line: chain_line)
          return false
        end

        has_pos_non_literal = non_literals.any? { |c| c[:combiner] == primary_combiner }
        if !non_literals.empty? && !has_pos_non_literal
          log.skip(pass: :arith_reassoc, reason: :no_positive_nonliteral,
                   file: function.path, line: chain_line)
          return false
        end

        first_op_inst = insts[chain[:op_positions].first[:idx]]
        literal_inst = LiteralValue.emit(reduced, line: first_op_inst.line, object_table: object_table)

        replacement = build_replacement(non_literals, literal_inst, first_op_inst, group)

        range = chain[:first_idx]..chain[:end_idx]
        function.splice_instructions!(range, replacement)
        log.rewrite(pass: :arith_reassoc, reason: :reassociated,
                    file: function.path, line: chain_line)
        true
      end

      # Emit the rewritten tail. For single-op groups (today: multiplicative),
      # this preserves non-literal order and fills intermediate ops with the
      # primary op. For multi-op groups (today: additive with opt_plus +
      # opt_minus), non-literals partition into pos/neg by combiner, emit as
      # pos ++ neg with intermediate ops driven by adjacent combiners, tail
      # literal via the primary op.
      def build_replacement(non_literals, literal_inst, first_op_inst, group)
        primary_combiner = group[:ops].fetch(group[:primary_op])

        pos = non_literals.select { |c| c[:combiner] == primary_combiner }
        neg = non_literals.reject { |c| c[:combiner] == primary_combiner }
        ordered = pos + neg

        replacement = []
        ordered.each_with_index do |c, idx|
          replacement << c[:inst]
          next if idx == 0
          # Intermediate op is driven by c's combiner: same as primary →
          # primary op; different → find the opcode in group[:ops] whose
          # combiner matches c's.
          intermediate_opcode = opcode_for_combiner(group, c[:combiner])
          replacement << IR::Instruction.new(
            opcode: intermediate_opcode,
            operands: first_op_inst.operands,
            line: first_op_inst.line,
          )
        end

        replacement << literal_inst
        if !ordered.empty?
          replacement << IR::Instruction.new(
            opcode: group[:primary_op],
            operands: first_op_inst.operands,
            line: first_op_inst.line,
          )
        end

        replacement
      end

      def opcode_for_combiner(group, combiner)
        group[:ops].each { |opcode, c| return opcode if c == combiner }
        raise "no opcode in group for combiner #{combiner.inspect}"
      end

      def fits_intern_range?(n)
        n.is_a?(Integer) && n.bit_length < INTERN_BIT_LENGTH_LIMIT
      end
    end
  end
end
