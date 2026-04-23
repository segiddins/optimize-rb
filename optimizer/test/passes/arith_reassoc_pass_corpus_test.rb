# frozen_string_literal: true
require "test_helper"
require "optimize/codec"
require "optimize/pipeline"

class ArithReassocPassCorpusTest < Minitest::Test
  def test_every_corpus_fixture_survives_default_pipeline_with_arith
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

  def test_default_pipeline_includes_arith_before_const_fold
    passes = Optimize::Pipeline.default.instance_variable_get(:@passes)
    names = passes.map(&:name)
    arith_idx = names.index(:arith_reassoc)
    const_idx = names.index(:const_fold)
    refute_nil arith_idx
    refute_nil const_idx
    assert arith_idx < const_idx,
      "expected arith_reassoc before const_fold in default pipeline, got #{names.inspect}"
  end

  def test_default_pipeline_collapses_chain_const_fold_cannot_reach
    src = "def f(x); x + 1 + 2 + 3; end; f(10)"
    ir = Optimize::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    Optimize::Pipeline.default.run(ir, type_env: nil)
    loaded = RubyVM::InstructionSequence.load_from_binary(Optimize::Codec.encode(ir))
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
