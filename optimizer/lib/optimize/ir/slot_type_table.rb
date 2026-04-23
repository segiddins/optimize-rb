# frozen_string_literal: true

module Optimize
  module IR
    class SlotTypeTable
      attr_reader :parent

      def self.build(function, signature, parent, object_table: nil)
        new(function, signature, parent, object_table: object_table)
      end

      def initialize(function, signature, parent, object_table: nil)
        @slot_types = {}
        @parent = parent
        @local_table_size = (function.misc && function.misc[:local_table_size]) || 0
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

      # Returns the local_table_size of the table `level` parents up.
      # Returns nil if the parent chain ends before reaching `level`.
      def local_table_size_at(level)
        table = self
        level.times do
          table = table.parent
          return nil unless table
        end
        table.local_table_size
      end

      # Update the cached size after the function's local table grew. The
      # cache is what `local_table_size_at` walks; after a pass calls
      # Codec::LocalTable.grow!, the slot-table view must be re-synced.
      def refresh_local_table_size!(new_size)
        @local_table_size = new_size
      end

      # LINDEX ↔ slot-index conversion.
      # LINDEX = VM_ENV_DATA_SIZE(3) + (size - 1 - slot)  →  slot = size - 1 - (LINDEX - 3).
      def self.lindex_to_slot(lindex, size)
        size - 1 - (lindex - 3)
      end

      protected

      attr_reader :slot_types, :local_table_size

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

      def detect_class_new_producer(insts, set_idx, object_table)
        detect_via_direct_new_send(insts, set_idx, object_table) ||
          detect_via_opt_new(insts, set_idx, object_table)
      end

      # Ruby 3.x shape: setlocal directly preceded by opt_send_without_block :new.
      def detect_via_direct_new_send(insts, set_idx, object_table)
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
        resolve_constant_path_tail(recv.operands[0], object_table)
      end

      # Resolves the tail symbol of a constant-path operand on an
      # `opt_getconstant_path` instruction. Handles both shapes:
      # - Array literal (older/test-stub form): `[:Point]` → "Point"
      # - Object-table index into an Array of Symbol indices (codec form):
      #   `4` → object_table.objects[4] = [12] → objects[12] = :Point.
      def resolve_constant_path_tail(operand, object_table)
        if operand.is_a?(Array)
          return nil if operand.empty?
          return operand.last.to_s
        end
        return nil unless operand.is_a?(Integer) && object_table
        path_array = object_table.objects[operand]
        return nil unless path_array.is_a?(Array) && !path_array.empty?
        tail = path_array.last
        tail = object_table.objects[tail] if tail.is_a?(Integer)
        return nil unless tail.is_a?(Symbol)
        tail.to_s
      end

      # Ruby 4.0+ shape: setlocal is preceded by a fast/slow-path wrapper
      # around `opt_new`. We scan back up to MAX_NEW_WRAPPER_LOOKBACK
      # instructions for the :opt_new opcode; if found, look further back
      # for the opt_getconstant_path that names the class.
      MAX_NEW_WRAPPER_LOOKBACK = 12
      MAX_GETCONSTANT_LOOKBACK = 6

      def detect_via_opt_new(insts, set_idx, object_table)
        i = set_idx - 1
        limit = [0, set_idx - MAX_NEW_WRAPPER_LOOKBACK].max
        while i >= limit
          if insts[i].opcode == :opt_new
            cd = insts[i].operands[0]
            return nil unless cd.respond_to?(:mid_symbol)
            return nil unless cd.mid_symbol(object_table) == :new
            j = i - 1
            jlimit = [0, i - MAX_GETCONSTANT_LOOKBACK].max
            while j >= jlimit
              if insts[j].opcode == :opt_getconstant_path
                return resolve_constant_path_tail(insts[j].operands[0], object_table)
              end
              j -= 1
            end
            return nil
          end
          i -= 1
        end
        nil
      end
    end
  end
end
