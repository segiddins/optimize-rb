# frozen_string_literal: true

# Smoke test: compile `1 + 2` and print the disasm.
# Run from experiments/: `bundle exec ruby 01-iseq-basics/hello.rb`

require_relative "../lib/disasm_helper"

puts "Ruby: #{RUBY_VERSION}"
puts
puts DisasmHelper.deep_disasm("1 + 2")
