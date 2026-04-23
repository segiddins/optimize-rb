# frozen_string_literal: true

module Optimize
  VERSION = "0.0.0"

  # One-shot sugar: compile `source`, run `Pipeline.default`, return a new
  # `RubyVM::InstructionSequence`. Raises on pipeline or codec failure —
  # callers who want silent fallback should use `Optimize::Harness` instead.
  def self.optimize(source, path: "(optimize)", type_env: nil)
    require "optimize/codec"
    require "optimize/pipeline"
    require "optimize/type_env"

    iseq = RubyVM::InstructionSequence.compile(source, path, path)
    ir = Codec.decode(iseq.to_binary)
    env = type_env || TypeEnv.from_source(source, path)
    Pipeline.default.run(ir, type_env: env)
    RubyVM::InstructionSequence.load_from_binary(Codec.encode(ir))
  end
end
