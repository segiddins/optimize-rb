# frozen_string_literal: true
require "test_helper"
require "optimize/codec"

class CodecSmokeTest < Minitest::Test
  def test_decode_encode_execute
    src = <<~RUBY
      def add(a, b); a + b; end
      def greet(name); "hello, \#{name}"; end
      add(2, 3) + greet("world").length
    RUBY
    original = RubyVM::InstructionSequence.compile(src).to_binary
    ir = Optimize::Codec.decode(original)
    re_encoded = Optimize::Codec.encode(ir)

    loaded = RubyVM::InstructionSequence.load_from_binary(re_encoded)
    result = loaded.eval
    # add(2,3) == 5, "hello, world".length == 12, total == 17
    assert_equal 17, result
  end
end
