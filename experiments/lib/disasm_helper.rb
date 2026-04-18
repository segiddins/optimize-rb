# frozen_string_literal: true

module DisasmHelper
  # Returns the disassembly of +code+ including all nested iseqs.
  def self.deep_disasm(code)
    iseq = RubyVM::InstructionSequence.compile(code)
    [iseq.disasm, *each_child(iseq).map(&:disasm)].join("\n")
  end

  def self.each_child(iseq, &block)
    return enum_for(__method__, iseq) unless block_given?
    iseq.each_child do |child|
      yield child
      each_child(child, &block)
    end
  end
end
