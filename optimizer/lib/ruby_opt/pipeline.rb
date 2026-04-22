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

      each_function(ir) do |function|
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
      each_function(ir) do |fn|
        next unless fn.type == :method
        next unless fn.name
        map[fn.name.to_sym] = fn
      end
      map
    end

    def build_type_maps(ir, type_env, object_table)
      slot_type_map = {}.compare_by_identity
      signature_map = {}.compare_by_identity
      walk_with_context(ir, class_context: nil, parent_table: nil) do |fn, class_context, parent_table|
        sig = type_env && type_env.signature_for_function(fn, class_context: class_context)
        signature_map[fn] = sig if sig
        table = IR::SlotTypeTable.build(fn, sig, parent_table, object_table: object_table)
        slot_type_map[fn] = table
        [class_context_for_child(fn, class_context), table]
      end
      [slot_type_map, signature_map]
    end

    def walk_with_context(fn, class_context:, parent_table:, &block)
      next_ctx, next_parent = yield(fn, class_context, parent_table)
      (fn.children || []).each do |child|
        walk_with_context(child, class_context: next_ctx, parent_table: next_parent, &block)
      end
    end

    def class_context_for_child(fn, current_ctx)
      return fn.name if fn.type == :class
      current_ctx
    end
  end
end
