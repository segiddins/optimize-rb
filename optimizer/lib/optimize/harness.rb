# frozen_string_literal: true
require "optimize/codec"
require "optimize/pipeline"
require "optimize/type_env"

module Optimize
  module Harness
    OPT_OUT_RE = /\A#\s*rbs-optimize\s*:\s*false\s*\z/

    module_function

    # Whether the source file has opted out of optimization. Scans the
    # first 5 lines for a `# rbs-optimize: false` directive.
    def opted_out?(source)
      source.each_line.first(5).any? { |line| OPT_OUT_RE.match?(line.chomp) }
    end

    # Install a single process-wide hook that runs `passes` on every loaded
    # iseq. Calling `install` a second time replaces the previous hook. Returns
    # the installed `LoadIseqHook` so the caller can `uninstall` later.
    def install(passes: Pipeline.default.passes)
      @current&.uninstall
      @current = LoadIseqHook.new(passes: passes)
      @current.install
      @current
    end

    # Uninstall the currently-installed hook, if any. No-op otherwise.
    def uninstall
      @current&.uninstall
      @current = nil
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
            Optimize::Harness::LoadIseqHook::HOOKS[#{id}].__transform(path)
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
        warn "[optimize] harness fell back on #{path}: #{e.class}: #{e.message}"
        nil
      end
    end
  end
end
