# frozen_string_literal: true

require_relative "test_helper"

class TestDockerRunner < Minitest::Test
  include TestHelper

  def test_command_for_inline_code_pins_image_and_disables_network
    cmd = RubyBytecodeMcp::DockerRunner.command_for_inline(
      code: "puts :hi",
      ruby_version: "4.0.2",
      timeout_s: 5,
    )
    assert_equal "docker", cmd.first
    assert_includes cmd, "--rm"
    assert_includes cmd, "--network=none"
    assert_includes cmd, "ruby:4.0.2-slim"
    assert_includes cmd, "timeout"
    assert_includes cmd, "5"
    assert_includes cmd, "puts :hi"
  end

  def test_run_inline_returns_stdout_and_exit_code
    skip_without_docker!
    result = RubyBytecodeMcp::DockerRunner.run_inline(
      code: "puts RUBY_VERSION",
      ruby_version: "4.0.2",
    )
    assert_equal 0, result[:exit_code]
    assert_equal "4.0.2", result[:stdout].strip
    assert_equal "", result[:stderr]
  end
end
