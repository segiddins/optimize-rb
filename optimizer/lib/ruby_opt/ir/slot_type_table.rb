# frozen_string_literal: true

module RubyOpt
  module IR
    class SlotTypeTable
      attr_reader :parent

      def self.build(function, signature, parent, object_table: nil)
        new(function, signature, parent, object_table: object_table)
      end

      def initialize(function, signature, parent, object_table: nil)
        @slot_types = {}
        @parent = parent
        seed_from_signature(function, signature)
        scan_for_constructors(function, object_table)
      end

      def lookup(slot, level)
        table = self
        level.times do
          table = table.parent
          return nil unless table
        end
        table.slot_types[slot]
      end

      # LINDEX ↔ slot-index conversion.
      # LINDEX = VM_ENV_DATA_SIZE(3) + (size - 1 - slot)  →  slot = size - 1 - (LINDEX - 3).
      def self.lindex_to_slot(lindex, size)
        size - 1 - (lindex - 3)
      end

      protected

      attr_reader :slot_types

      private

      def seed_from_signature(function, signature)
        return unless signature
        lead_num = (function.arg_spec && function.arg_spec[:lead_num]) || 0
        arg_types = signature.arg_types || []
        lead_num.times do |i|
          type = arg_types[i]
          next unless type
          @slot_types[i] = type
        end
      end

      def scan_for_constructors(function, object_table)
        insts = function.instructions || []
        size  = (function.misc && function.misc[:local_table_size]) || 0
        insts.each_with_index do |inst, i|
          next unless setlocal_level0?(inst)
          slot = self.class.lindex_to_slot(inst.operands[0], size)
          class_name = detect_class_new_producer(insts, i, object_table)
          if class_name
            @slot_types[slot] = class_name
          else
            @slot_types.delete(slot)
          end
        end
      end

      def setlocal_level0?(inst)
        inst.opcode == :setlocal_WC_0 ||
          (inst.opcode == :setlocal && (inst.operands[1] || 0) == 0)
      end

      # Walk back from the setlocal at idx looking for
      # [opt_getconstant_path <path>, arg pushes..., opt_send_without_block :new].
      #
      # v1 assumes each arg occupies exactly one instruction (literals,
      # `getlocal`, etc.). A compound arg like `Point.new(a + b, 2)` has
      # a multi-instruction producer for the first arg; the back-walk
      # will land mid-expression and fail to match, which is safe but
      # misses a real `.new` call. Stack-effect-aware back-walk is future
      # work.
      def detect_class_new_producer(insts, set_idx, object_table)
        return nil if set_idx.zero?
        send_inst = insts[set_idx - 1]
        return nil unless send_inst.opcode == :opt_send_without_block
        cd = send_inst.operands[0]
        return nil unless cd.respond_to?(:argc) && cd.respond_to?(:mid_symbol)
        return nil unless cd.mid_symbol(object_table) == :new
        recv_idx = set_idx - 1 - cd.argc - 1
        return nil if recv_idx < 0
        recv = insts[recv_idx]
        return nil unless recv.opcode == :opt_getconstant_path
        path = recv.operands[0]
        return nil unless path.is_a?(Array) && !path.empty?
        path.last.to_s
      end
    end
  end
end
