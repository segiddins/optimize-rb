# frozen_string_literal: true
require "test_helper"
require "ruby_opt/pass"
require "ruby_opt/log"
require "ruby_opt/codec"

class PassTest < Minitest::Test
  def test_noop_pass_does_not_change_instructions
    ir = RubyOpt::Codec.decode(
      RubyVM::InstructionSequence.compile("1 + 2").to_binary
    )
    f = ir.children.first # outer iseq
    before = f.instructions.map(&:opcode)
    log = RubyOpt::Log.new
    RubyOpt::NoopPass.new.apply(f, type_env: nil, log: log)
    after = f.instructions.map(&:opcode)
    assert_equal before, after
    assert_empty log.entries
  end

  def test_base_pass_apply_raises_not_implemented
    assert_raises(NotImplementedError) do
      RubyOpt::Pass.new.apply(nil, type_env: nil, log: nil)
    end
  end

  def test_pass_has_a_name
    assert_equal :noop, RubyOpt::NoopPass.new.name
  end
end
