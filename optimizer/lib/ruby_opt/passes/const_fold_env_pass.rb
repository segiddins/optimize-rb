# frozen_string_literal: true
require "set"
require "ruby_opt/pass"
require "ruby_opt/passes/literal_value"
require "ruby_opt/ir/instruction"
require "ruby_opt/ir/call_data"

module RubyOpt
  module Passes
    # Tier 4 const-fold: ENV["LIT"] -> its snapshot value (or nil).
    #
    # Runs per-function like every other pass, but soundness is tree-wide:
    # if *any* function in the IR tree has a tainted ENV use (a write, a
    # `fetch`, any send other than the safe `opt_aref` consumer), every
    # fold site in the tree is skipped and one :env_write_observed log
    # entry is emitted. The "anywhere in tree" flag is memoized on the
    # root function's `misc` via `@root ||= function` — a fresh pass
    # instance per `Pipeline.default.run` call keeps the scoping per-run.
    #
    # Task 3 adds the scanner; Task 4 adds the fold loop.
    #
    # Operand shape (confirmed via decode diagnostics on Ruby 4.0.2):
    #   opt_getconstant_path operands=[N]  where N is an object-table index.
    #   object_table.objects[N] is an Array of object-table indices whose
    #   resolved elements are the constant-path symbols, e.g. [:ENV].
    class ConstFoldEnvPass < RubyOpt::Pass
      TAINT_FLAG_KEY = :const_fold_env_tree_tainted

      # Read-only ENV methods that cannot mutate ENV. A send on ENV with
      # one of these mids does NOT taint the tree. v1: argc 0 and 1 only.
      # Expanding this set is safe iff the method is guaranteed non-mutating.
      SAFE_ENV_READ_METHODS = %i[
        fetch to_h to_hash key? has_key? include? member?
        values_at assoc size length empty? keys values
        inspect to_s hash ==
      ].to_set.freeze

      # Default-producer opcodes that are safe to drop when folding
      # `ENV.fetch(LIT, default)` on a key hit: each is a single-instruction
      # side-effect-free producer. Extending this set requires the producer
      # to be observably pure (no autoload, no side effects, no raises).
      PURE_DEFAULT_OPCODES = %i[
        putnil putobject putstring putchilledstring putself
      ].to_set.freeze

      def name = :const_fold_env

      def apply(function, type_env:, log:, object_table: nil, env_snapshot: nil, **_extras)
        _ = type_env
        return unless object_table
        return unless env_snapshot

        root = tree_root(function)
        root.misc ||= {}
        unless root.misc.key?(:const_fold_env_tree_scanned)
          root.misc[:const_fold_env_tree_scanned] = true
          scan_tree_for_taint(root, object_table, log)
        end

        insts = function.instructions
        return unless insts
        return if root.misc[TAINT_FLAG_KEY]

        # Fold phase. Match the 3-tuple:
        #   opt_getconstant_path <ENV>; putchilledstring/putstring KEY; opt_aref
        # Splice to a single putobject <idx> or putnil, where idx comes from
        # object_table.index_for(snapshot_value). If the snapshot value isn't
        # already interned, skip that fold site (intern can't append strings).
        i = 0
        while i <= insts.size - 3
          a  = insts[i]
          b  = insts[i + 1]
          op = insts[i + 2]

          unless env_producer?(a, object_table) && literal_string?(b, object_table)
            i += 1
            next
          end

          d   = insts[i + 2]
          op4 = insts[i + 3]
          if d && op4 && op4.opcode == :opt_send_without_block &&
             fetch_send_argc2?(op4, object_table) && pure_default?(d)
            key = LiteralValue.read(b, object_table: object_table)
            if env_snapshot.key?(key)
              value = env_snapshot[key]
              if value.is_a?(String)
                idx = object_table.intern(value)
                replacement = IR::Instruction.new(opcode: :putobject, operands: [idx], line: a.line)
                function.splice_instructions!(i..(i + 3), [replacement])
                log.rewrite(pass: :const_fold_env, reason: :folded,
                            file: function.path, line: (a.line || function.first_lineno || 0))
              else
                log.skip(pass: :const_fold_env, reason: :env_value_not_string,
                         file: function.path, line: (a.line || function.first_lineno || 0))
              end
            else
              # Key absent: return the default. Keep `d` as the sole instruction.
              function.splice_instructions!(i..(i + 3), [d])
              log.rewrite(pass: :const_fold_env, reason: :folded,
                          file: function.path, line: (a.line || function.first_lineno || 0))
            end
            i += 1
            next
          end

          if op.opcode == :opt_aref
            key = LiteralValue.read(b, object_table: object_table)
            value = env_snapshot[key]

            replacement =
              if value.nil?
                IR::Instruction.new(opcode: :putnil, operands: [], line: a.line)
              elsif value.is_a?(String)
                idx = object_table.intern(value)
                IR::Instruction.new(opcode: :putobject, operands: [idx], line: a.line)
              else
                log.skip(pass: :const_fold_env, reason: :env_value_not_string,
                         file: function.path, line: (a.line || function.first_lineno || 0))
                nil
              end

            if replacement
              function.splice_instructions!(i..(i + 2), [replacement])
              log.rewrite(pass: :const_fold_env, reason: :folded,
                          file: function.path, line: (a.line || function.first_lineno || 0))
            end
            i += 1
          elsif op.opcode == :opt_send_without_block && fetch_send?(op, object_table)
            key = LiteralValue.read(b, object_table: object_table)
            if env_snapshot.key?(key)
              value = env_snapshot[key]
              if value.is_a?(String)
                idx = object_table.intern(value)
                replacement = IR::Instruction.new(opcode: :putobject, operands: [idx], line: a.line)
                function.splice_instructions!(i..(i + 2), [replacement])
                log.rewrite(pass: :const_fold_env, reason: :folded,
                            file: function.path, line: (a.line || function.first_lineno || 0))
              else
                log.skip(pass: :const_fold_env, reason: :env_value_not_string,
                         file: function.path, line: (a.line || function.first_lineno || 0))
              end
            else
              log.skip(pass: :const_fold_env, reason: :fetch_key_absent,
                       file: function.path, line: (a.line || function.first_lineno || 0))
            end
            i += 1
          else
            i += 1
          end
        end
      end

      private

      # Whole-tree taint scan. Called once per pipeline run on the root
      # function before any folds happen. Walks every function in the
      # tree, and if any carries a tainted ENV use, records a single
      # :env_write_observed log entry and sets the tree's taint flag.
      def scan_tree_for_taint(fn, object_table, log)
        insts = fn.instructions
        if insts
          tainted_here, first_taint_line = classify(insts, object_table)
          if tainted_here
            root = tree_root(fn)
            unless root.misc[TAINT_FLAG_KEY]
              root.misc[TAINT_FLAG_KEY] = true
              log.skip(pass: :const_fold_env, reason: :env_write_observed,
                       file: fn.path, line: first_taint_line || fn.first_lineno || 0)
            end
          end
        end
        fn.children&.each { |c| scan_tree_for_taint(c, object_table, log) }
      end

      # Walk `insts`. For every ENV producer, ask consumer_safe? whether
      # the consumer pattern at that producer site is an allowed read-only
      # shape. Returns [tainted?, first_taint_line].
      def classify(insts, object_table)
        i = 0
        while i < insts.size
          inst = insts[i]
          if env_producer?(inst, object_table)
            safe, line = consumer_safe?(insts, i, object_table)
            unless safe
              return [true, line || inst.line]
            end
          end
          i += 1
        end
        [false, nil]
      end

      # For an ENV producer at `insts[i]`, return [safe?, consumer_line].
      # Safe if the consumer is:
      #   - opt_aref at i+2 (bare ENV[KEY]; consumes ENV+key), OR
      #   - the first opt_send_without_block encountered at insts[i + 1 + j]
      #     with cd.argc == j, mid ∈ SAFE_ENV_READ_METHODS, and no
      #     kwargs/splat/block.
      # Stops at the first send encountered: if that send doesn't match,
      # taints. Walking off the end without a send also taints.
      def consumer_safe?(insts, i, object_table)
        at_i_plus_2 = insts[i + 2]
        if at_i_plus_2 && at_i_plus_2.opcode == :opt_aref
          return [true, at_i_plus_2.line]
        end

        j = 0
        last_seen_line = nil
        loop do
          cand = insts[i + 1 + j]
          break unless cand
          last_seen_line = cand.line || last_seen_line
          if cand.opcode == :opt_send_without_block
            if safe_send?(cand, object_table, expected_argc: j)
              return [true, cand.line]
            else
              return [false, cand.line]
            end
          end
          j += 1
        end

        [false, last_seen_line]
      end

      def fetch_send?(inst, object_table)
        cd = inst.operands[0]
        return false unless cd.is_a?(IR::CallData)
        return false unless cd.argc == 1
        return false if cd.has_kwargs? || cd.has_splat? || cd.blockarg?
        cd.mid_symbol(object_table) == :fetch
      end

      def fetch_send_argc2?(inst, object_table)
        cd = inst.operands[0]
        return false unless cd.is_a?(IR::CallData)
        return false unless cd.argc == 2
        return false if cd.has_kwargs? || cd.has_splat? || cd.blockarg?
        cd.mid_symbol(object_table) == :fetch
      end

      def pure_default?(inst)
        inst && PURE_DEFAULT_OPCODES.include?(inst.opcode)
      end

      def safe_send?(inst, object_table, expected_argc:)
        cd = inst.operands[0]
        return false unless cd.is_a?(IR::CallData)
        return false unless cd.argc == expected_argc
        return false if cd.has_kwargs? || cd.has_splat? || cd.blockarg?
        SAFE_ENV_READ_METHODS.include?(cd.mid_symbol(object_table))
      end

      # Returns true if +inst+ is an ENV constant producer.
      #
      # For opt_getconstant_path: operand is an object-table index N.
      # object_table.objects[N] is a T_ARRAY of object-table indices;
      # resolving those indices gives the constant-path symbol list.
      # We match if any resolved symbol in that list is :ENV.
      #
      # For getconstant: operand is an ID (object-table index for the Symbol).
      # We match if it resolves to :ENV.
      def env_producer?(inst, object_table)
        case inst.opcode
        when :opt_getconstant_path
          path_idx = inst.operands[0]
          return false unless path_idx.is_a?(Integer)
          path_array = object_table.objects[path_idx]
          return false unless path_array.is_a?(Array)
          path_array.any? do |elem_idx|
            elem_idx.is_a?(Integer) && object_table.objects[elem_idx] == :ENV
          end
        when :getconstant
          id_idx = inst.operands[0]
          return false unless id_idx.is_a?(Integer)
          object_table.objects[id_idx] == :ENV
        else
          false
        end
      end

      # Returns true if +inst+ is a literal string producer whose operand
      # resolves to a String in the object table.
      def literal_string?(inst, object_table)
        return false unless inst
        case inst.opcode
        when :putchilledstring, :putstring
          idx = inst.operands[0]
          idx.is_a?(Integer) && object_table.objects[idx].is_a?(String)
        else
          false
        end
      end

      # Memoize the root on first call. Fresh pass per Pipeline.default
      # run keeps this scoped to a single run.
      def tree_root(function)
        @root ||= function
        @root
      end
    end
  end
end
