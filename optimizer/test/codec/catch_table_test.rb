# frozen_string_literal: true
require "test_helper"
require "ruby_opt/codec"
require "ruby_opt/codec/catch_table"
require "ruby_opt/codec/instruction_stream"
require "ruby_opt/codec/binary_writer"

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

  # 5d.ii: CatchTable.encode must silently drop catch entries whose start_inst,
  # end_inst, or cont_inst has been removed from the instruction list.
  def test_encode_drops_dangling_catch_entries_without_key_error
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

    # Pick the start_inst of a catch entry and remove it from instructions.
    rescue_entry = safe_divide.catch_entries.first
    deleted_inst = rescue_entry.start_inst
    safe_divide.instructions.delete(deleted_inst)

    # Build inst_to_slot from the REDUCED instruction list.
    inst_to_slot = RubyOpt::Codec::InstructionStream.inst_to_slot_map(safe_divide.instructions)

    # CatchTable.encode must NOT raise KeyError even though the entry's start_inst
    # is no longer in inst_to_slot.
    ct_writer = RubyOpt::Codec::BinaryWriter.new
    error = nil
    begin
      RubyOpt::Codec::CatchTable.encode(ct_writer, safe_divide.catch_entries, inst_to_slot)
    rescue => e
      error = e
    end
    assert_nil error, "CatchTable.encode raised unexpected error: #{error&.class}: #{error&.message}"

    # The dangling entry must have been dropped: live entries are those where
    # ALL instruction references are present in inst_to_slot.
    live_count = safe_divide.catch_entries.count do |e|
      inst_to_slot.key?(e.start_inst) &&
        inst_to_slot.key?(e.end_inst) &&
        (e.cont_inst.nil? || inst_to_slot.key?(e.cont_inst))
    end
    total_count = safe_divide.catch_entries.size
    assert_operator live_count, :<, total_count,
      "expected at least one catch entry to be dropped due to dangling start_inst"
  end
end
