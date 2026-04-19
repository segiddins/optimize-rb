# frozen_string_literal: true

require "json"

module RubyBytecodeMcp
  module Tools
    class IseqToBinary < MCP::Tool
      description "Compile Ruby code and return the base64-encoded iseq binary."
      input_schema(
        properties: {
          code: { type: "string" },
          ruby_version: { type: "string" },
        },
        required: ["code"],
      )

      RUNNER = <<~'RUBY'
        require "base64"
        require "json"
        bin = RubyVM::InstructionSequence.compile(STDIN.read).to_binary
        puts JSON.generate("blob_b64" => Base64.strict_encode64(bin), "size" => bin.bytesize)
      RUBY

      class << self
        def call(code:, server_context:, ruby_version: RubyBytecodeMcp::DEFAULT_RUBY_VERSION)
          result = DockerRunner.run_inline(code: RUNNER, ruby_version: ruby_version, stdin: code)
          text = result[:exit_code].zero? ? result[:stdout] : "ERROR (exit #{result[:exit_code]}):\n#{result[:stderr]}"
          MCP::Tool::Response.new([{ type: "text", text: text }])
        end
      end
    end
  end
end
