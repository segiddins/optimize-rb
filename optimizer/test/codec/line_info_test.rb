# frozen_string_literal: true
require "test_helper"
require "ruby_opt/codec"

class LineInfoTest < Minitest::Test
  def test_multiline_method_has_line_entries_per_instruction_group
    src = <<~RUBY
      def multi
        x = 1
        y = 2
        x + y
      end
      multi
    RUBY
    original = RubyVM::InstructionSequence.compile(src).to_binary
    ir = RubyOpt::Codec.decode(original)

    m = ir.children.find { |c| c.name == "multi" }
    refute_nil m
    refute_empty m.line_entries
    m.line_entries.each do |e|
      assert_includes m.instructions, e.inst, "line entry points at a non-member instruction"
    end
    assert_operator m.line_entries.map(&:line_no).uniq.size, :>=, 3

    assert_equal original, RubyOpt::Codec.encode(ir)
  end
end
