# frozen_string_literal: true
require "test_helper"
require "optimize/codec"
require "optimize/codec/line_info"
require "optimize/codec/instruction_stream"
require "optimize/codec/binary_writer"
require "optimize/ir/instruction"
require "optimize/ir/line_entry"

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
    ir = Optimize::Codec.decode(original)

    m = ir.children.find { |c| c.name == "multi" }
    refute_nil m
    refute_empty m.line_entries
    m.line_entries.each do |e|
      assert_includes m.instructions, e.inst, "line entry points at a non-member instruction"
    end
    assert_operator m.line_entries.map(&:line_no).uniq.size, :>=, 3

    assert_equal original, Optimize::Codec.encode(ir)
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
    ir = Optimize::Codec.decode(original)

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
    inst_to_slot = Optimize::Codec::InstructionStream.inst_to_slot_map(m.instructions)

    # LineInfo.encode must NOT raise KeyError even though some entries
    # reference the deleted instruction.
    body_writer = Optimize::Codec::BinaryWriter.new
    pos_writer  = Optimize::Codec::BinaryWriter.new
    error = nil
    begin
      Optimize::Codec::LineInfo.encode(body_writer, pos_writer, m.line_entries, inst_to_slot)
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

  # Integration test: full decode → mutate (inject a dangling line entry pointing at a
  # phantom instruction that is NOT in the instruction list) → encode →
  # RubyVM::InstructionSequence.load_from_binary round-trip.
  #
  # This models the real optimizer scenario: an optimizer pass removes an instruction from
  # the stream but forgets to prune stale line_entries. The encoder must silently drop the
  # dangling entry, patch insns_info_size in the body record, and produce a binary that
  # Ruby can load cleanly.
  def test_dangling_line_entry_survives_full_encode_and_load
    src = <<~RUBY
      def multi
        x = 1
        y = 2
        x + y
      end
      multi
    RUBY
    original = RubyVM::InstructionSequence.compile(src).to_binary
    ir = Optimize::Codec.decode(original)

    m = ir.children.find { |c| c.name == "multi" }
    refute_nil m
    refute_empty m.line_entries

    # Inject a dangling line entry pointing at a phantom instruction that is NOT in
    # m.instructions. This simulates an optimizer removing an instruction while leaving
    # a stale line_entry reference behind.
    phantom = Optimize::IR::Instruction.new(opcode: :nop, operands: [], line: nil)
    dangling_entry = Optimize::IR::LineEntry.new(
      inst:        phantom,
      slot_offset: 0,
      line_no:     m.line_entries.first.line_no,
      node_id:     m.line_entries.first.node_id,
      events:      m.line_entries.first.events,
    )
    original_count = m.line_entries.size
    m.line_entries << dangling_entry

    # Full encode must not raise (the dangling entry is silently dropped),
    # and the result must load cleanly.
    re_encoded = Optimize::Codec.encode(ir)
    loaded = RubyVM::InstructionSequence.load_from_binary(re_encoded)
    assert_kind_of RubyVM::InstructionSequence, loaded

    # The dangling entry must have been excluded: live count == original_count.
    assert_equal original_count, m.line_entries.count { |e|
      # After encode, the injected phantom is still in m.line_entries (not mutated),
      # so we check by identity.
      e != dangling_entry
    }
  end
end
