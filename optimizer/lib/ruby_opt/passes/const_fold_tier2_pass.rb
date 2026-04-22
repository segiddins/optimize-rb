# frozen_string_literal: true
require "set"
require "ruby_opt/pass"
require "ruby_opt/passes/literal_value"
require "ruby_opt/ir/instruction"

module RubyOpt
  module Passes
    # Tier 2 const-fold: frozen top-level constants.
    #
    # Scans the whole IR tree for `setconstant :NAME` sites. Admits a name
    # to the fold table only when its sole assignment is a top-level
    # literal:
    #
    #     <literal-producer>
    #     putspecialobject 3
    #     setconstant :NAME
    #
    # Any other assignment shape (nested `dup`-flavored, non-literal RHS,
    # reassignment) taints the name — both removing it from the fold
    # table and barring re-admission.
    #
    # Fold phase rewrites `opt_getconstant_path <idx>` where
    # `object_table[idx]` is a single-element T_ARRAY whose symbol is in
    # the fold table.
    class ConstFoldTier2Pass < RubyOpt::Pass
      TABLE_KEY   = :const_fold_tier2_table
      TAINTED_KEY = :const_fold_tier2_tainted
      SCANNED_KEY = :const_fold_tier2_scanned

      def name = :const_fold_tier2

      def apply(function, type_env:, log:, object_table: nil, **_extras)
        _ = type_env
        return unless object_table

        root = tree_root(function)
        root.misc ||= {}
        unless root.misc[SCANNED_KEY]
          root.misc[SCANNED_KEY]  = true
          root.misc[TABLE_KEY]    = {}
          root.misc[TAINTED_KEY]  = Set.new
          scan_tree(root, object_table, log, root.misc[TABLE_KEY], root.misc[TAINTED_KEY])
        end

        table = root.misc[TABLE_KEY]
        return if table.empty?

        insts = function.instructions
        return unless insts

        i = 0
        while i < insts.size
          inst = insts[i]
          if inst.opcode == :opt_getconstant_path
            name = single_name_for_path(inst, object_table)
            if name && table.key?(name)
              replacement = emit_literal(table[name], line: inst.line, object_table: object_table)
              if replacement
                function.splice_instructions!(i..i, [replacement])
                log.skip(pass: name_sym, reason: :folded,
                         file: function.path, line: (inst.line || function.first_lineno || 0))
              end
            end
          end
          i += 1
        end
      end

      private

      def name_sym = :const_fold_tier2

      # Walk every function. For each `setconstant`, classify the
      # preceding shape and update table/tainted accordingly.
      def scan_tree(fn, object_table, log, table, tainted)
        insts = fn.instructions
        scan_function(fn, insts, object_table, log, table, tainted) if insts
        fn.children&.each { |c| scan_tree(c, object_table, log, table, tainted) }
      end

      def scan_function(fn, insts, object_table, log, table, tainted)
        insts.each_with_index do |inst, i|
          next unless inst.opcode == :setconstant
          name = setconstant_name(inst, object_table)
          next unless name

          shape = classify_setconstant(insts, i, object_table)

          case shape[:kind]
          when :top_level_literal
            value = shape[:value]
            if tainted.include?(name)
              # already tainted — nothing to do
            elsif table.key?(name) && table[name] != value
              taint!(table, tainted, name)
              log.skip(pass: name_sym, reason: :reassigned,
                       file: fn.path, line: inst.line || fn.first_lineno || 0)
            elsif table.key?(name) && table[name] == value
              # redundant identical assignment — still two sites;
              # conservatively taint because Ruby would warn and the
              # semantics allow reassignment. A later session can
              # refine if we care.
              taint!(table, tainted, name)
              log.skip(pass: name_sym, reason: :reassigned,
                       file: fn.path, line: inst.line || fn.first_lineno || 0)
            else
              table[name] = value
            end
          when :non_literal_rhs
            taint!(table, tainted, name)
            log.skip(pass: name_sym, reason: :non_literal_rhs,
                     file: fn.path, line: inst.line || fn.first_lineno || 0)
          when :non_top_level
            taint!(table, tainted, name)
            log.skip(pass: name_sym, reason: :non_top_level,
                     file: fn.path, line: inst.line || fn.first_lineno || 0)
          end
        end
      end

      def taint!(table, tainted, name)
        tainted << name
        table.delete(name)
      end

      # Given `insts[i]` is `setconstant :NAME`, look at i-1, i-2.
      # Returns a hash describing the assignment shape.
      def classify_setconstant(insts, i, object_table)
        prev1 = i >= 1 ? insts[i - 1] : nil
        prev2 = i >= 2 ? insts[i - 2] : nil

        # Top-level shape: <literal>; putspecialobject 3; setconstant
        if prev1 && prev1.opcode == :putspecialobject && prev1.operands[0] == 3 &&
           prev2 && literal_producer?(prev2) && intern_safe_literal_value?(prev2, object_table)
          value = LiteralValue.read(prev2, object_table: object_table)
          # Explicit literal? covers the "putnil vs unknown" disambiguation.
          if LiteralValue.literal?(prev2)
            return { kind: :top_level_literal, value: value }
          end
        end

        # Top-level but non-literal RHS: <non-literal>; putspecialobject 3; setconstant
        if prev1 && prev1.opcode == :putspecialobject && prev1.operands[0] == 3
          return { kind: :non_literal_rhs }
        end

        # Anything else — nested / dup-flavored / module-scope.
        { kind: :non_top_level }
      end

      def literal_producer?(inst)
        LiteralValue.literal?(inst)
      end

      # True if `inst`'s literal value is one `intern` / LiteralValue.emit
      # knows how to re-emit.
      def intern_safe_literal_value?(inst, object_table)
        return true if inst.opcode == :putobject_INT2FIX_0_ || inst.opcode == :putobject_INT2FIX_1_
        return true if inst.opcode == :putnil
        value = LiteralValue.read(inst, object_table: object_table)
        case value
        when Integer then value.bit_length < 62
        when String, true, false then true
        when nil     then inst.opcode == :putnil # only real nil, not unknown
        else false
        end
      end

      # setconstant operand[0] is a Symbol-index into object_table.
      def setconstant_name(inst, object_table)
        idx = inst.operands[0]
        return nil unless idx.is_a?(Integer)
        sym = object_table.objects[idx]
        sym.is_a?(Symbol) ? sym : nil
      end

      # Returns the single Symbol name for a bare top-level
      # `opt_getconstant_path [:NAME]`, else nil.
      def single_name_for_path(inst, object_table)
        path_idx = inst.operands[0]
        return nil unless path_idx.is_a?(Integer)
        path = object_table.objects[path_idx]
        return nil unless path.is_a?(Array) && path.size == 1
        elem = path[0]
        return nil unless elem.is_a?(Integer)
        sym = object_table.objects[elem]
        sym.is_a?(Symbol) ? sym : nil
      end

      def emit_literal(value, line:, object_table:)
        case value
        when Integer
          LiteralValue.emit(value, line: line, object_table: object_table)
        when String
          idx = object_table.intern(value)
          IR::Instruction.new(opcode: :putobject, operands: [idx], line: line)
        when true, false
          idx = object_table.intern(value)
          IR::Instruction.new(opcode: :putobject, operands: [idx], line: line)
        when nil
          IR::Instruction.new(opcode: :putnil, operands: [], line: line)
        else
          nil
        end
      end

      def tree_root(function)
        @root ||= function
        @root
      end
    end
  end
end
