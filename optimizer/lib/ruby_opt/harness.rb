# frozen_string_literal: true

module RubyOpt
  module Harness
    OPT_OUT_RE = /\A#\s*rbs-optimize\s*:\s*false\s*\z/

    module_function

    # Whether the source file has opted out of optimization. Scans the
    # first 5 lines for a `# rbs-optimize: false` directive.
    def opted_out?(source)
      source.each_line.first(5).any? { |line| OPT_OUT_RE.match?(line.chomp) }
    end
  end
end
