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

      # Splice-replace a contiguous range of instructions. Handles:
      #   - Patching absolute branch-target operand indices for:
      #       :branchif, :branchunless, :branchnil, :jump (operand 0)
      #       :opt_case_dispatch (operand 1: default offset)
      #   - Raising if any branch targets an instruction inside the spliced range
      #     (callers must only splice over non-target instructions).
      #   - Invalidating the memoized CFG.
      #
      # @param range [Range<Integer>] inclusive range of instruction indices to replace
      # @param replacement [Array<IR::Instruction>] the new instructions
      def splice_instructions!(range, replacement)
        insts = instructions
        return unless insts
        start = range.begin
        last  = range.end
        old_len = last - start + 1
        new_len = replacement.size
        delta = old_len - new_len # positive when shrinking, negative when growing

        # Patch branch targets. A branch to `start` still points at the first
        # replacement instruction (valid). A branch to an index in (start, last]
        # points INTO the spliced-away region — invariant violation.
        insts.each_with_index do |inst, idx|
          next if idx >= start && idx <= last # instruction is being replaced
          case inst.opcode
          when :branchif, :branchunless, :branchnil, :jump
            t = inst.operands[0]
            next unless t.is_a?(Integer)
            if t > start && t <= last
              raise "splice_instructions!: branch at index #{idx} targets instruction at #{t}, which is inside the spliced range #{range}"
            elsif t > last
              inst.operands[0] = t - delta
            end
          when :opt_case_dispatch
            # Default OFFSET is operand[1]; CDHASH of case offsets is operand[0].
            # For v1 correctness we only need to patch the default; the CDHASH is a
            # frozen Hash{VALUE => Integer_index} — patch its values too.
            t = inst.operands[1]
            if t.is_a?(Integer)
              if t > start && t <= last
                raise "splice_instructions!: opt_case_dispatch at index #{idx} default-targets #{t} inside spliced range"
              elsif t > last
                inst.operands[1] = t - delta
              end
            end
            cdhash = inst.operands[0]
            if cdhash.is_a?(Hash)
              new_hash = {}
              cdhash.each do |k, v|
                if v.is_a?(Integer)
                  if v > start && v <= last
                    raise "splice_instructions!: opt_case_dispatch at index #{idx} CDHASH entry targets #{v} inside spliced range"
                  end
                  new_hash[k] = v > last ? v - delta : v
                else
                  new_hash[k] = v
                end
              end
              inst.operands[0] = new_hash
            end
          end
        end

        # A replacement entry that is itself a branch/jump carries a target
        # expressed against the PRE-splice array. Patch it the same way we
        # patch targets on surviving instructions so the post-splice array
        # is self-consistent.
        replacement.each do |inst|
          case inst.opcode
          when :branchif, :branchunless, :branchnil, :jump
            t = inst.operands[0]
            next unless t.is_a?(Integer)
            if t > start && t <= last
              raise "splice_instructions!: replacement branch targets #{t}, which is inside the spliced range #{range}"
            elsif t > last
              inst.operands[0] = t - delta
            end
          end
        end

        insts[start..last] = replacement
        invalidate_cfg
      end
    end
  end
end
