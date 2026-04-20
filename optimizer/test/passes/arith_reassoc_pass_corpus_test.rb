# frozen_string_literal: true
require "test_helper"
require "ruby_opt/codec"
require "ruby_opt/pipeline"

class ArithReassocPassCorpusTest < Minitest::Test
  def test_every_corpus_fixture_survives_default_pipeline_with_arith
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

  def test_default_pipeline_includes_arith_before_const_fold
    passes = RubyOpt::Pipeline.default.instance_variable_get(:@passes)
    assert_equal :arith_reassoc, passes[0].name
    assert_equal :const_fold,    passes[1].name
  end

  def test_default_pipeline_collapses_chain_const_fold_cannot_reach
    src = "def f(x); x + 1 + 2 + 3; end; f(10)"
    ir = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    RubyOpt::Pipeline.default.run(ir, type_env: nil)
    loaded = RubyVM::InstructionSequence.load_from_binary(RubyOpt::Codec.encode(ir))
    assert_equal 16, loaded.eval
    f = find_iseq(ir, "f")
    assert_equal 1, f.instructions.count { |i| i.opcode == :opt_plus }
  end

  private

  def find_iseq(ir, name)
    return ir if ir.name == name
    ir.children&.each do |c|
      found = find_iseq(c, name)
      return found if found
    end
    nil
  end
end
