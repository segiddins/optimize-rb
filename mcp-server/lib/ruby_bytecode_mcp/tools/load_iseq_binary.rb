# frozen_string_literal: true

require "json"

module RubyBytecodeMcp
  module Tools
    class LoadIseqBinary < MCP::Tool
      description "Load a base64-encoded iseq binary; optionally run it and capture stdout/stderr."
      input_schema(
        properties: {
          blob_b64: { type: "string" },
          call: { type: "boolean", description: "If true, run the loaded iseq and return its output." },
          ruby_version: { type: "string" },
        },
        required: ["blob_b64"],
      )

      RUNNER = <<~'RUBY'
        require "base64"
        require "json"
        payload = JSON.parse(STDIN.read)
        bin = Base64.strict_decode64(payload["blob_b64"])
        iseq = RubyVM::InstructionSequence.load_from_binary(bin)
        if payload["call"]
          iseq.eval
        else
          puts iseq.disasm
        end
      RUBY

      class << self
        def call(blob_b64:, server_context:, call: false, ruby_version: RubyBytecodeMcp::DEFAULT_RUBY_VERSION)
          payload = JSON.generate("blob_b64" => blob_b64, "call" => call)
          result = DockerRunner.run_inline(code: RUNNER, ruby_version: ruby_version, stdin: payload)
          combined = [result[:stdout], result[:stderr]].reject(&:empty?).join("\n")
          text = result[:exit_code].zero? ? combined : "ERROR (exit #{result[:exit_code]}):\n#{combined}"
          MCP::Tool::Response.new([{ type: "text", text: text }])
        end
      end
    end
  end
end
