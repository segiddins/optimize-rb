# frozen_string_literal: true
require "ruby_opt/codec/instruction_stream"

module RubyOpt
  module Demo
    module Claude
      # Serialize an IR::Function's instruction stream into a JSON-ready
      # Array of [opcode_string, *operands] tuples. VALUE/ID operands are
      # resolved through the object table so the output is self-describing
      # (no bare table indices). CALLDATA is expanded to a Hash.
      #
      # Intended for round-tripping through an LLM ("gag pass"); the
      # inverse is Serializer.deserialize (Task 3).
      module Serializer
        module_function

        # opcode_name (Symbol) => Array<operand_type (Symbol)>
        OPCODE_OPERAND_TYPES = Codec::InstructionStream::OPCODE_TO_INFO
          .each_with_object({}) { |(_num, (name, ops)), h| h[name] = ops }
          .freeze

        # @param function     [IR::Function]
        # @param object_table [Codec::ObjectTable]
        # @return [Array<Array>] each entry is [opcode_string, *operands]
        def serialize(function, object_table:)
          function.instructions.map do |insn|
            op_types = OPCODE_OPERAND_TYPES.fetch(insn.opcode) do
              raise ArgumentError, "unknown opcode #{insn.opcode.inspect}"
            end
            operands = insn.operands.each_with_index.map do |operand, i|
              serialize_operand(op_types[i], operand, object_table)
            end
            [insn.opcode.to_s, *operands]
          end
        end

        def serialize_operand(op_type, operand, object_table)
          case op_type
          when :VALUE, :ID
            serialize_value(object_table.resolve(operand))
          when :CALLDATA
            {
              "mid"   => operand.mid_symbol(object_table).to_s,
              "argc"  => operand.argc,
              "flag"  => operand.flag,
              "kwlen" => operand.kwlen,
            }
          when :OFFSET, :LINDEX, :NUM, :ISE, :IVC, :ICVARC, :IC, :CDHASH, :ISEQ
            operand
          when :BUILTIN
            idx, _name_len, name_bytes = operand
            ["__builtin__", idx, name_bytes]
          else
            raise ArgumentError, "unknown operand type #{op_type.inspect}"
          end
        end

        def serialize_value(value)
          case value
          when Integer, TrueClass, FalseClass, NilClass, String
            value
          when Symbol
            value.to_s
          else
            value.inspect
          end
        end
      end
    end
  end
end
