# frozen_string_literal: true

require "open3"

module RubyBytecodeMcp
  module DockerRunner
    module_function

    # Build a `docker run` command array for inline Ruby code.
    # `-e` is used so no host filesystem is mounted.
    def command_for_inline(code:, ruby_version: DEFAULT_RUBY_VERSION, timeout_s: DEFAULT_TIMEOUT_S, network: false)
      image = "#{DEFAULT_IMAGE_PREFIX}:#{ruby_version}#{DEFAULT_IMAGE_SUFFIX}"
      net_flag = network ? "--network=bridge" : "--network=none"
      [
        "docker", "run", "--rm", "-i",
        net_flag,
        "--memory=512m",
        "--cpus=1",
        image,
        "timeout", timeout_s.to_s,
        "ruby", "-e", code,
      ]
    end

    # Execute inline Ruby code in a container.
    # Returns {stdout:, stderr:, exit_code:, duration_ms:}.
    def run_inline(code:, ruby_version: DEFAULT_RUBY_VERSION, timeout_s: DEFAULT_TIMEOUT_S, stdin: nil, network: false)
      cmd = command_for_inline(
        code: code, ruby_version: ruby_version, timeout_s: timeout_s, network: network,
      )
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      stdout, stderr, status = Open3.capture3(*cmd, stdin_data: stdin || "")
      duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).to_i
      {
        stdout: stdout,
        stderr: stderr,
        exit_code: status.exitstatus || -1,
        duration_ms: duration_ms,
      }
    rescue Errno::ENOENT => e
      {
        stdout: "",
        stderr: "docker not found on PATH: #{e.message}",
        exit_code: 127,
        duration_ms: 0,
      }
    end
  end
end
