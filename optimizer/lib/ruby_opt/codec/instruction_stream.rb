# frozen_string_literal: true

require "ruby_opt/ir/instruction"
require "ruby_opt/codec/binary_reader"
require "ruby_opt/codec/binary_writer"

module RubyOpt
  module Codec
    module InstructionStream
      # Raised when an unknown opcode is encountered in the bytecode stream.
      class UnsupportedOpcode < StandardError
        attr_reader :opcode_num, :offset

        def initialize(opcode_num, offset)
          @opcode_num = opcode_num
          @offset     = offset
          super("Unsupported opcode #{opcode_num} at byte offset #{offset}")
        end
      end

      # Operand type sentinels used in INSN_TABLE below.
      # Each symbol maps to how many small_values are read/written in the bytecode stream:
      #
      #   :VALUE    -> 1 small_value  (object-table index)
      #   :CDHASH   -> 1 small_value  (object-table index of a frozen Hash)
      #   :ISEQ     -> 1 small_value  (iseq-list index; 0xFFFFFFFF = nil)
      #   :LINDEX   -> 1 small_value  (local variable index)
      #   :NUM      -> 1 small_value  (raw numeric value)
      #   :OFFSET   -> 1 small_value  (branch target slot offset, raw value)
      #   :ID       -> 1 small_value  (object-table index for a Symbol/ID)
      #   :ISE      -> 1 small_value  (inline-storage entry index)
      #   :IVC      -> 1 small_value  (inline variable cache index)
      #   :ICVARC   -> 1 small_value  (inline class-variable ref cache index)
      #   :IC       -> 1 small_value  (inline constant cache index)
      #   :CALLDATA -> 0 small_values (NOT stored in bytecode; tracked via ci_index)
      #   :BUILTIN  -> special        (small_value index + small_value len + len bytes)
      #
      # Sources: research/cruby/ibf-format.md §5, insns.def (CRuby v4.0.2),
      # and empirical verification against RubyVM::InstructionSequence#to_binary.

      # Maps opcode number -> [name_sym, operand_type_list].
      # Covers all non-trace, non-zjit opcodes for CRuby 4.0.2 (opcodes 0–108).
      # Trace variants (109–217) and zjit variants (218–247) use the same operand
      # shapes as their base opcodes and are added programmatically at the bottom.
      INSN_TABLE = {
        0   => [:nop,                          []],
        1   => [:getlocal,                     [:LINDEX, :NUM]],
        2   => [:setlocal,                     [:LINDEX, :NUM]],
        3   => [:getblockparam,                [:LINDEX, :NUM]],
        4   => [:setblockparam,                [:LINDEX, :NUM]],
        5   => [:getblockparamproxy,           [:LINDEX, :NUM]],
        6   => [:getspecial,                   [:NUM, :NUM]],
        7   => [:setspecial,                   [:NUM]],
        8   => [:getinstancevariable,          [:ID, :ISE]],
        9   => [:setinstancevariable,          [:ID, :ISE]],
        10  => [:getclassvariable,             [:ID, :IC]],
        11  => [:setclassvariable,             [:ID, :IC]],
        12  => [:opt_getconstant_path,         [:VALUE]],
        13  => [:getconstant,                  [:ID]],
        14  => [:setconstant,                  [:ID]],
        15  => [:getglobal,                    [:ID]],
        16  => [:setglobal,                    [:ID]],
        17  => [:putnil,                       []],
        18  => [:putself,                      []],
        19  => [:putobject,                    [:VALUE]],
        20  => [:putspecialobject,             [:NUM]],
        21  => [:putstring,                    [:VALUE]],
        22  => [:putchilledstring,             [:VALUE]],
        23  => [:concatstrings,                [:NUM]],
        24  => [:anytostring,                  [:NUM]],
        25  => [:toregexp,                     [:NUM, :NUM]],
        26  => [:intern,                       []],
        27  => [:newarray,                     [:NUM]],
        28  => [:pushtoarraykwsplat,           []],
        29  => [:duparray,                     [:VALUE]],
        30  => [:duphash,                      [:VALUE]],
        31  => [:expandarray,                  [:NUM, :NUM]],
        32  => [:concatarray,                  []],
        33  => [:concattoarray,                []],
        34  => [:pushtoarray,                  []],
        35  => [:splatarray,                   [:NUM]],
        36  => [:splatkw,                      []],
        37  => [:newhash,                      [:NUM]],
        38  => [:newrange,                     [:NUM]],
        39  => [:pop,                          []],
        40  => [:dup,                          []],
        41  => [:dupn,                         [:NUM]],
        42  => [:swap,                         []],
        43  => [:opt_reverse,                  [:NUM]],
        44  => [:topn,                         [:NUM]],
        45  => [:setn,                         [:NUM]],
        46  => [:adjuststack,                  [:NUM]],
        47  => [:defined,                      [:NUM, :ID, :VALUE]],
        48  => [:definedivar,                  [:ID, :ISE]],
        49  => [:checkmatch,                   [:NUM]],
        50  => [:checkkeyword,                 [:NUM, :NUM]],
        51  => [:checktype,                    [:NUM]],
        52  => [:defineclass,                  [:ID, :ISEQ, :NUM]],
        53  => [:definemethod,                 [:ID, :ISEQ]],
        54  => [:definesmethod,                [:ID, :ISEQ]],
        55  => [:send,                         [:CALLDATA, :ISEQ]],
        56  => [:sendforward,                  [:CALLDATA, :ISEQ]],
        57  => [:opt_send_without_block,       [:CALLDATA]],
        58  => [:opt_new,                      [:CALLDATA, :ISEQ]],
        59  => [:objtostring,                  [:CALLDATA]],
        60  => [:opt_ary_freeze,               [:VALUE, :CALLDATA]],
        61  => [:opt_hash_freeze,              [:VALUE, :CALLDATA]],
        62  => [:opt_str_freeze,               [:VALUE, :CALLDATA]],
        63  => [:opt_nil_p,                    [:CALLDATA]],
        64  => [:opt_str_uminus,               [:VALUE, :CALLDATA]],
        65  => [:opt_duparray_send,            [:VALUE, :CALLDATA, :ISEQ]],
        66  => [:opt_newarray_send,            [:NUM, :CALLDATA]],
        67  => [:invokesuper,                  [:CALLDATA, :ISEQ, :NUM]],
        68  => [:invokesuperforward,           [:CALLDATA, :ISEQ, :NUM]],
        69  => [:invokeblock,                  [:CALLDATA, :NUM]],
        70  => [:leave,                        []],
        71  => [:throw,                        [:NUM]],
        72  => [:jump,                         [:OFFSET]],
        73  => [:branchif,                     [:OFFSET]],
        74  => [:branchunless,                 [:OFFSET]],
        75  => [:branchnil,                    [:OFFSET]],
        76  => [:once,                         [:ISEQ, :ISE]],
        77  => [:opt_case_dispatch,            [:CDHASH, :OFFSET]],
        78  => [:opt_plus,                     [:CALLDATA]],
        79  => [:opt_minus,                    [:CALLDATA]],
        80  => [:opt_mult,                     [:CALLDATA]],
        81  => [:opt_div,                      [:CALLDATA]],
        82  => [:opt_mod,                      [:CALLDATA]],
        83  => [:opt_eq,                       [:CALLDATA]],
        84  => [:opt_neq,                      [:CALLDATA, :CALLDATA]],
        85  => [:opt_lt,                       [:CALLDATA]],
        86  => [:opt_le,                       [:CALLDATA]],
        87  => [:opt_gt,                       [:CALLDATA]],
        88  => [:opt_ge,                       [:CALLDATA]],
        89  => [:opt_ltlt,                     [:CALLDATA]],
        90  => [:opt_and,                      [:CALLDATA]],
        91  => [:opt_or,                       [:CALLDATA]],
        92  => [:opt_aref,                     [:CALLDATA]],
        93  => [:opt_aset,                     [:CALLDATA, :CALLDATA]],
        94  => [:opt_length,                   [:CALLDATA]],
        95  => [:opt_size,                     [:CALLDATA]],
        96  => [:opt_empty_p,                  [:CALLDATA]],
        97  => [:opt_succ,                     [:CALLDATA]],
        98  => [:opt_not,                      [:CALLDATA]],
        99  => [:opt_regexpmatch2,             [:CALLDATA]],
        100 => [:invokebuiltin,                [:BUILTIN]],
        101 => [:opt_invokebuiltin_delegate,   [:BUILTIN, :NUM]],
        102 => [:opt_invokebuiltin_delegate_leave, [:BUILTIN, :NUM]],
        103 => [:getlocal_WC_0,               [:LINDEX]],
        104 => [:getlocal_WC_1,               [:LINDEX]],
        105 => [:setlocal_WC_0,               [:LINDEX]],
        106 => [:setlocal_WC_1,               [:LINDEX]],
        107 => [:putobject_INT2FIX_0_,        []],
        108 => [:putobject_INT2FIX_1_,        []],
      }.freeze

      # Number of base (non-trace, non-zjit) opcodes.
      BASE_OPCODE_COUNT = 109

      # Trace variants (109–217) have the same operand shapes as their base counterparts (0–108).
      # zjit variants (218–247) also mirror base opcodes starting from 8 (getinstancevariable).
      # We build a combined lookup hash for decode.
      OPCODE_TO_INFO = begin
        table = {}
        INSN_TABLE.each { |num, (name, ops)| table[num] = [name, ops] }

        # Trace variants: trace_X at num+109 mirrors base X at num (opcodes 0..108).
        INSN_TABLE.each do |base_num, (base_name, ops)|
          trace_num = base_num + BASE_OPCODE_COUNT
          trace_name = :"trace_#{base_name}"
          table[trace_num] = [trace_name, ops]
        end

        # zjit variants: zjit_X starts at 218 and mirrors a subset of base opcodes.
        # From RubyVM::INSTRUCTION_NAMES (Ruby 4.0.2), zjit starts at 218 with
        # zjit_getinstancevariable (base 8), zjit_setinstancevariable (9), etc.
        ZJIT_BASE_OPCODES = [8, 9, 48, 55, 57, 59, 63, 69, 78, 79, 80, 81, 82, 83, 84,
                             85, 86, 87, 88, 89, 90, 91, 92, 93, 94, 95, 96, 97, 98, 99]
        zjit_num = 218
        ZJIT_BASE_OPCODES.each do |base_num|
          base_name, ops = INSN_TABLE[base_num]
          next unless base_name
          zjit_name = :"zjit_#{base_name}"
          table[zjit_num] = [zjit_name, ops]
          zjit_num += 1
        end

        table.freeze
      end

      # Maps name symbol -> opcode number (for encode).
      NAME_TO_OPCODE = OPCODE_TO_INFO.transform_values { |name, _ops| name }
                                      .invert
                                      .tap { |h| OPCODE_TO_INFO.each { |num, (name, _)| h[name] = num } }
                                      .freeze

      # Decode +bytes+ (a binary String) into an Array<IR::Instruction>.
      #
      # @param bytes        [String]        raw bytecode bytes (ASCII-8BIT)
      # @param object_table [ObjectTable]   decoded global object table (for index resolution)
      # @param iseqs        [Array]         iseq-list array (for TS_ISEQ resolution)
      # @return [Array<IR::Instruction>]
      def self.decode(bytes, object_table, iseqs)
        reader = BinaryReader.new(bytes)
        instructions = []

        while reader.pos < bytes.bytesize
          opcode_offset = reader.pos
          opcode_num = reader.read_small_value

          info = OPCODE_TO_INFO[opcode_num]
          raise UnsupportedOpcode.new(opcode_num, opcode_offset) unless info

          _name, op_types = info
          opcode_sym = info[0]

          operands = op_types.filter_map do |op_type|
            case op_type
            when :VALUE, :CDHASH, :ID, :ISEQ, :LINDEX, :NUM, :OFFSET, :ISE, :IVC, :ICVARC, :IC
              reader.read_small_value
            when :CALLDATA
              # TS_CALLDATA: nothing written in the bytecode stream.
              # We store nil to mark where a calldata slot would be,
              # but filter_map drops it (nil -> filtered out).
              nil
            when :BUILTIN
              # TS_BUILTIN: small_value index + small_value name_len + name bytes.
              idx = reader.read_small_value
              name_len = reader.read_small_value
              name_bytes = reader.read_bytes(name_len)
              [idx, name_len, name_bytes]
            else
              raise "Unknown operand type #{op_type.inspect} for opcode #{opcode_sym}"
            end
          end

          instructions << IR::Instruction.new(
            opcode:   opcode_sym,
            operands: operands,
            line:     nil,
          )
        end

        instructions
      end

      # Encode +instructions+ (Array<IR::Instruction>) back into a bytecode binary String.
      #
      # @param instructions [Array<IR::Instruction>]
      # @param object_table [ObjectTable]  (unused in current identity encoding, reserved)
      # @param iseqs        [Array]        (unused in current identity encoding, reserved)
      # @return [String] ASCII-8BIT bytecode bytes
      def self.encode(instructions, object_table, iseqs)
        writer = BinaryWriter.new

        instructions.each do |insn|
          opcode_num = NAME_TO_OPCODE[insn.opcode]
          raise "Unknown opcode name: #{insn.opcode.inspect}" unless opcode_num

          writer.write_small_value(opcode_num)

          _name, op_types = OPCODE_TO_INFO[opcode_num]
          operand_idx = 0

          op_types.each do |op_type|
            case op_type
            when :VALUE, :CDHASH, :ID, :ISEQ, :LINDEX, :NUM, :OFFSET, :ISE, :IVC, :ICVARC, :IC
              writer.write_small_value(insn.operands[operand_idx])
              operand_idx += 1
            when :CALLDATA
              # TS_CALLDATA: write nothing in the bytecode stream.
              # (No operand consumed from insn.operands either.)
            when :BUILTIN
              # TS_BUILTIN: stored as [idx, name_len, name_bytes] array.
              builtin = insn.operands[operand_idx]
              writer.write_small_value(builtin[0])
              writer.write_small_value(builtin[1])
              writer.write_bytes(builtin[2])
              operand_idx += 1
            else
              raise "Unknown operand type #{op_type.inspect} for opcode #{insn.opcode}"
            end
          end
        end

        writer.buffer
      end
    end
  end
end
