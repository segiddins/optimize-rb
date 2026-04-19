# frozen_string_literal: true

require "json"

module RubyBytecodeMcp
  module Tools
    class RunRuby < MCP::Tool
      description "Run arbitrary Ruby code inside a sandboxed Docker container."
      input_schema(
        properties: {
          code: { type: "string", description: "Ruby source to execute." },
          ruby_version: { type: "string", description: "Ruby version tag, e.g. 4.0.2." },
          stdin: { type: "string", description: "Data piped to STDIN." },
          timeout_s: { type: "integer", description: "Container timeout in seconds." },
        },
        required: ["code"],
      )

      class << self
        def call(code:, server_context:, ruby_version: RubyBytecodeMcp::DEFAULT_RUBY_VERSION, stdin: nil, timeout_s: RubyBytecodeMcp::DEFAULT_TIMEOUT_S)
          result = DockerRunner.run_inline(
            code: code, ruby_version: ruby_version, stdin: stdin, timeout_s: timeout_s,
          )
          MCP::Tool::Response.new([{ type: "text", text: JSON.pretty_generate(result) }])
        end
      end
    end
  end
end
