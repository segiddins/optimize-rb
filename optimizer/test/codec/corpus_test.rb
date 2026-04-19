# frozen_string_literal: true
require "test_helper"
require "ruby_opt/codec"

class CorpusTest < Minitest::Test
  Dir[File.join(__dir__, "corpus", "*.rb")].each do |path|
    name = File.basename(path, ".rb")
    define_method(:"test_corpus_#{name}") do
      source = File.read(path)
      original = RubyVM::InstructionSequence.compile(source, path).to_binary
      ir = RubyOpt::Codec.decode(original)
      re_encoded = RubyOpt::Codec.encode(ir)
      assert_equal original, re_encoded, "mismatch for #{name}"
      # Must also still run
      RubyVM::InstructionSequence.load_from_binary(re_encoded).eval
    end
  end

  # Error-path tests: malformed input must fail loudly with specific exceptions

  def test_malformed_binary_raises_on_wrong_magic
    # Binary with wrong magic bytes
    bad_magic = "NOTYARB!".b + "\x00" * 100
    assert_raises(RubyOpt::Codec::MalformedBinary) do
      RubyOpt::Codec.decode(bad_magic)
    end
  end

  def test_malformed_binary_message_includes_actual_bytes
    # Verify the error message includes the actual bytes found
    bad_magic = "TEST".b + "\x00" * 100
    begin
      RubyOpt::Codec.decode(bad_magic)
      flunk("expected MalformedBinary to be raised")
    rescue RubyOpt::Codec::MalformedBinary => e
      assert_match(/TEST/, e.message, "error message should include actual bytes")
    end
  end

  def test_malformed_binary_raises_on_truncated_header
    # Real YARB prefix, but truncated — decode should fail
    bin = RubyVM::InstructionSequence.compile("1").to_binary
    truncated = bin.byteslice(0, 8)  # magic + 4 bytes, incomplete
    assert_raises(StandardError) do
      RubyOpt::Codec.decode(truncated)
    end
  end
end
