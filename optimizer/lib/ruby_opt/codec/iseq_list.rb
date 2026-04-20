# frozen_string_literal: true

require "ruby_opt/codec/iseq_envelope"
require "ruby_opt/codec/binary_reader"
require "ruby_opt/codec/binary_writer"
require "ruby_opt/codec/instruction_stream"
require "ruby_opt/codec/catch_table"
require "ruby_opt/codec/line_info"
require "ruby_opt/codec/arg_positions"
require "ruby_opt/ir/function"

module RubyOpt
  module Codec
    # Decodes and encodes the iseq list section of a YARB binary.
    #
    # Binary layout (from research/cruby/ibf-format.md §2 and §4):
    #
    #   [40]  Iseq data region — data sections and body records for all iseqs
    #         (interleaved; each iseq written by ibf_dump_iseq_each; body record last)
    #   [X]   Iseq offset array — iseq_list_size × uint32_t at header.iseq_list_offset
    #         Each entry is the absolute offset of that iseq's body record.
    #
    # The ObjectTable follows immediately after the iseq offset array.
    #
    # Decode strategy:
    #   1. Read the iseq offset array (random-access via header.iseq_list_offset).
    #   2. Capture the raw iseq data region (bytes 40 .. iseq_list_offset-1 plus the
    #      offset array itself) for verbatim re-emission.
    #   3. Decode each body record to build IR::Function objects.
    #   4. Wire up parent/child relationships using parent_iseq_index.
    #
    # Encode strategy:
    #   1. Write the raw iseq data region verbatim.
    #   2. Write the iseq offset array (the body record offsets stay the same since we
    #      re-emit the data region byte-for-byte).
    #
    class IseqList
      # @return [Array<IR::Function>] all functions in iseq-list order
      attr_reader :functions

      # @return [IR::Function] the root (top-level) iseq — typically functions[0]
      attr_reader :root

      # Absolute byte offset where the iseq data region begins in the binary.
      ISEQ_REGION_START = 40

      def initialize(functions, root, raw_iseq_region, raw_offset_array, object_table, raw_trailing = "".b)
        @functions         = functions
        @root              = root
        @raw_iseq_region   = raw_iseq_region   # bytes from pos 40 to iseq_list_offset (exclusive)
        @raw_offset_array  = raw_offset_array  # iseq_list_size × 4 bytes
        @object_table      = object_table
        @raw_trailing      = raw_trailing      # trailing bytes after last body record (before list_offset)
      end

      # Decode the iseq list from +binary+ using +header+ and +object_table+.
      #
      # @param binary       [String]      full YARB binary (ASCII-8BIT)
      # @param header       [Header]      decoded header
      # @param object_table [ObjectTable] decoded object table
      # @return [IseqList]
      def self.decode(binary, header, object_table)
        iseq_count  = header.iseq_list_size
        list_offset = header.iseq_list_offset

        # Capture raw bytes: iseq data region (from pos 40 to list_offset).
        iseq_region_start = 40
        iseq_region_len   = list_offset - iseq_region_start
        raw_iseq_region   = binary.byteslice(iseq_region_start, iseq_region_len)

        # Capture raw offset array bytes.
        raw_offset_array  = binary.byteslice(list_offset, iseq_count * 4)

        # Read the offset array.
        body_offsets = raw_offset_array.unpack("V*")  # V = uint32 little-endian

        # First pass: decode each body record, building IR::Function stubs.
        # all_functions[i] corresponds to iseq-list index i.
        all_functions = Array.new(iseq_count)
        body_offsets.each_with_index do |body_offset, idx|
          all_functions[idx] = IseqEnvelope.decode(
            binary, body_offset, header, object_table, all_functions
          )
        end

        # Capture per-function raw slices that bracket the bytecode section.
        # After this, IseqList#encode can emit bytecode from IR without touching
        # @raw_iseq_region for bytecode bytes.
        prev_end = iseq_region_start   # byte offset where previous function's body ended
        body_offsets.each_with_index do |body_offset, idx|
          fn   = all_functions[idx]
          misc = fn.misc
          raw_body      = misc[:raw_body]
          bytecode_abs  = misc[:bytecode_abs]
          bytecode_size = misc[:bytecode_size]

          if bytecode_abs && bytecode_size && bytecode_size > 0
            # Bytes before bytecode (from prev function's end to bytecode start).
            pre_len    = bytecode_abs - prev_end
            pre_bytes  = pre_len > 0 ? binary.byteslice(prev_end, pre_len) : "".b

            # Bytes after bytecode up to (but not including) the body record.
            post_start = bytecode_abs + bytecode_size
            post_len   = body_offset - post_start
            post_bytes = post_len > 0 ? binary.byteslice(post_start, post_len) : "".b

            misc[:pre_bytecode_raw]  = pre_bytes
            misc[:post_bytecode_raw] = post_bytes
          else
            # No bytecode: entire data section (prev_end..body_offset) is "pre".
            pre_len   = body_offset - prev_end
            pre_bytes = pre_len > 0 ? binary.byteslice(prev_end, pre_len) : "".b
            misc[:pre_bytecode_raw]  = pre_bytes
            misc[:post_bytecode_raw] = "".b
          end

          prev_end = body_offset + raw_body.bytesize
        end

        # Capture any trailing bytes in the iseq data region after the last body record.
        # These bytes (if any) exist between the last body record's end and list_offset.
        trailing_len  = list_offset - prev_end
        raw_trailing  = trailing_len > 0 ? binary.byteslice(prev_end, trailing_len) : "".b

        # Second pass: wire up parent/child relationships.
        # Each function's misc[:parent_iseq_index] tells us who its parent is.
        # The sentinel for "no parent" is -1 stored as a huge unsigned int in small_value
        # (CRuby uses ibf_offset_t which is uint32; -1 == 0xFFFFFFFF).
        # We treat any parent_idx >= iseq_count or parent_idx == idx as "no real parent".
        all_functions.each_with_index do |fn, idx|
          parent_idx = fn.misc[:parent_iseq_index]
          # Clamp to signed 32-bit to handle the -1 sentinel (stored as 0xFFFFFFFF).
          # small_value is decoded as unsigned; -1 as uint32 = 4294967295.
          parent_idx_signed = parent_idx > 0x7FFFFFFF ? parent_idx - 0x100000000 : parent_idx
          next if parent_idx_signed < 0          # -1 sentinel: no parent
          next if parent_idx_signed == idx       # root iseq: parent is itself
          next if parent_idx_signed >= iseq_count

          parent_fn = all_functions[parent_idx_signed]
          parent_fn&.children&.push(fn)
        end

        # The root is the top-level iseq (index 0 in the list, or the one with no real parent).
        # Convention: iseq-list index 0 is always the outermost iseq.
        root = all_functions[0]

        new(all_functions, root, raw_iseq_region, raw_offset_array, object_table, raw_trailing)
      end

      # Encode the iseq list into +writer+.
      #
      # For each function, re-encodes its instruction stream via InstructionStream.encode
      # and emits it from IR (not from @raw_iseq_region). Other data sections and body
      # records are reconstructed from per-function raw captures stored at decode time.
      # If the re-encoded instruction bytes differ in length from the original,
      # raises RubyOpt::Codec::EncoderSizeChange.
      #
      # Catch table entries are re-encoded from IR::CatchEntry objects and spliced in.
      #
      # @param writer [BinaryWriter]
      def encode(writer)
        # Reconstruct the iseq data region from per-function raw captures.
        # Bytecode is sourced from IR (not from @raw_iseq_region); all other bytes
        # come from the pre/post captures stored at decode time.
        region = "".b
        @functions.each do |fn|
          misc          = fn.misc
          bytecode_abs  = misc[:bytecode_abs]
          bytecode_size = misc[:bytecode_size]

          # Emit the bytes that precede the bytecode section for this function.
          region << misc[:pre_bytecode_raw]

          if bytecode_abs && bytecode_size && bytecode_size > 0 && fn.instructions
            # Re-encode the instruction stream from IR (not from @raw_iseq_region).
            new_bytes = InstructionStream.encode(fn.instructions, @object_table, @functions)
            new_len   = new_bytes.bytesize

            if new_len != bytecode_size
              raise Codec::EncoderSizeChange,
                "instruction re-encode changed size: iseq=#{fn.name} was=#{bytecode_size} got=#{new_len}"
            end

            region << new_bytes
          end

          # Emit the bytes that follow the bytecode section (up to the body record).
          region << misc[:post_bytecode_raw]

          # Emit the raw body record bytes (will be overwritten by body-record re-encode below).
          region << misc[:raw_body]
        end

        # Append trailing bytes after the last body record (alignment padding, if any).
        region << @raw_trailing

        # Apply re-encoded catch table, line info, opt_table into region (same splice logic).
        @functions.each do |fn|
          bytecode_abs  = fn.misc[:bytecode_abs]
          bytecode_size = fn.misc[:bytecode_size]

          # Skip iseqs with no bytecode (e.g. iseq_size == 0).
          next unless bytecode_abs && bytecode_size && bytecode_size > 0
          next unless fn.instructions

          # Re-encode the catch table from IR::CatchEntry objects (if present).
          catch_entries = fn.catch_entries
          catch_table_abs  = fn.misc[:catch_table_abs]
          catch_table_size = fn.misc[:catch_table_size]
          if catch_entries && catch_table_abs && catch_table_size > 0
            # Build inst → slot map from current instructions.
            inst_to_slot = InstructionStream.inst_to_slot_map(fn.instructions)
            ct_writer = BinaryWriter.new
            CatchTable.encode(ct_writer, catch_entries, inst_to_slot)
            new_ct_bytes = ct_writer.buffer

            # Splice the re-encoded catch table into the region.
            ct_region_offset = catch_table_abs - ISEQ_REGION_START
            region[ct_region_offset, new_ct_bytes.bytesize] = new_ct_bytes
          end

          # Re-encode the insns_info (line info) from IR::LineEntry objects (if present).
          # CRuby stores this as two separate sections: body (line_no/node_id/events) and
          # positions (delta-encoded slot positions).
          line_entries = fn.line_entries
          insns_body_abs = fn.misc[:insns_body_abs]
          insns_pos_abs  = fn.misc[:insns_pos_abs]
          insns_info_size = fn.misc[:insns_info_size]
          if line_entries && insns_body_abs && insns_pos_abs && insns_info_size > 0
            inst_to_slot = InstructionStream.inst_to_slot_map(fn.instructions)
            body_writer = BinaryWriter.new
            pos_writer  = BinaryWriter.new
            LineInfo.encode(body_writer, pos_writer, line_entries, inst_to_slot)

            body_region_offset = insns_body_abs - ISEQ_REGION_START
            pos_region_offset  = insns_pos_abs  - ISEQ_REGION_START
            region[body_region_offset, body_writer.buffer.bytesize] = body_writer.buffer
            region[pos_region_offset,  pos_writer.buffer.bytesize]  = pos_writer.buffer
          end

          # Re-encode the opt_table from IR::ArgPositions (if present).
          # opt_table is VALUE[] (8-byte native uint64 YARV slot indices), VALUE-aligned.
          arg_positions = fn.arg_positions
          opt_table_abs = fn.misc[:opt_table_abs]
          if arg_positions && opt_table_abs
            inst_to_slot = InstructionStream.inst_to_slot_map(fn.instructions)
            ArgPositions.encode(region, ISEQ_REGION_START, opt_table_abs, arg_positions, inst_to_slot)
          end
        end

        # Task 5b: Re-emit each body record from IR fields + data_region_offsets, then
        # splice the re-emitted bytes over the original body bytes in the region.
        body_offsets = @raw_offset_array.unpack("V*")
        @functions.each_with_index do |fn, idx|
          data_region_offsets = {
            body_offset_abs:  body_offsets[idx],
            bytecode_abs:     fn.misc[:bytecode_abs],
            opt_table_abs:    fn.misc[:opt_table_abs],
            kw_abs:           fn.misc[:kw_abs],
            insns_body_abs:   fn.misc[:insns_body_abs],
            insns_pos_abs:    fn.misc[:insns_pos_abs],
            local_table_abs:  fn.misc[:local_table_abs],
            lvar_states_abs:  fn.misc[:lvar_states_abs],
            catch_table_abs:  fn.misc[:catch_table_abs],
            ci_entries_abs:   fn.misc[:ci_entries_abs],
            outer_vars_abs:   fn.misc[:outer_vars_abs],
          }

          body_writer = BinaryWriter.new
          IseqEnvelope.encode(body_writer, fn, data_region_offsets)
          emitted = body_writer.buffer
          original = fn.misc[:raw_body]

          if emitted.bytesize != original.bytesize
            raise RuntimeError,
              "body record size mismatch: iseq=#{fn.name} was=#{original.bytesize} got=#{emitted.bytesize}"
          end

          if emitted != original
            # Field-by-field diff to identify the first wrong field.
            field_names = [
              :type_val, :iseq_size, :bytecode_offset_rel, :bytecode_size,
              :param_flags, :param_size, :param_lead_num, :param_opt_num,
              :param_rest_start, :param_post_start, :param_post_num, :param_block_start,
              :param_opt_table_offset_rel, :param_keyword_offset,
              :location_pathobj_index, :location_base_label_index, :location_label_index,
              :location_first_lineno, :location_node_id, :location_beg_lineno,
              :location_beg_column, :location_end_lineno, :location_end_column,
              :insns_info_body_offset_rel, :insns_info_positions_offset_rel,
              :insns_info_size, :local_table_offset_rel, :lvar_states_offset_rel,
              :catch_table_size, :catch_table_offset_rel,
              :parent_iseq_index, :local_iseq_index, :mandatory_only_iseq_index,
              :ci_entries_offset_rel, :outer_variables_offset_rel,
              :variable_flip_count, :local_table_size, :ivc_size, :icvarc_size,
              :ise_size, :ic_size, :ci_size, :stack_max, :builtin_attrs, :prism,
            ]

            orig_reader = BinaryReader.new(original)
            emit_reader = BinaryReader.new(emitted)
            field_names.each do |field|
              orig_val = orig_reader.read_small_value
              emit_val = emit_reader.read_small_value
              if orig_val != emit_val
                raise RuntimeError,
                  "body record field mismatch: iseq=#{fn.name} field=#{field} " \
                  "expected=#{orig_val} got=#{emit_val}"
              end
            end
            raise RuntimeError,
              "body record bytes differ but all fields match: iseq=#{fn.name} (encoding bug)"
          end

          # Splice re-emitted body bytes into region.
          body_region_offset = body_offsets[idx] - ISEQ_REGION_START
          region[body_region_offset, emitted.bytesize] = emitted
        end

        writer.write_bytes(region)
        writer.write_bytes(@raw_offset_array)
      end
    end
  end
end
