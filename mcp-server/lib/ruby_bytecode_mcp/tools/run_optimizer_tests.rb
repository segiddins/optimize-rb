# frozen_string_literal: true

require "json"

module RubyBytecodeMcp
  module Tools
    class RunOptimizerTests < MCP::Tool
      description "Run the optimizer project's test suite inside a Docker container. Mounts the optimizer/ directory read-write so bundle install can cache gems under optimizer/vendor/bundle."
      input_schema(
        properties: {
          test_filter: {
            type: "string",
            description: "Optional TEST= filter passed to rake (e.g. test/codec/round_trip_test.rb).",
          },
          ruby_version: {
            type: "string",
            description: "Ruby version tag, e.g. 4.0.2.",
          },
          timeout_s: {
            type: "integer",
            description: "Container timeout in seconds. Default 300; bundle install on a cold cache can take minutes.",
          },
        },
      )

      DEFAULT_TIMEOUT_S = 300

      class << self
        def call(server_context:, test_filter: nil, ruby_version: RubyBytecodeMcp::DEFAULT_RUBY_VERSION, timeout_s: DEFAULT_TIMEOUT_S)
          repo_root = ENV["RUBY_BYTECODE_REPO_ROOT"]
          unless repo_root && !repo_root.empty?
            return error_response("RUBY_BYTECODE_REPO_ROOT is not set; the MCP wrapper must export it")
          end

          optimizer_dir = File.join(repo_root, "optimizer")
          unless File.directory?(optimizer_dir)
            return error_response("optimizer/ directory not found at #{optimizer_dir}")
          end

          rake_args = ["bundle", "exec", "rake", "test"]
          rake_args << "TEST=#{test_filter}" if test_filter && !test_filter.empty?

          script = [
            "set -e",
            "bundle config set --local path vendor/bundle",
            "bundle install --quiet",
            rake_args.map { |a| shellesc(a) }.join(" "),
          ].join(" && ")

          result = DockerRunner.run_in_dir(
            host_dir: optimizer_dir,
            command: ["bash", "-c", script],
            ruby_version: ruby_version,
            timeout_s: timeout_s,
            network: true,
          )

          MCP::Tool::Response.new([{ type: "text", text: JSON.pretty_generate(result) }])
        end

        private

        def shellesc(s)
          %("#{s.gsub('"', '\\"')}")
        end

        def error_response(message)
          MCP::Tool::Response.new([{
            type: "text",
            text: JSON.pretty_generate({ stdout: "", stderr: message, exit_code: -1, duration_ms: 0 }),
          }])
        end
      end
    end
  end
end
