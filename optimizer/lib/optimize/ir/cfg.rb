# frozen_string_literal: true
require "optimize/ir/basic_block"

module Optimize
  module IR
    # Control-flow graph of a function. Blocks are computed once from the
    # function's instruction list; successors/predecessors are queried via
    # edge lookups.
    #
    # Branch OFFSET operands are instruction indices (normalized by the codec
    # at decode time), so CFG construction works directly on instruction indices.
    class CFG
      BRANCH_OPCODES = %i[branchif branchunless branchnil].freeze
      JUMP_OPCODES = %i[jump].freeze
      TERMINATOR_OPCODES = (BRANCH_OPCODES + JUMP_OPCODES + %i[leave throw]).freeze

      attr_reader :blocks

      def self.build(instructions)
        leaders = compute_leaders(instructions)
        blocks = slice_into_blocks(instructions, leaders)
        edges = compute_edges(instructions, blocks)
        new(blocks, edges)
      end

      def initialize(blocks, edges)
        @blocks = blocks
        @edges = edges # { from_block_id => [to_block, ...] }
      end

      def successors(block)
        @edges[block.id] || []
      end

      def predecessors(block)
        @blocks.select { |b| successors(b).include?(block) }
      end

      def self.compute_leaders(instructions)
        return [] if instructions.empty?
        leaders = [0]
        instructions.each_with_index do |ins, i|
          next unless TERMINATOR_OPCODES.include?(ins.opcode)
          # The instruction after a terminator is a leader (if it exists).
          leaders << (i + 1) if i + 1 < instructions.size
          # Branch targets are leaders (OFFSET operand is an instruction index).
          if (BRANCH_OPCODES + JUMP_OPCODES).include?(ins.opcode)
            target = ins.operands[0]
            leaders << target if target.is_a?(Integer) && target >= 0 && target < instructions.size
          end
        end
        leaders.uniq.sort
      end

      def self.slice_into_blocks(instructions, leaders)
        return [] if instructions.empty?
        blocks = []
        leaders.each_with_index do |start, idx|
          stop = leaders[idx + 1] || instructions.size
          blocks << BasicBlock.new(id: idx, instructions: instructions[start...stop])
        end
        blocks
      end

      def self.compute_edges(instructions, blocks)
        # Map instruction index -> block (via identity comparison on first instruction).
        insn_to_block = {}
        blocks.each do |b|
          offset = instructions.index { |ins| ins.equal?(b.instructions.first) }
          next unless offset
          b.instructions.each_with_index do |_, j|
            insn_to_block[offset + j] = b
          end
        end

        edges = Hash.new { |h, k| h[k] = [] }
        blocks.each do |b|
          term = b.terminator
          next unless term
          case term.opcode
          when *BRANCH_OPCODES
            # OFFSET operand is an instruction index (normalized at decode time).
            target = term.operands[0]
            fallthrough_idx = instructions.index { |i| i.equal?(term) } + 1
            if (tblock = insn_to_block[target])
              edges[b.id] << tblock
            end
            if (fblock = insn_to_block[fallthrough_idx])
              edges[b.id] << fblock
            end
          when *JUMP_OPCODES
            target = term.operands[0]
            if (tblock = insn_to_block[target])
              edges[b.id] << tblock
            end
          when :leave, :throw
            # no successors
          else
            # Non-terminator tail (shouldn't happen if leaders are right,
            # but fall through to the next block just in case).
            fallthrough_idx = instructions.index { |i| i.equal?(term) } + 1
            if (fblock = insn_to_block[fallthrough_idx])
              edges[b.id] << fblock
            end
          end
        end
        edges
      end
    end
  end
end
