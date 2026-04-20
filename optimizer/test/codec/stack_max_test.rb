# frozen_string_literal: true
require "test_helper"
require "ruby_opt/codec"
require "ruby_opt/codec/stack_max"

class StackMaxTest < Minitest::Test
  def test_matches_or_exceeds_ruby_computed_value
    # For every corpus fixture, our computed stack_max must be >=
    # the value Ruby assigned at compile time.
    Dir[File.expand_path("corpus/*.rb", __dir__)].each do |path|
      src = File.read(path)
      ir = RubyOpt::Codec.decode(
        RubyVM::InstructionSequence.compile(src, path).to_binary
      )
      walk_ir(ir) do |function|
        original = function.misc[:stack_max] || 0
        computed = RubyOpt::Codec::StackMax.compute(function)
        assert_operator computed, :>=, original,
          "#{path} / #{function.name}: computed #{computed} < ruby's #{original}"
      end
    end
  end

  private

  def walk_ir(ir, &block)
    yield ir if ir.instructions
    ir.children&.each { |c| walk_ir(c, &block) }
  end
end
