# frozen_string_literal: true
require "ruby_opt/ir/cfg"

module RubyOpt
  module IR
    # Holds instruction references for an iseq's optional-argument position table.
    # References are to IR::Instruction objects by identity so they survive
    # instruction-list mutation.
    #
    #   opt_table — Array<IR::Instruction>, one per optional arg plus one terminating entry.
    #               Each entry points at the instruction where execution begins when
    #               exactly (lead_num + i) positional args were supplied.
    #               Format on disk: VALUE[] (8-byte native uint64 YARV slot indices).
    ArgPositions = Struct.new(:opt_table, keyword_init: true)

    # One decoded iseq. Fields mirror the envelope described in
    # research/cruby/ibf-format.md §4.
    Function = Struct.new(
      # Location fields (from body record: location_* indices resolved via object table)
      :name,            # String — location_label (human-readable name like "hi" or "block in hi")
      :path,            # String — path component of location_pathobj
      :absolute_path,   # String or nil — realpath component (nil for top-level or eval)
      :first_lineno,    # Integer
      :type,            # Symbol — :top, :method, :block, :class, :rescue, :ensure, :eval, etc.

      # Param/arg spec (decoded from param_flags + param.* fields)
      :arg_spec,        # Hash with keys: :lead_num, :opt_num, :rest_start, :post_start,
                        #   :post_num, :block_start, :flags (raw param_flags integer)

      # Tables (raw bytes for now; Task 8+ will decode fully)
      :local_table,     # raw bytes or decoded ID array — local variable names
      :catch_table,     # raw bytes or decoded catch entries
      :line_info,       # raw bytes — insns_info body + positions

      # Decoded catch table entries (Array<IR::CatchEntry> or nil if no catch table)
      :catch_entries,   # Array<IR::CatchEntry> — decoded exception handler table

      # Decoded line info entries (Array<IR::LineEntry> or nil)
      :line_entries,    # Array<IR::LineEntry> — decoded insns_info table

      # Decoded arg positions (IR::ArgPositions or nil if no opt_table)
      :arg_positions,   # IR::ArgPositions — opt_table as IR::Instruction references

      # Instructions (raw bytecode bytes — Task 8 will decode the stream)
      :instructions,    # raw bytes of the encoded bytecode stream

      # Nested iseqs (blocks, nested methods, etc.)
      :children,        # Array<Function> — nested iseqs (in iseq-list order within this iseq's tree)

      # Raw envelope for byte-identical round-trip
      :misc,            # Hash with all raw body-record field values and raw data section bytes
      keyword_init: true
    )

    Function.class_eval do
      def cfg
        @cfg ||= CFG.build(instructions || [])
      end

      def invalidate_cfg
        @cfg = nil
      end
    end
  end
end
