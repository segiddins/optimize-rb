# frozen_string_literal: true

require "json"

module RubyBytecodeMcp
  module Tools
    class BenchmarkIps < MCP::Tool
      description "Run benchmark-ips over named Ruby scenarios in a container."
      input_schema(
        properties: {
          setup: { type: "string", description: "Code run once before benchmarking." },
          scenarios: {
            type: "array",
            items: {
              type: "object",
              properties: { name: { type: "string" }, code: { type: "string" } },
              required: ["name", "code"],
            },
          },
          warmup: { type: "integer" },
          time: { type: "integer" },
          ruby_version: { type: "string" },
        },
        required: ["scenarios"],
      )

      RUNNER = <<~'RUBY'
        require "json"
        unless Gem::Specification.find_all_by_name("benchmark-ips").any?
          Gem.install("benchmark-ips", "2.14.0")
        end
        require "benchmark/ips"

        payload = JSON.parse(STDIN.read)
        if payload["setup"] && !payload["setup"].empty?
          Kernel.send(:eval, payload["setup"])
        end

        Benchmark.ips do |x|
          x.config(warmup: payload["warmup"] || 2, time: payload["time"] || 5)
          payload["scenarios"].each do |s|
            x.report(s["name"]) { Kernel.send(:eval, s["code"]) }
          end
          x.compare!
        end
      RUBY

      class << self
        def call(scenarios:, server_context:, setup: nil, warmup: nil, time: nil, ruby_version: RubyBytecodeMcp::DEFAULT_RUBY_VERSION)
          payload = JSON.generate(
            "setup" => setup,
            "scenarios" => scenarios,
            "warmup" => warmup,
            "time" => time,
          )
          total_timeout = 10 + ((warmup || 2) + (time || 5)) * scenarios.length * 2
          result = DockerRunner.run_inline(
            code: RUNNER,
            ruby_version: ruby_version,
            stdin: payload,
            timeout_s: total_timeout,
            network: true,
          )
          text = result[:exit_code].zero? ? result[:stdout] : "ERROR (exit #{result[:exit_code]}):\n#{result[:stderr]}"
          MCP::Tool::Response.new([{ type: "text", text: text }])
        end
      end
    end
  end
end
