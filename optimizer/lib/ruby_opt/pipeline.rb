# frozen_string_literal: true
require "ruby_opt/log"
require "ruby_opt/passes/inlining_pass"
require "ruby_opt/passes/arith_reassoc_pass"
require "ruby_opt/passes/const_fold_pass"
require "ruby_opt/passes/identity_elim_pass"

module RubyOpt
  class Pipeline
    def self.default
      new([
        Passes::InliningPass.new,
        Passes::ArithReassocPass.new,
        Passes::ConstFoldPass.new,
        Passes::IdentityElimPass.new,
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
      each_function(ir) do |function|
        @passes.each do |pass|
          begin
            pass.apply(
              function,
              type_env: type_env, log: log,
              object_table: object_table, callee_map: callee_map,
              env_snapshot: env_snapshot,
            )
          rescue => e
            log.skip(
              pass: pass.name,
              reason: :pass_raised,
              file: function.path,
              line: function.first_lineno || 0,
            )
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
  end
end
