# frozen_string_literal: true

module RubyBytecodeMcp
  module Tools
    class ParseAst < MCP::Tool
      description "Parse Ruby code and return the AST via Prism (default) or RubyVM::AbstractSyntaxTree."
      input_schema(
        properties: {
          code: { type: "string", description: "Ruby source to parse." },
          parser: { type: "string", enum: %w[prism ruby_vm], description: "Which parser to use." },
          ruby_version: { type: "string", description: "Ruby version tag." },
        },
        required: ["code"],
      )

      PRISM_RUNNER = <<~RUBY
        require "prism"
        puts Prism.parse(STDIN.read).value.inspect
      RUBY

      RUBY_VM_RUNNER = <<~RUBY
        puts RubyVM::AbstractSyntaxTree.parse(STDIN.read).inspect
      RUBY

      class << self
        def call(code:, server_context:, parser: "prism", ruby_version: RubyBytecodeMcp::DEFAULT_RUBY_VERSION)
          runner = parser == "ruby_vm" ? RUBY_VM_RUNNER : PRISM_RUNNER
          result = DockerRunner.run_inline(code: runner, ruby_version: ruby_version, stdin: code)
          text = result[:exit_code].zero? ? result[:stdout] : "ERROR (exit #{result[:exit_code]}):\n#{result[:stderr]}"
          MCP::Tool::Response.new([{ type: "text", text: text }])
        end
      end
    end
  end
end
