# frozen_string_literal: true
require "optimize/demo"
require "optimize/codec"
require "optimize/pipeline"
require "optimize/type_env"

module Optimize
  module Demo
    module IseqSnapshots
      Result = Struct.new(:before, :after_full, :per_pass, :convergence, keyword_init: true)

      module_function

      def generate(fixture_path:, walkthrough:, entry_setup: "", entry_call: nil)
        source = build_source(fixture_path, entry_setup, entry_call)

        pass_index = Pipeline.default.passes.each_with_object({}) do |p, h|
          h[p.name] = p
        end
        unknown = walkthrough - pass_index.keys
        raise ArgumentError, "unknown pass name(s): #{unknown.inspect}" unless unknown.empty?

        before = compile_raw(source, fixture_path)
        after_full_disasm, after_full_log = run_with_passes(source, fixture_path, Pipeline.default.passes)

        per_pass = {}
        walkthrough.each_with_index do |name, idx|
          prefix = walkthrough[0..idx].map { |n| pass_index.fetch(n) }
          per_pass[name], _ = run_with_passes(source, fixture_path, prefix)
        end

        Result.new(
          before: before,
          after_full: after_full_disasm,
          per_pass: per_pass,
          convergence: after_full_log.convergence,
        )
      end

      # Compose a synthetic program: the fixture source followed by the
      # walkthrough's entry_setup + entry_call. Without the call site,
      # most passes see no-op iseqs (inlining needs a caller, const_fold
      # needs literals at a call).
      def build_source(fixture_path, entry_setup, entry_call)
        fixture_source = File.read(fixture_path)
        return fixture_source if entry_call.to_s.empty?
        "#{fixture_source.chomp}\n\n#{entry_setup}\n#{entry_call}\n"
      end

      def compile_raw(source, path)
        RubyVM::InstructionSequence.compile(source, path, path).disasm
      end

      def run_with_passes(source, path, passes)
        iseq = RubyVM::InstructionSequence.compile(source, path, path)
        binary = iseq.to_binary
        ir = Codec.decode(binary)
        type_env = TypeEnv.from_source(source, path)
        log = Pipeline.new(passes).run(ir, type_env: type_env)
        modified = Codec.encode(ir)
        [RubyVM::InstructionSequence.load_from_binary(modified).disasm, log]
      end
    end
  end
end
