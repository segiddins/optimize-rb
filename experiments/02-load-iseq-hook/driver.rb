# frozen_string_literal: true

# Install a load_iseq hook, then `require` target.rb. The method
# Greeter#greet ends up running bytecode WE handed to the VM, not
# bytecode MRI compiled from the source on disk.
#
# Run from experiments/: `bundle exec ruby 02-load-iseq-hook/driver.rb`

TARGET_BASENAME = "target.rb"

# TODO (you): implement the rewrite.
#
# You get the original source string and the absolute path. Return the
# source string that should be compiled in its place. The trade-off to
# think about:
#
#   - source-level rewrite (what this harness does): easy, portable,
#     but you're really just re-running the parser. The "bytecode" angle
#     is a lie — MRI compiles your new source normally.
#
#   - AST-level rewrite via Prism + re-emit: still ends in `compile`,
#     but lets you reason about structure, not strings.
#
#   - binary-level: compile once, `to_binary`, patch the blob,
#     `load_from_binary`. Version-locked and brittle, but it's the only
#     path where you actually touch bytecode.
#
# For a first pass, pick a small visible change you can assert on — e.g.
# swap "hi," for "HELLO,", or change the method to memoize, or inject a
# `puts` at entry. Keep it to ~5 lines.
def rewrite_source(src, path)
  raise NotImplementedError, "implement rewrite_source in driver.rb"
end

class << RubyVM::InstructionSequence
  def load_iseq(path)
    return nil unless path.end_with?("/#{TARGET_BASENAME}")

    original = File.read(path)
    rewritten = rewrite_source(original, path)

    warn "[load_iseq] intercepted #{File.basename(path)} " \
         "(#{original.bytesize}B → #{rewritten.bytesize}B)"

    RubyVM::InstructionSequence.compile(rewritten, path, path)
  end
end

require_relative "target"

greeter = Greeter.new
puts greeter.greet("world", 2)
puts
puts "--- disasm of Greeter#greet ---"
puts RubyVM::InstructionSequence.of(Greeter.instance_method(:greet)).disasm
