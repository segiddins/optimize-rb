# frozen_string_literal: true
require "ruby_opt/demo"

module RubyOpt
  module Demo
    module DisasmNormalizer
      HEADER_RE   = /\A==\s+disasm:\s+#<ISeq:(?<label>[^>]+)>/
      DROPPED_RE  = /\A(?:local table|\(catch table|\|\s|\s*$)/
      PC_RE       = /\A\d{4}\s+/
      SUFFIX_RE   = /\s*\(\s*\d+\)\[[A-Za-z]+\]\s*\z/

      module_function

      def normalize(raw)
        out = []
        first_header = true
        raw.each_line do |line|
          line = line.chomp
          if (m = line.match(HEADER_RE))
            if first_header
              first_header = false
              next
            else
              out << "== block: #{m[:label]}"
              next
            end
          end
          next if DROPPED_RE.match?(line)
          stripped = line.sub(PC_RE, "").sub(SUFFIX_RE, "").rstrip
          next if stripped.empty?
          out << stripped
        end
        out.join("\n") + "\n"
      end
    end
  end
end
