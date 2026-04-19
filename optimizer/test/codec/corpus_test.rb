# frozen_string_literal: true
require "test_helper"
require "ruby_opt/codec"

class CorpusTest < Minitest::Test
  Dir[File.join(__dir__, "corpus", "*.rb")].each do |path|
    name = File.basename(path, ".rb")
    define_method(:"test_corpus_#{name}") do
      source = File.read(path)
      original = RubyVM::InstructionSequence.compile(source, path).to_binary
      ir = RubyOpt::Codec.decode(original)
      re_encoded = RubyOpt::Codec.encode(ir)
      assert_equal original, re_encoded, "mismatch for #{name}"
      # Must also still run
      RubyVM::InstructionSequence.load_from_binary(re_encoded).eval
    end
  end
end
