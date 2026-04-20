# frozen_string_literal: true
require "test_helper"
require "ruby_opt/codec"
require "ruby_opt/codec/line_info"
require "ruby_opt/codec/instruction_stream"
require "ruby_opt/codec/binary_writer"

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

  # 5d.i: LineInfo.encode must silently drop line entries whose instruction
  # has been removed, without raising KeyError.
  def test_encode_drops_dangling_line_entries_without_key_error
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

    # Pick an instruction that has at least one line entry, then remove it
    # to create a dangling reference in line_entries.
    insts_with_entries = m.line_entries.map(&:inst).uniq & m.instructions
    skip "no instruction with a line entry found" if insts_with_entries.empty?
    deleted_inst = insts_with_entries.first

    m.instructions.delete(deleted_inst)

    # Build the slot map from the REDUCED instruction list.
    inst_to_slot = RubyOpt::Codec::InstructionStream.inst_to_slot_map(m.instructions)

    # LineInfo.encode must NOT raise KeyError even though some entries
    # reference the deleted instruction.
    body_writer = RubyOpt::Codec::BinaryWriter.new
    pos_writer  = RubyOpt::Codec::BinaryWriter.new
    error = nil
    begin
      RubyOpt::Codec::LineInfo.encode(body_writer, pos_writer, m.line_entries, inst_to_slot)
    rescue => e
      error = e
    end
    assert_nil error, "LineInfo.encode raised unexpected error: #{error&.class}: #{error&.message}"

    # The filtered count must be strictly less than the original entry count.
    dangling_count = m.line_entries.count { |e| e.inst == deleted_inst }
    assert_operator dangling_count, :>, 0, "expected at least one dangling line entry"
    live_count = m.line_entries.count { |e| inst_to_slot.key?(e.inst) }
    assert_equal m.line_entries.size - dangling_count, live_count

    # The encoded body bytes must correspond to exactly live_count entries.
    # Each entry encodes 3 small_values in the body section.
    # A small_value ≤ 127 is 1 byte (the majority of line_no, node_id, events values).
    # We can't assert exact byte size without knowing all values, but we CAN assert
    # the body bytes are non-empty when live_count > 0.
    assert_operator live_count, :>, 0
    assert_operator body_writer.buffer.bytesize, :>, 0
    assert_operator pos_writer.buffer.bytesize, :>, 0
  end
end
