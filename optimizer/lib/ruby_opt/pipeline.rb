# frozen_string_literal: true
require "ruby_opt/log"

module RubyOpt
  class Pipeline
    def initialize(passes)
      @passes = passes
    end

    # Run all passes over every Function in the IR tree.
    # Returns the RubyOpt::Log accumulated during the run.
    def run(ir, type_env:)
      log = Log.new
      each_function(ir) do |function|
        @passes.each do |pass|
          begin
            pass.apply(function, type_env: type_env, log: log)
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
  end
end
