# frozen_string_literal: true
require "ruby_opt/demo/claude/serializer"
require "ruby_opt/codec"
require "ruby_opt/codec/stack_max"

module RubyOpt
  module Demo
    module Claude
      # Structural validator for IR::Function instruction streams coming back
      # from the "gag pass" (LLM rewrite). Checks that every instruction has
      # a known opcode and the arity matches the YARV operand schema.
      module Validator
        module_function

        # @param function [IR::Function]
        # @return [Array<String>] one human-readable error per problematic
        #   instruction; empty when the stream is structurally valid.
        def structural(function)
          errors = []
          function.instructions.each_with_index do |insn, idx|
            op_types = Serializer::OPCODE_OPERAND_TYPES[insn.opcode]
            if op_types.nil?
              errors << "instruction #{idx}: unknown opcode :#{insn.opcode}"
              next
            end
            expected = op_types.size
            actual = insn.operands.size
            if expected != actual
              errors << "instruction #{idx}: opcode :#{insn.opcode} expects #{expected} operand(s), got #{actual}"
            end
          end
          errors.concat(stack_discipline_errors(function)) if errors.empty?
          errors
        end

        # Catches stack-discipline violations that would otherwise trigger an
        # uncatchable VM [BUG] ("Stack consistency error"). Linear walk —
        # doesn't model control flow, so branch-heavy rewrites may slip
        # through; but the typical Claude shortcut (leaving an extra value on
        # the stack) is caught here.
        def stack_discipline_errors(function)
          insns = function.instructions
          return ["iseq is empty"] if insns.nil? || insns.empty?
          return ["iseq must end with :leave, got :#{insns.last.opcode}"] if insns.last.opcode != :leave

          depth = 0
          insns.each_with_index do |insn, idx|
            pop, push = Codec::StackMax.delta_for(insn)
            if depth < pop
              return ["instruction #{idx}: :#{insn.opcode} pops #{pop} but stack depth is #{depth}"]
            end
            depth = depth - pop + push
          end
          # After the last (:leave) instruction, depth should be zero. :leave
          # pops one, so depth just before the final :leave must have been 1.
          unless depth.zero?
            return ["final stack depth is #{depth}; must be 0 (i.e. exactly one value on the stack before :leave)"]
          end
          []
        end
        private_class_method :stack_discipline_errors

        # Encode the envelope, load it as an iseq, run it (which defines any
        # top-level methods), then evaluate each case in TOPLEVEL_BINDING and
        # compare against the expected value with ==.
        #
        # A rewrite must preserve behavior across every case, not just one —
        # otherwise Claude happily table-looks-up a single expected value
        # and calls it a day. Callers pass as many cases as are needed to
        # catch that shortcut (multiple inputs covering the domain of
        # interest).
        #
        # @param envelope [IR::Function] a root-level function (as returned
        #   by RubyOpt::Codec.decode) with any mutations already spliced in.
        # @param cases [Array<Array(String, Object)>] one or more
        #   [entry_source, expected] pairs. `entry_source` is evaluated in
        #   TOPLEVEL_BINDING after the iseq is loaded.
        # @return [Array<String>] empty on success; otherwise one error per
        #   failing case (plus at most one loader/runtime error if the iseq
        #   couldn't be loaded at all).
        def semantic(envelope, cases:)
          raise ArgumentError, "cases must not be empty" if cases.empty?

          run_cases(envelope, cases)
        end

        def run_cases(envelope, cases)
          binary = RubyOpt::Codec.encode(envelope)
          RubyVM::InstructionSequence.load_from_binary(binary).eval
          errors = []
          cases.each do |entry, expected|
            begin
              result = TOPLEVEL_BINDING.eval(entry)
              unless result == expected
                errors << "case `#{entry}` returned #{result.inspect}; expected #{expected.inspect}"
              end
            rescue => e
              errors << "case `#{entry}` raised #{e.class}: #{e.message}"
            end
          end
          errors
        rescue => e
          ["loader/runtime error: #{e.class}: #{e.message}"]
        end
        private_class_method :run_cases
      end
    end
  end
end
