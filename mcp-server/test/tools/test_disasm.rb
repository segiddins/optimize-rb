# frozen_string_literal: true

require_relative "../test_helper"

class TestDisasm < Minitest::Test
  include TestHelper

  def test_disasm_of_addition_mentions_opt_plus
    skip_without_docker!
    response = RubyBytecodeMcp::Tools::Disasm.call(
      code: "1 + 2",
      server_context: nil,
    )
    text = response.content.first[:text]
    assert_match(/putobject\s+1/, text)
    assert_match(/putobject\s+2/, text)
    assert_match(/opt_plus/, text)
  end
end
