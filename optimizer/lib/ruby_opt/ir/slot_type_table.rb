# frozen_string_literal: true

module RubyOpt
  module IR
    # Per-function map from local-slot-index → type-string.
    # v1: populated from (a) RBS signature param types, (b) ClassName.new
    # constructor-prop (added in a later task). Parent ref enables
    # cross-iseq-level lookup from block bodies.
    class SlotTypeTable
      attr_reader :parent

      def self.build(function, signature, parent)
        new(function, signature, parent)
      end

      def initialize(function, signature, parent)
        @slot_types = {}
        @parent = parent
        seed_from_signature(function, signature)
      end

      def lookup(slot, level)
        table = self
        level.times do
          table = table.parent
          return nil unless table
        end
        table.slot_types[slot]
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
    end
  end
end
