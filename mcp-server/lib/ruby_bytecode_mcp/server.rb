# frozen_string_literal: true

require_relative "tools/run_ruby"
require_relative "tools/disasm"
require_relative "tools/parse_ast"
require_relative "tools/benchmark_ips"
require_relative "tools/iseq_to_binary"
require_relative "tools/load_iseq_binary"

module RubyBytecodeMcp
  TOOLS = [
    Tools::RunRuby,
    Tools::Disasm,
    Tools::ParseAst,
    Tools::BenchmarkIps,
    Tools::IseqToBinary,
    Tools::LoadIseqBinary,
  ].freeze

  def self.build_server
    MCP::Server.new(name: "ruby-bytecode", tools: TOOLS.dup)
  end
end
