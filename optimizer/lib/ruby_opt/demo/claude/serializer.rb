# frozen_string_literal: true
require "ruby_opt/codec/instruction_stream"
require "ruby_opt/ir/instruction"
require "ruby_opt/ir/call_data"

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
        class DeserializeError < StandardError; end

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

        # Inverse of serialize. Reconstructs an IR::Function whose instructions
        # mirror +json+ (an Array of [opcode_string, *operands] tuples). All
        # other Function fields are shallow-copied from +template+ — this is
        # the "gag pass" boundary: Claude only gets to rewrite the instruction
        # stream, never the iseq envelope.
        #
        # @param json         [Array<Array>]
        # @param template     [IR::Function]
        # @param object_table [Codec::ObjectTable]
        # @param strict       [Boolean] when true, raise on unknown opcodes
        # @return [IR::Function]
        def deserialize(json, template:, object_table:, strict: false)
          rebuilt = json.map do |tuple|
            opcode_str, *operands = tuple
            opcode = opcode_str.to_sym
            op_types = OPCODE_OPERAND_TYPES[opcode]
            if op_types.nil?
              if strict
                raise DeserializeError, "unknown opcode #{opcode_str.inspect}"
              end
              # Lax: keep operands as-is without type-directed rebuild.
              IR::Instruction.new(opcode: opcode, operands: operands, line: nil)
            else
              rebuilt_operands = operands.each_with_index.map do |operand, i|
                deserialize_operand(op_types[i], operand, object_table)
              end
              IR::Instruction.new(opcode: opcode, operands: rebuilt_operands, line: nil)
            end
          end

          new_fn = template.dup
          new_fn.instructions = rebuilt
          new_fn
        end

        def deserialize_operand(op_type, operand, object_table)
          case op_type
          when :VALUE, :ID
            intern_value(operand, object_table)
          when :CALLDATA
            unless operand.is_a?(Hash)
              raise DeserializeError, "expected Hash for CALLDATA, got #{operand.inspect}"
            end
            mid_str = operand["mid"]
            unless mid_str.is_a?(String)
              raise DeserializeError, "CALLDATA 'mid' must be a String, got #{mid_str.inspect}"
            end
            mid_idx =
              begin
                object_table.intern(mid_str.to_sym)
              rescue ArgumentError => e
                raise DeserializeError, "cannot intern calldata mid #{mid_str.inspect}: #{e.message}"
              end
            IR::CallData.new(
              mid_idx: mid_idx,
              flag: operand["flag"],
              argc: operand["argc"],
              kwlen: operand["kwlen"] || 0,
              kw_indices: [],
            )
          when :OFFSET, :LINDEX, :NUM, :ISE, :IVC, :ICVARC, :IC, :CDHASH, :ISEQ
            operand
          when :BUILTIN
            unless operand.is_a?(Array) && operand[0] == "__builtin__"
              raise DeserializeError, "expected [\"__builtin__\", idx, name_bytes] for BUILTIN, got #{operand.inspect}"
            end
            _tag, idx, name_bytes = operand
            [idx, name_bytes.bytesize, name_bytes]
          else
            raise DeserializeError, "unknown operand type #{op_type.inspect}"
          end
        end

        def intern_value(value, object_table)
          case value
          when Integer, TrueClass, FalseClass, NilClass, String
            object_table.intern(value)
          else
            raise DeserializeError,
              "unsupported VALUE/ID operand #{value.inspect}; only Integer/true/false/nil/String are internable in v1"
          end
        rescue ArgumentError => e
          raise DeserializeError, "cannot intern value #{value.inspect}: #{e.message}"
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
