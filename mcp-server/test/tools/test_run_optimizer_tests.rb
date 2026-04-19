# frozen_string_literal: true

require_relative "../test_helper"
require "json"

class TestRunOptimizerTests < Minitest::Test
  include TestHelper

  def test_command_mounts_optimizer_dir_and_runs_rake
    cmd = RubyBytecodeMcp::DockerRunner.command_for_dir(
      host_dir: "/tmp/repo/optimizer",
      command: ["bash", "-c", "bundle exec rake test"],
      ruby_version: "4.0.2",
      timeout_s: 60,
      network: true,
    )
    assert_equal "docker", cmd.first
    assert_includes cmd, "--rm"
    assert_includes cmd, "--network=bridge"
    assert_includes cmd, "ruby:4.0.2-slim"
    assert_includes cmd, "-v"
    assert_includes cmd, "/tmp/repo/optimizer:/w"
    assert_includes cmd, "-w"
    assert_includes cmd, "/w"
  end

  def test_errors_when_repo_root_not_set
    original = ENV.delete("RUBY_BYTECODE_REPO_ROOT")
    response = RubyBytecodeMcp::Tools::RunOptimizerTests.call(server_context: nil)
    payload = JSON.parse(response.content.first[:text])
    assert_equal(-1, payload["exit_code"])
    assert_match(/RUBY_BYTECODE_REPO_ROOT/, payload["stderr"])
  ensure
    ENV["RUBY_BYTECODE_REPO_ROOT"] = original if original
  end

  def test_runs_optimizer_test_suite_end_to_end
    skip_without_docker!
    repo_root = File.expand_path("../../..", __dir__)
    skip "optimizer/ not present" unless File.directory?(File.join(repo_root, "optimizer"))

    ENV["RUBY_BYTECODE_REPO_ROOT"] = repo_root
    response = RubyBytecodeMcp::Tools::RunOptimizerTests.call(server_context: nil, timeout_s: 600)
    payload = JSON.parse(response.content.first[:text])
    # We don't assert exit_code==0 because round-trip tests intentionally fail
    # at this point in the plan. We only assert the harness actually ran rake.
    combined = (payload["stdout"].to_s + payload["stderr"].to_s)
    assert_match(/runs.*assertions/, combined, "expected rake test output, got: #{combined[0,500]}")
  end
end
