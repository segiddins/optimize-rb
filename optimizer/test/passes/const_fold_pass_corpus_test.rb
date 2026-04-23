# frozen_string_literal: true
require "test_helper"
require "optimize/codec"
require "optimize/pipeline"

class ConstFoldPassCorpusTest < Minitest::Test
  def test_every_corpus_fixture_loads_through_default_pipeline
    corpus = Dir[File.expand_path("../codec/corpus/*.rb", __dir__)]
    skip "no codec corpus" if corpus.empty?
    corpus.each do |path|
      src = File.read(path)
      ir = Optimize::Codec.decode(
        RubyVM::InstructionSequence.compile(src, path).to_binary
      )
      Optimize::Pipeline.default.run(ir, type_env: nil)
      bin = Optimize::Codec.encode(ir)
      loaded = RubyVM::InstructionSequence.load_from_binary(bin)
      assert_kind_of RubyVM::InstructionSequence, loaded,
        "#{File.basename(path)} did not re-load after the default pipeline"
    end
  end
end
