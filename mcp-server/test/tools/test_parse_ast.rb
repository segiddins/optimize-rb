# frozen_string_literal: true

require_relative "../test_helper"

class TestParseAst < Minitest::Test
  include TestHelper

  def test_prism_parse_returns_non_empty
    skip_without_docker!
    response = RubyBytecodeMcp::Tools::ParseAst.call(
      code: "1 + 2",
      server_context: nil,
    )
    text = response.content.first[:text]
    refute_empty text
    assert_match(/CallNode|ProgramNode|@/, text)
  end

  def test_ruby_vm_parser
    skip_without_docker!
    response = RubyBytecodeMcp::Tools::ParseAst.call(
      code: "1 + 2",
      parser: "ruby_vm",
      server_context: nil,
    )
    text = response.content.first[:text]
    assert_match(/SCOPE|OPCALL|:\+/, text)
  end
end
