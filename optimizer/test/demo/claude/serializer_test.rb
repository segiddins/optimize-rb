# frozen_string_literal: true
require "test_helper"
require "optimize/demo/claude/serializer"

class SerializerTest < Minitest::Test
  FIXTURE = <<~RUBY
    def answer
      2 + 3
    end
  RUBY

  def decode_method(source, method_name)
    iseq = RubyVM::InstructionSequence.compile(source)
    root = Optimize::Codec.decode(iseq.to_binary)
    object_table = root.misc[:object_table]
    target = find_function(root, method_name.to_s) or
      raise "method #{method_name} not found in iseq tree"
    [target, object_table]
  end

  def find_function(fn, name)
    return fn if fn.name == name
    (fn.children || []).each do |c|
      found = find_function(c, name)
      return found if found
    end
    nil
  end

  def serialize_answer
    fn, ot = decode_method(FIXTURE, :answer)
    Optimize::Demo::Claude::Serializer.serialize(fn, object_table: ot)
  end

  def test_serialize_returns_array_of_tuples
    result = serialize_answer
    assert_kind_of Array, result
    refute_empty result
    result.each do |tuple|
      assert_kind_of Array, tuple
      assert_kind_of String, tuple.first
    end
  end

  def test_serialize_resolves_value_operands
    result = serialize_answer
    putobjects = result.select { |t| t[0] == "putobject" }
    values = putobjects.map { |t| t[1] }
    assert_includes values, 2
    assert_includes values, 3
  end

  def test_serialize_emits_call_data_hash
    result = serialize_answer
    opt_plus = result.find { |t| t[0] == "opt_plus" }
    refute_nil opt_plus, "expected opt_plus in serialized output"
    cd = opt_plus[1]
    assert_kind_of Hash, cd
    assert_equal "+", cd["mid"]
    assert_equal 1, cd["argc"]
    assert_kind_of Integer, cd["flag"]
    assert_equal 0, cd["kwlen"]
  end

  def test_serialize_leave_has_no_operands
    result = serialize_answer
    leave = result.find { |t| t[0] == "leave" }
    refute_nil leave
    assert_equal ["leave"], leave
  end

  def test_round_trip_preserves_opcode_sequence
    fn, ot = decode_method(FIXTURE, :answer)
    json = Optimize::Demo::Claude::Serializer.serialize(fn, object_table: ot)
    restored = Optimize::Demo::Claude::Serializer.deserialize(json, template: fn, object_table: ot)
    assert_equal fn.instructions.map(&:opcode), restored.instructions.map(&:opcode)
  end

  def test_round_trip_call_data
    fn, ot = decode_method(FIXTURE, :answer)
    json = Optimize::Demo::Claude::Serializer.serialize(fn, object_table: ot)
    restored = Optimize::Demo::Claude::Serializer.deserialize(json, template: fn, object_table: ot)
    opt_plus = restored.instructions.find { |i| i.opcode == :opt_plus }
    refute_nil opt_plus
    cd = opt_plus.operands[0]
    assert_kind_of Optimize::IR::CallData, cd
    assert_equal 1, cd.argc
    assert_equal :+, cd.mid_symbol(ot)
  end

  def test_round_trip_preserves_template_metadata
    fn, ot = decode_method(FIXTURE, :answer)
    json = Optimize::Demo::Claude::Serializer.serialize(fn, object_table: ot)
    restored = Optimize::Demo::Claude::Serializer.deserialize(json, template: fn, object_table: ot)
    assert_equal fn.name, restored.name
    assert_same fn.local_table, restored.local_table
    assert_same fn.catch_entries, restored.catch_entries
    assert_same fn.arg_positions, restored.arg_positions
    refute_same fn.instructions, restored.instructions
  end

  def test_strict_raises_on_unknown_opcode
    fn, ot = decode_method(FIXTURE, :answer)
    json = [["opt_fastmath"], ["leave"]]
    err = assert_raises(Optimize::Demo::Claude::Serializer::DeserializeError) do
      Optimize::Demo::Claude::Serializer.deserialize(json, template: fn, object_table: ot, strict: true)
    end
    assert_includes err.message, "opt_fastmath"
  end

  def test_lax_tolerates_unknown_opcode
    fn, ot = decode_method(FIXTURE, :answer)
    json = [["opt_fastmath"], ["leave"]]
    restored = Optimize::Demo::Claude::Serializer.deserialize(json, template: fn, object_table: ot, strict: false)
    assert_equal [:opt_fastmath, :leave], restored.instructions.map(&:opcode)
  end

  def test_round_trip_integer_literal_value_operand
    fn, ot = decode_method(FIXTURE, :answer)
    json = [["putobject", 42], ["leave"]]
    restored = Optimize::Demo::Claude::Serializer.deserialize(json, template: fn, object_table: ot)
    insn = restored.instructions[0]
    assert_equal :putobject, insn.opcode
    idx = insn.operands[0]
    assert_kind_of Integer, idx
    assert_equal 42, ot.resolve(idx)
  end

  def test_deserialize_rejects_unsupported_value_kind
    fn, ot = decode_method(FIXTURE, :answer)
    json = [["putobject", { "weird" => "object" }], ["leave"]]
    assert_raises(Optimize::Demo::Claude::Serializer::DeserializeError) do
      Optimize::Demo::Claude::Serializer.deserialize(json, template: fn, object_table: ot)
    end
  end
end
