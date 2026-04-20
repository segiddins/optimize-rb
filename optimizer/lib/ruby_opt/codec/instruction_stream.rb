# frozen_string_literal: true

require "ruby_opt/ir/instruction"
require "ruby_opt/codec/binary_reader"
require "ruby_opt/codec/binary_writer"
require "ruby_opt/codec"

module RubyOpt
  module Codec
    module InstructionStream

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
        24  => [:anytostring,                  []],
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

      # Returns the number of YARV slots an instruction of the given op_types occupies
      # (1 for the opcode itself + N for each operand slot). CALLDATA counts as 1
      # YARV slot even though it is not stored in the IBF binary. BUILTIN = 2 slots
      # (idx + name_len; the name bytes are embedded and don't count as YARV slots).
      # Convention: branch OFFSET operands are stored as instruction indices in IR;
      # they are YARV absolute slot indices in the binary.
      def self.slots_for(op_types)
        1 + op_types.sum do |op_type|
          case op_type
          when :BUILTIN then 2
          else               1  # :CALLDATA, :OFFSET, :VALUE, :NUM, etc. all = 1 slot
          end
        end
      end

      # Build a slot → IR::Instruction map from a decoded instruction list.
      # This reconstructs the mapping by walking instructions and computing slot sizes.
      #
      # @param instructions [Array<IR::Instruction>]
      # @return [Hash{Integer=>IR::Instruction}] YARV slot → instruction
      def self.slot_map(instructions)
        map = {}
        slot = 0
        instructions.each do |insn|
          opcode_num = NAME_TO_OPCODE[insn.opcode]
          raise "Unknown opcode name: #{insn.opcode.inspect}" unless opcode_num
          _name, op_types = OPCODE_TO_INFO[opcode_num]
          map[slot] = insn
          slot += slots_for(op_types)
        end
        map
      end

      # Build a slot → IR::Instruction map that covers every YARV slot within each
      # instruction's range (not just the instruction start slot). This is used to
      # decode insns_info entries that point to mid-instruction slots ("adjust" entries).
      #
      # @param instructions [Array<IR::Instruction>]
      # @return [Hash{Integer=>IR::Instruction}] YARV slot → instruction (any slot in range)
      def self.slot_to_containing_inst_map(instructions)
        map = {}
        slot = 0
        instructions.each do |insn|
          opcode_num = NAME_TO_OPCODE[insn.opcode]
          raise "Unknown opcode name: #{insn.opcode.inspect}" unless opcode_num
          _name, op_types = OPCODE_TO_INFO[opcode_num]
          size = slots_for(op_types)
          size.times { |i| map[slot + i] = insn }
          slot += size
        end
        map
      end

      # Build an IR::Instruction → slot map (reverse of slot_map).
      #
      # @param instructions [Array<IR::Instruction>]
      # @return [Hash{IR::Instruction=>Integer}] instruction → YARV slot
      def self.inst_to_slot_map(instructions)
        result = {}
        slot = 0
        instructions.each do |insn|
          opcode_num = NAME_TO_OPCODE[insn.opcode]
          raise "Unknown opcode name: #{insn.opcode.inspect}" unless opcode_num
          _name, op_types = OPCODE_TO_INFO[opcode_num]
          result[insn] = slot
          slot += slots_for(op_types)
        end
        result
      end

      # Decode +bytes+ (a binary String) into an Array<IR::Instruction>.
      #
      # Branch OFFSET operands in the binary are relative slot offsets: the number
      # of YARV slots to skip from the NEXT instruction's slot to reach the target.
      # In IR, they are stored as absolute instruction indices.
      # Convention: branch OFFSET operands are instruction indices in IR;
      # they are relative YARV slot offsets (from next-insn) in the binary.
      # See #encode for the reverse conversion.
      #
      # @param bytes        [String]        raw bytecode bytes (ASCII-8BIT)
      # @param object_table [ObjectTable]   decoded global object table (for index resolution)
      # @param iseqs        [Array]         iseq-list array (for TS_ISEQ resolution)
      # @return [Array<IR::Instruction>]
      def self.decode(bytes, object_table, iseqs)
        reader = BinaryReader.new(bytes)
        instructions = []
        # slot_to_insn_idx[slot] = instruction index; built as we decode.
        # slot is the YARV absolute slot number for the first slot of each instruction.
        slot_to_insn_idx = {}
        # Track each instruction's starting slot and op_types for OFFSET conversion.
        insn_slots = []  # [starting_slot, op_types] per instruction
        # Also track which instruction indices have OFFSET operands and which operand position.
        offset_operand_positions = [] # [[insn_idx, operand_idx], ...]
        current_slot = 0

        while reader.pos < bytes.bytesize
          opcode_offset = reader.pos
          opcode_num = reader.read_small_value

          info = OPCODE_TO_INFO[opcode_num]
          raise Codec::UnsupportedOpcode.new(opcode_num, opcode_offset) unless info

          _name, op_types = info
          opcode_sym = info[0]

          insn_idx = instructions.size
          slot_to_insn_idx[current_slot] = insn_idx
          insn_slot_start = current_slot
          insn_slots << [insn_slot_start, op_types]

          operand_idx = 0
          operands = op_types.filter_map do |op_type|
            case op_type
            when :VALUE, :CDHASH, :ID, :ISEQ, :LINDEX, :NUM, :ISE, :IVC, :ICVARC, :IC
              operand_idx += 1
              reader.read_small_value
            when :OFFSET
              offset_operand_positions << [insn_idx, operand_idx]
              operand_idx += 1
              reader.read_small_value  # raw relative offset; converted below
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
              operand_idx += 1
              [idx, name_len, name_bytes]
            else
              raise "Unknown operand type #{op_type.inspect} for opcode #{opcode_sym}"
            end
          end

          current_slot += slots_for(op_types)

          instructions << IR::Instruction.new(
            opcode:   opcode_sym,
            operands: operands,
            line:     nil,
          )
        end

        # Convert OFFSET operands from YARV relative slot offsets to instruction indices.
        # The binary stores: OFFSET_raw = target_slot - next_insn_slot
        # where next_insn_slot = start_slot + slots_for(op_types) of the branching instruction.
        offset_operand_positions.each do |insn_idx, op_idx|
          raw_offset = instructions[insn_idx].operands[op_idx]
          start_slot, op_types = insn_slots[insn_idx]
          next_insn_slot = start_slot + slots_for(op_types)
          target_slot = next_insn_slot + raw_offset
          insn_target = slot_to_insn_idx[target_slot]
          raise "OFFSET raw=#{raw_offset} in #{instructions[insn_idx].opcode} targets slot #{target_slot} with no corresponding instruction" unless insn_target
          instructions[insn_idx].operands[op_idx] = insn_target
        end

        instructions
      end

      # Encode +instructions+ (Array<IR::Instruction>) back into a bytecode binary String.
      #
      # Branch OFFSET operands in IR are absolute instruction indices; they are
      # converted to relative YARV slot offsets (from next-insn) in the binary.
      # Convention: branch OFFSET operands are instruction indices in IR;
      # they are relative YARV slot offsets (from next-insn) in the binary.
      # See #decode for the reverse conversion.
      #
      # @param instructions [Array<IR::Instruction>]
      # @param object_table [ObjectTable]  (unused in current identity encoding, reserved)
      # @param iseqs        [Array]        (unused in current identity encoding, reserved)
      # @return [String] ASCII-8BIT bytecode bytes
      def self.encode(instructions, object_table, iseqs)
        writer = BinaryWriter.new

        # Build instruction-index -> YARV starting slot map for OFFSET conversion.
        insn_to_slot = {}
        current_slot = 0
        instructions.each_with_index do |insn, idx|
          insn_to_slot[idx] = current_slot
          opcode_num = NAME_TO_OPCODE[insn.opcode]
          raise "Unknown opcode name: #{insn.opcode.inspect}" unless opcode_num
          _name, op_types = OPCODE_TO_INFO[opcode_num]
          current_slot += slots_for(op_types)
        end

        instructions.each_with_index do |insn, insn_idx|
          opcode_num = NAME_TO_OPCODE[insn.opcode]
          raise "Unknown opcode name: #{insn.opcode.inspect}" unless opcode_num

          writer.write_small_value(opcode_num)

          _name, op_types = OPCODE_TO_INFO[opcode_num]
          operand_idx = 0
          next_insn_slot = insn_to_slot[insn_idx] + slots_for(op_types)

          op_types.each do |op_type|
            case op_type
            when :VALUE, :CDHASH, :ID, :ISEQ, :LINDEX, :NUM, :ISE, :IVC, :ICVARC, :IC
              writer.write_small_value(insn.operands[operand_idx])
              operand_idx += 1
            when :OFFSET
              # Convert instruction index to YARV relative slot offset.
              # OFFSET_raw = target_slot - next_insn_slot
              target_insn_idx = insn.operands[operand_idx]
              target_slot = insn_to_slot[target_insn_idx]
              raise "OFFSET operand #{target_insn_idx} has no corresponding slot (out of range?)" unless target_slot
              writer.write_small_value(target_slot - next_insn_slot)
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
