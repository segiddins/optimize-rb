# frozen_string_literal: true
require "test_helper"
require "optimize/codec"
require "optimize/ir/instruction"

class EncodeModificationsTest < Minitest::Test
  def test_modifying_putobject_operand_changes_bytes
    # Use 256 and 512: they go through the normal putobject path (not INT2FIX specialisation).
    # Change second putobject to use the object-table index of 256 (making f return 256+256=512).
    src = "def f; 256 + 512; end; f"
    original = RubyVM::InstructionSequence.compile(src).to_binary
    ir = Optimize::Codec.decode(original)

    f = ir.children.find { |c| c.name == "f" }
    refute_nil f
    putobjects = f.instructions.select { |i| i.opcode == :putobject }
    assert putobjects.size >= 2, "expected 2+ putobject ops, got #{f.instructions.inspect}"

    # Operands are raw object-table indices. Swap them: 256+512 becomes 512+256 (same sum),
    # but the two indices differ so the encoded bytes must change.
    idx0 = putobjects[0].operands[0]
    idx1 = putobjects[1].operands[0]
    # If indices happen to be the same, the test would be vacuous — guard against that.
    refute_equal idx0, idx1, "object-table indices for 256 and 512 must differ"
    # Swap: f now does putobject(idx1) + putobject(idx0) → 512 + 256 = 768 (same result),
    # but the operand bytes in the bytecode stream are swapped → bytes must differ.
    putobjects[0].operands[0] = idx1
    putobjects[1].operands[0] = idx0

    modified = Optimize::Codec.encode(ir)
    refute_equal original, modified, "expected re-encoded bytes to differ after mutation"
    # Load and eval; 512 + 256 = 768 (addition is commutative).
    loaded = RubyVM::InstructionSequence.load_from_binary(modified)
    assert_equal 768, loaded.eval
  end

  def test_round_trip_is_still_identity_when_instructions_unmodified
    src = "[1, 2, 3].map { |n| n * 2 }"
    original = RubyVM::InstructionSequence.compile(src).to_binary
    ir = Optimize::Codec.decode(original)
    re_encoded = Optimize::Codec.encode(ir)
    assert_equal original, re_encoded
  end

end
