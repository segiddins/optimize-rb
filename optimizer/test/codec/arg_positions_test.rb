# frozen_string_literal: true
require "test_helper"
require "ruby_opt/codec"

class ArgPositionsTest < Minitest::Test
  def test_method_with_optional_args_round_trips_opt_table
    src = <<~RUBY
      def f(a, b = 10, c = 20)
        a + b + c
      end
      f(1)
      f(1, 2, 3)
    RUBY
    original = RubyVM::InstructionSequence.compile(src).to_binary
    ir = RubyOpt::Codec.decode(original)

    f = ir.children.find { |c| c.name == "f" }
    refute_nil f
    refute_empty f.arg_positions.opt_table
    f.arg_positions.opt_table.each do |inst|
      assert_includes f.instructions, inst,
        "opt_table entry does not reference a method instruction"
    end

    assert_equal original, RubyOpt::Codec.encode(ir)
  end

  def test_method_with_keyword_args_round_trips
    src = 'def g(name:, greeting: "hi"); "#{greeting} #{name}"; end; g(name: "x")'
    original = RubyVM::InstructionSequence.compile(src).to_binary
    ir = RubyOpt::Codec.decode(original)
    assert_equal original, RubyOpt::Codec.encode(ir)
  end
end
