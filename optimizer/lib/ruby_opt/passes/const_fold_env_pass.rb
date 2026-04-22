# frozen_string_literal: true
require "ruby_opt/pass"
require "ruby_opt/passes/literal_value"
require "ruby_opt/ir/instruction"

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

      def name = :const_fold_env

      def apply(function, type_env:, log:, object_table: nil, env_snapshot: nil, **_extras)
        _ = type_env
        return unless object_table
        return unless env_snapshot
        insts = function.instructions
        return unless insts

        tainted_here, first_taint_line = classify(insts, object_table)
        root = tree_root(function)
        root.misc ||= {}
        if tainted_here && !root.misc[TAINT_FLAG_KEY]
          root.misc[TAINT_FLAG_KEY] = true
          log.skip(pass: :const_fold_env, reason: :env_write_observed,
                   file: function.path, line: first_taint_line || function.first_lineno || 0)
        end
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

          unless env_producer?(a, object_table) && literal_string?(b, object_table) && op.opcode == :opt_aref
            i += 1
            next
          end

          key = LiteralValue.read(b, object_table: object_table)
          value = env_snapshot[key]

          replacement =
            if value.nil?
              IR::Instruction.new(opcode: :putnil, operands: [], line: a.line)
            elsif value.is_a?(String)
              idx = object_table.index_for(value)
              if idx.nil?
                log.skip(pass: :const_fold_env, reason: :env_value_not_interned,
                         file: function.path, line: (a.line || function.first_lineno || 0))
                nil
              else
                IR::Instruction.new(opcode: :putobject, operands: [idx], line: a.line)
              end
            else
              # ENV values are strings or nil by contract. Defensive.
              log.skip(pass: :const_fold_env, reason: :env_value_not_string,
                       file: function.path, line: (a.line || function.first_lineno || 0))
              nil
            end

          if replacement
            function.splice_instructions!(i..(i + 2), [replacement])
            log.skip(pass: :const_fold_env, reason: :folded,
                     file: function.path, line: (a.line || function.first_lineno || 0))
            i += 1
          else
            i += 1
          end
        end
      end

      private

      # Walk `insts`. For every ENV producer, the stack consumer is
      # `insts[i+2]` (the key producer sits at i+1). Safe iff the
      # consumer is `opt_aref`. Returns [tainted?, first_taint_line].
      def classify(insts, object_table)
        first_taint_line = nil
        i = 0
        while i < insts.size
          inst = insts[i]
          if env_producer?(inst, object_table)
            consumer = insts[i + 2]
            unless consumer && consumer.opcode == :opt_aref
              first_taint_line ||= (consumer&.line || inst.line)
              return [true, first_taint_line]
            end
          end
          i += 1
        end
        [false, nil]
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
