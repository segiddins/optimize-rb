# frozen_string_literal: true
require "test_helper"
require "ruby_opt/codec"
require "ruby_opt/pipeline"

class ConstFoldPassCorpusTest < Minitest::Test
  def test_every_corpus_fixture_loads_through_default_pipeline
    corpus = Dir[File.expand_path("../codec/corpus/*.rb", __dir__)]
    skip "no codec corpus" if corpus.empty?
    corpus.each do |path|
      src = File.read(path)
      ir = RubyOpt::Codec.decode(
        RubyVM::InstructionSequence.compile(src, path).to_binary
      )
      RubyOpt::Pipeline.default.run(ir, type_env: nil)
      bin = RubyOpt::Codec.encode(ir)
      loaded = RubyVM::InstructionSequence.load_from_binary(bin)
      assert_kind_of RubyVM::InstructionSequence, loaded,
        "#{File.basename(path)} did not re-load after the default pipeline"
    end
  end
end
