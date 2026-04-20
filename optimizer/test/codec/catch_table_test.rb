# frozen_string_literal: true
require "test_helper"
require "ruby_opt/codec"

class CatchTableTest < Minitest::Test
  def test_rescue_method_round_trips_through_catch_entries
    src = <<~RUBY
      def safe_divide(a, b)
        a / b
      rescue ZeroDivisionError
        :nope
      end
      safe_divide(10, 2)
      safe_divide(10, 0)
    RUBY
    original = RubyVM::InstructionSequence.compile(src).to_binary
    ir = RubyOpt::Codec.decode(original)

    safe_divide = ir.children.find { |c| c.name == "safe_divide" }
    refute_nil safe_divide
    refute_empty safe_divide.catch_entries
    rescue_entry = safe_divide.catch_entries.find { |e| e.type == :rescue }
    refute_nil rescue_entry
    assert_includes safe_divide.instructions, rescue_entry.start_inst
    assert_includes safe_divide.instructions, rescue_entry.end_inst

    # Byte-identical round-trip still passes.
    assert_equal original, RubyOpt::Codec.encode(ir)
  end
end
