# frozen_string_literal: true
require "test_helper"
require "ruby_opt/demo/claude/serializer"

class SerializerTest < Minitest::Test
  FIXTURE = <<~RUBY
    def answer
      2 + 3
    end
  RUBY

  def decode_method(source, method_name)
    iseq = RubyVM::InstructionSequence.compile(source)
    root = RubyOpt::Codec.decode(iseq.to_binary)
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
    RubyOpt::Demo::Claude::Serializer.serialize(fn, object_table: ot)
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
end
