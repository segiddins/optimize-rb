# frozen_string_literal: true

module RubyBytecodeMcp
  module Tools
    class Disasm < MCP::Tool
      description "Compile Ruby code and return disassembly of the top-level iseq and all child iseqs."
      input_schema(
        properties: {
          code: { type: "string", description: "Ruby source to compile." },
          ruby_version: { type: "string", description: "Ruby version tag." },
        },
        required: ["code"],
      )

      RUNNER = <<~RUBY
        code = STDIN.read
        iseq = RubyVM::InstructionSequence.compile(code)
        out = [iseq.disasm]
        walk = ->(i) { i.each_child { |c| out << c.disasm; walk.call(c) } }
        walk.call(iseq)
        puts out.join("\n")
      RUBY

      class << self
        def call(code:, server_context:, ruby_version: RubyBytecodeMcp::DEFAULT_RUBY_VERSION)
          result = DockerRunner.run_inline(
            code: RUNNER, ruby_version: ruby_version, stdin: code,
          )
          text = result[:exit_code].zero? ? result[:stdout] : "ERROR (exit #{result[:exit_code]}):\n#{result[:stderr]}"
          MCP::Tool::Response.new([{ type: "text", text: text }])
        end
      end
    end
  end
end
