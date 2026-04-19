# frozen_string_literal: true

require_relative "../test_helper"

class TestRunRuby < Minitest::Test
  include TestHelper

  def test_returns_stdout_for_simple_program
    skip_without_docker!
    response = RubyBytecodeMcp::Tools::RunRuby.call(
      code: "puts 'hello'",
      server_context: nil,
    )
    text = response.content.first[:text]
    assert_match(/"exit_code": *0/, text)
    assert_match(/hello/, text)
  end
end
