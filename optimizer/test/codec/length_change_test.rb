# frozen_string_literal: true
require "test_helper"
require "ruby_opt/codec"
require "ruby_opt/ir/instruction"

class LengthChangeTest < Minitest::Test
  def test_deleting_an_instruction_re_encodes_to_a_loadable_iseq
    src = "def f; x = 1; x + 2; end; f"
    ir = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    f = ir.children.find { |c| c.name == "f" }
    setlocal_idx = f.instructions.index { |i| i.opcode.to_s.start_with?("setlocal") }
    skip "no setlocal in test fixture" unless setlocal_idx
    f.instructions.delete_at(setlocal_idx)
    modified = RubyOpt::Codec.encode(ir)
    loaded = RubyVM::InstructionSequence.load_from_binary(modified)
    assert_kind_of RubyVM::InstructionSequence, loaded
  end

  def test_inserting_a_nop_extends_the_iseq
    src = "def f; 1 + 2; end; f"
    ir = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    f = ir.children.find { |c| c.name == "f" }
    f.instructions.unshift(
      RubyOpt::IR::Instruction.new(opcode: :nop, operands: [], line: f.instructions.first.line)
    )
    modified = RubyOpt::Codec.encode(ir)
    loaded = RubyVM::InstructionSequence.load_from_binary(modified)
    assert_equal 3, loaded.eval
  end

  def test_round_trip_is_byte_identical_on_unmodified_ir
    Dir[File.expand_path("corpus/*.rb", __dir__)].each do |path|
      src = File.read(path)
      original = RubyVM::InstructionSequence.compile(src, path).to_binary
      ir = RubyOpt::Codec.decode(original)
      assert_equal original, RubyOpt::Codec.encode(ir), "mismatch for #{File.basename(path)}"
    end
  end
end
