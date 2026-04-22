# frozen_string_literal: true
require "ruby_opt/log"
require "ruby_opt/ir/slot_type_table"
require "ruby_opt/passes/inlining_pass"
require "ruby_opt/passes/arith_reassoc_pass"
require "ruby_opt/passes/const_fold_tier2_pass"
require "ruby_opt/passes/const_fold_env_pass"
require "ruby_opt/passes/const_fold_pass"
require "ruby_opt/passes/identity_elim_pass"
require "ruby_opt/passes/dead_branch_fold_pass"

module RubyOpt
  class Pipeline
    def self.default
      new([
        Passes::InliningPass.new,
        Passes::ArithReassocPass.new,
        # ConstFoldTier2Pass rewrites frozen top-level constant references
        # to their literal values. Runs before the other const-folders so
        # `FOO + 1` → `42 + 1` → `43` cascades in one pipeline run.
        Passes::ConstFoldTier2Pass.new,
        # ConstFoldEnvPass runs BEFORE ConstFoldPass so `ENV["FLAG"] == "true"`
        # can cascade through string-eq folding in a single pipeline run.
        Passes::ConstFoldEnvPass.new,
        Passes::ConstFoldPass.new,
        Passes::IdentityElimPass.new,
        # DeadBranchFoldPass runs LAST — any earlier pass that turns a
        # branch condition into a literal (ConstFold*, IdentityElim) feeds
        # this pass, which collapses `<lit>; branch*` into either a
        # `jump` (taken) or a drop (not taken).
        Passes::DeadBranchFoldPass.new,
      ])
    end

    attr_reader :passes

    def initialize(passes)
      @passes = passes
    end

    # Run all passes over every Function in the IR tree.
    # Returns the RubyOpt::Log accumulated during the run.
    def run(ir, type_env:, env_snapshot: nil)
      log = Log.new
      object_table = ir.misc && ir.misc[:object_table]
      callee_map = build_callee_map(ir)
      slot_type_map, signature_map = build_type_maps(ir, type_env, object_table)

      seen_fns = {}.compare_by_identity
      each_function(ir) do |function|
        next if seen_fns[function]
        seen_fns[function] = true
        @passes.each do |pass|
          begin
            pass.apply(
              function,
              type_env: type_env, log: log,
              object_table: object_table, callee_map: callee_map,
              slot_type_map: slot_type_map,
              signature_map: signature_map,
              env_snapshot: env_snapshot,
            )
          rescue => e
            log.skip(pass: pass.name, reason: :pass_raised,
                     file: function.path, line: function.first_lineno || 0)
          end
        end
      end
      log
    end

    private

    def each_function(function, &block)
      yield function
      function.children&.each do |child|
        each_function(child, &block)
      end
    end

    def build_callee_map(ir)
      map = {}
      walk_with_class_context(ir, nil) do |fn, class_context|
        next unless fn.type == :method && fn.name
        if class_context
          map[[class_context, fn.name.to_sym]] = fn
        else
          map[fn.name.to_sym] = fn
        end
      end
      # The codec decoder flattens all iseqs under <root> and leaves many
      # methods' parent_iseq_index as -1, so the walk above misses
      # class-scoped methods. Recover the class binding by scanning each
      # class body's `definemethod` instructions and resolving the ISEQ
      # operand through the iseq_list's flat function array.
      iseqs = ir.misc && ir.misc[:iseq_list] && ir.misc[:iseq_list].functions
      object_table = ir.misc && ir.misc[:object_table]
      if iseqs && object_table
        each_function(ir) do |fn|
          next unless fn.type == :class
          class_name = class_name_from_iseq(fn.name)
          (fn.instructions || []).each do |inst|
            next unless inst.opcode == :definemethod
            id_idx, iseq_idx = inst.operands[0], inst.operands[1]
            next unless iseq_idx.is_a?(Integer) && iseq_idx >= 0 && iseq_idx < iseqs.size
            callee = iseqs[iseq_idx]
            next unless callee && callee.type == :method
            mid = object_table.objects[id_idx] if id_idx.is_a?(Integer)
            mid = callee.name.to_sym unless mid.is_a?(Symbol)
            map[[class_name, mid]] = callee
          end
        end
      end
      map
    end

    def walk_with_class_context(fn, class_context, &block)
      yield fn, class_context
      next_ctx = fn.type == :class ? class_name_from_iseq(fn.name) : class_context
      (fn.children || []).each do |child|
        walk_with_class_context(child, next_ctx, &block)
      end
    end

    # Real iseqs for class bodies are labelled "<class:Point>" by the
    # compiler; synthetic test-stub functions label them "Point". Accept both
    # so the callee_map key matches what SlotTypeTable produces from
    # `opt_getconstant_path [:Point]` ("Point").
    def class_name_from_iseq(name)
      return name unless name.is_a?(String)
      m = name.match(/\A<class:(.+)>\z/)
      m ? m[1] : name
    end

    def build_type_maps(ir, type_env, object_table)
      slot_type_map = {}.compare_by_identity
      signature_map = {}.compare_by_identity
      # The codec decoder can share a child between multiple parent function
      # children arrays (e.g. a block iseq is listed under both <root> and
      # <top>); we only want the first, deepest-parent visit to build the
      # table so `lookup(slot, level=1)` can walk up to the real enclosing
      # scope. Track visited functions by identity.
      visited = {}.compare_by_identity
      walk_with_context(ir, class_context: nil, parent_table: nil, visited: visited) do |fn, class_context, parent_table|
        sig = type_env && type_env.signature_for_function(fn, class_context: class_context)
        signature_map[fn] = sig if sig
        table = IR::SlotTypeTable.build(fn, sig, parent_table, object_table: object_table)
        slot_type_map[fn] = table
        [class_context_for_child(fn, class_context), table]
      end
      [slot_type_map, signature_map]
    end

    def walk_with_context(fn, class_context:, parent_table:, visited: nil, &block)
      if visited
        return if visited[fn]
        visited[fn] = true
      end
      next_ctx, next_parent = yield(fn, class_context, parent_table)
      (fn.children || []).each do |child|
        walk_with_context(child, class_context: next_ctx, parent_table: next_parent, visited: visited, &block)
      end
    end

    def class_context_for_child(fn, current_ctx)
      return class_name_from_iseq(fn.name) if fn.type == :class
      current_ctx
    end
  end
end
