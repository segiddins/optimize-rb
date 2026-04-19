# frozen_string_literal: true
require "ruby_opt/codec"
require "ruby_opt/pipeline"
require "ruby_opt/type_env"

module RubyOpt
  module Harness
    OPT_OUT_RE = /\A#\s*rbs-optimize\s*:\s*false\s*\z/

    module_function

    # Whether the source file has opted out of optimization. Scans the
    # first 5 lines for a `# rbs-optimize: false` directive.
    def opted_out?(source)
      source.each_line.first(5).any? { |line| OPT_OUT_RE.match?(line.chomp) }
    end

    # Intercepts RubyVM::InstructionSequence.load_iseq, runs the
    # configured pipeline on every loaded iseq, and falls back to the
    # built-in compiler on any failure.
    class LoadIseqHook
      HOOKS = {}

      def initialize(passes:)
        @pipeline = Pipeline.new(passes)
        @id = object_id
        @installed = false
      end

      def install
        return if @installed
        HOOKS[@id] = self
        id = @id
        meta = class << RubyVM::InstructionSequence; self; end
        meta.class_eval(<<~RUBY, __FILE__, __LINE__ + 1)
          def load_iseq(path)
            RubyOpt::Harness::LoadIseqHook::HOOKS[#{id}].__transform(path)
          end
        RUBY
        @installed = true
      end

      def uninstall
        return unless @installed
        HOOKS.delete(@id)
        meta = class << RubyVM::InstructionSequence; self; end
        meta.remove_method(:load_iseq)
        @installed = false
      end

      def __transform(path)
        source = File.read(path)
        return nil if Harness.opted_out?(source)

        iseq = RubyVM::InstructionSequence.compile(source, path, path)
        binary = iseq.to_binary
        ir = Codec.decode(binary)
        type_env = TypeEnv.from_source(source, path)
        @pipeline.run(ir, type_env: type_env)
        modified = Codec.encode(ir)
        RubyVM::InstructionSequence.load_from_binary(modified)
      rescue => e
        warn "[ruby_opt] harness fell back on #{path}: #{e.class}: #{e.message}"
        nil
      end
    end
  end
end
