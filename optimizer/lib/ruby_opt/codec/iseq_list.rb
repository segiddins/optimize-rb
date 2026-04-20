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

      def initialize(functions, root, raw_offset_array, object_table, raw_trailing = "".b)
        @functions         = functions
        @root              = root
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

        # Capture per-function raw slices: per-section alignment padding and raw content.
        #
        # Section order (from ibf-format.md §4.1):
        #   bytecode → opt_table → kw → insns_info_body → insns_info_positions →
        #   local_table → lvar_states → catch_table → ci_entries → outer_vars
        #
        # For each section we capture:
        #   misc[:"#{key}_pad_raw"]  — alignment bytes immediately BEFORE this section's abs offset.
        #                              Computed as binary[prev_content_end .. abs-1].
        #   misc[:"#{key}_raw"]      — section content bytes.
        #                              For bytecode: exact bytecode_size bytes (no trailing pad).
        #                              For all other sections: bytes from abs to next_section_abs-1,
        #                              which INCLUDES any trailing alignment padding before the
        #                              next section. At encode time, this trailing pad is reproduced
        #                              by writing IR_content + (raw.bytesize - ir_content.bytesize)
        #                              zero bytes, which is byte-identical since CRuby pads with zeros.
        #
        # After emit_section for non-bytecode sections, content_end advances by the FULL raw
        # size (abs + raw.bytesize), so the next section's pad_len calculation is 0 (the pad
        # is already embedded at the tail of the current section's raw blob).
        prev_end = ISEQ_REGION_START   # byte offset where previous function's data ended
        body_offsets.each_with_index do |body_offset, idx|
          fn   = all_functions[idx]
          misc = fn.misc
          raw_body      = misc[:raw_body]

          # Build the ordered list of (section_key, abs_offset) for this function,
          # sorted by ascending abs offset. Absent sections (abs nil or 0) are excluded.
          section_order = [
            [:bytecode,    misc[:bytecode_abs]],
            [:opt_table,   misc[:opt_table_abs]],
            [:kw,          misc[:kw_abs]],
            [:insns_body,  misc[:insns_body_abs]],
            [:insns_pos,   misc[:insns_pos_abs]],
            [:local_table, misc[:local_table_abs]],
            [:lvar_states, misc[:lvar_states_abs]],
            [:catch_table, misc[:catch_table_abs]],
            [:ci_entries,  misc[:ci_entries_abs]],
            [:outer_vars,  misc[:outer_vars_abs]],
          ].select { |_, abs| abs && abs > 0 }
           .sort_by { |_, abs| abs }

          # Walk the sections, capturing pad and raw content.
          # content_end tracks where the previous section's content (+ embedded trailing pad) ended.
          content_end = prev_end
          section_order.each_with_index do |(key, abs), i|
            # Alignment padding: bytes from content_end up to (but not including) this section's abs.
            pad_len = abs - content_end
            misc[:"#{key}_pad_raw"] = pad_len > 0 ? binary.byteslice(content_end, pad_len) : "".b

            # Section content size.
            # Bytecode: exact size from body record (no trailing pad).
            # Others: span from abs to just before the next section's abs (or body_offset if last).
            #   This span includes any trailing alignment zeros before the next section.
            if key == :bytecode
              content_size = misc[:bytecode_size] || 0
            else
              next_abs = (i + 1 < section_order.size) ? section_order[i + 1][1] : body_offset
              content_size = next_abs - abs
            end

            raw_bytes = content_size > 0 ? binary.byteslice(abs, content_size) : "".b
            misc[:"#{key}_raw"] = raw_bytes

            # Advance content_end by the full raw size (so next section's pad_len = 0
            # if trailing pad is embedded in our raw).
            content_end = abs + content_size
          end

          # Also set pre_bytecode_raw / post_bytecode_raw for backward compat.
          bytecode_abs  = misc[:bytecode_abs]
          bytecode_size = misc[:bytecode_size]
          if bytecode_abs && bytecode_size && bytecode_size > 0
            pre_len   = bytecode_abs - prev_end
            pre_bytes = pre_len > 0 ? binary.byteslice(prev_end, pre_len) : "".b
            post_start = bytecode_abs + bytecode_size
            post_len   = body_offset - post_start
            post_bytes = post_len > 0 ? binary.byteslice(post_start, post_len) : "".b
            misc[:pre_bytecode_raw]  = pre_bytes
            misc[:post_bytecode_raw] = post_bytes
          else
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

        new(all_functions, root, raw_offset_array, object_table, raw_trailing)
      end

      # Encode the iseq list into +writer+.
      #
      # Writes each function's data sections sequentially at writer.pos, tracking
      # fresh absolute byte offsets in data_region_offsets. IR-owned sections
      # (bytecode, catch_table, line_info, opt_table) are re-encoded from IR;
      # raw-only sections (kw, local_table, lvar_states, ci_entries, outer_vars)
      # are written verbatim from per-section raw captures stored at decode time.
      #
      # After all data sections, each function's body record is emitted at writer.pos
      # using IseqEnvelope.encode with the freshly-computed offsets.
      #
      # After all iseqs, the fresh body offsets are packed as the iseq offset array.
      # The original offset array is compared against the fresh one; a mismatch
      # raises a diagnostic error (indicating layout divergence for unmodified IR).
      #
      # @param writer [BinaryWriter]
      def encode(writer)
        original_body_offsets = @raw_offset_array.unpack("V*")
        fresh_body_offsets    = []

        @functions.each_with_index do |fn, idx|
          misc = fn.misc

          # Build inst_to_slot once if this function has instructions.
          inst_to_slot = fn.instructions ? InstructionStream.inst_to_slot_map(fn.instructions) : nil

          # Fresh offsets for this function's data sections (all absolute byte offsets).
          dro = {}

          # Helper: emit a section only if it was present in the original (abs != nil and > 0).
          #
          # Emits:
          #   1. Alignment pad bytes (misc[:"#{key}_pad_raw"]) before the section content.
          #   2. The section content (from block).
          #   3. Trailing zero bytes to fill up to misc[:"#{key}_raw"].bytesize.
          #      (For bytecode: raw == content exactly, so no trailing pad.
          #       For other sections: raw includes trailing alignment zeros before next section.)
          #
          # Records fresh abs offset in dro[abs_key].
          # Raises on byte-identity mismatch.
          emit_section = ->(key, abs_key, &block) do
            orig_abs = misc[abs_key]
            return unless orig_abs && orig_abs > 0

            # Emit alignment padding before this section.
            pad_raw = misc[:"#{key}_pad_raw"] || "".b
            writer.write_bytes(pad_raw) unless pad_raw.empty?

            # Record fresh abs offset (position after padding = start of content).
            dro[abs_key] = writer.pos

            # Emit section content (block writes to writer and returns content bytes).
            content_bytes = block.call

            # ROUND-TRIP ONLY: zero-pad IR content to raw size; real length changes will fail the fresh body-offset assertion downstream.
            # Emit trailing zero bytes to match original raw size.
            # For bytecode the raw is exact (no trailing pad).
            # For other sections the raw includes alignment zeros before next section.
            original_raw = misc[:"#{key}_raw"] || "".b
            trailing_pad = original_raw.bytesize - content_bytes.bytesize
            if trailing_pad > 0
              writer.write_bytes("\x00".b * trailing_pad)
            end

            # Byte-identity assertion: content + trailing pad must match original raw.
            emitted_str = content_bytes + ("\x00".b * [trailing_pad, 0].max)
            check_len = original_raw.bytesize
            if emitted_str.bytesize != check_len || emitted_str != original_raw
              first_diff = (0...check_len).find { |i| emitted_str.getbyte(i) != original_raw.getbyte(i) }
              raise RuntimeError,
                "byte-identity assertion failed: iseq=#{fn.name} section=#{key} " \
                "emitted=#{emitted_str.bytesize} original=#{check_len} " \
                "first diff at offset #{first_diff} " \
                "(emitted=0x#{emitted_str.getbyte(first_diff)&.to_s(16)&.rjust(2,'0') || 'nil'} " \
                "original=0x#{original_raw.getbyte(first_diff)&.to_s(16)&.rjust(2,'0') || 'nil'})"
            end
          end

          # 1. Bytecode (IR-encoded; raw is exact bytecode_size bytes, no trailing pad).
          # NOTE: bytecode is intentionally modifiable; we only check SIZE, not content.
          # The byte-identity assertion in emit_section would reject modified bytecode, so
          # we bypass emit_section for bytecode and write it directly.
          bytecode_abs_orig = misc[:bytecode_abs]
          if bytecode_abs_orig && bytecode_abs_orig > 0
            pad_raw = misc[:bytecode_pad_raw] || "".b
            writer.write_bytes(pad_raw) unless pad_raw.empty?
            dro[:bytecode_abs] = writer.pos

            bytecode_size = misc[:bytecode_size]
            if bytecode_size && bytecode_size > 0 && fn.instructions
              new_bytes = InstructionStream.encode(fn.instructions, @object_table, @functions)
              if new_bytes.bytesize != bytecode_size
                raise Codec::EncoderSizeChange,
                  "instruction re-encode changed size: iseq=#{fn.name} was=#{bytecode_size} got=#{new_bytes.bytesize}"
              end
              writer.write_bytes(new_bytes)
            end
          end

          # 2. opt_table (IR-encoded; VALUE[] entries; raw may include trailing pad to next section).
          # NOTE: If fn.arg_positions == nil (no positional optional args), we cannot re-encode
          # from IR. For keyword-only iseqs (param_opt_num == 0) arg_positions is nil but
          # opt_table_abs may still be set; emit the raw slice to preserve round-trip.
          emit_section.call(:opt_table, :opt_table_abs) do
            arg_positions = fn.arg_positions
            if arg_positions && inst_to_slot
              content_writer = BinaryWriter.new
              ArgPositions.encode_to_writer(content_writer, arg_positions, inst_to_slot)
              writer.write_bytes(content_writer.buffer)
              content_writer.buffer
            else
              # No IR data: write original bytes verbatim.
              original_raw_opt = misc[:opt_table_raw] || "".b
              writer.write_bytes(original_raw_opt)
              original_raw_opt
            end
          end

          # 3. kw (keyword param struct — raw only; raw includes trailing pad to next section)
          emit_section.call(:kw, :kw_abs) do
            raw = misc[:kw_raw] || "".b
            writer.write_bytes(raw)
            raw
          end

          # Pre-compute LineInfo.encode once per function (when line_entries are present).
          line_entries    = fn.line_entries
          insns_info_size = misc[:insns_info_size]
          line_body_bytes = nil
          line_pos_bytes  = nil
          if line_entries && insns_info_size && insns_info_size > 0 && inst_to_slot
            body_writer = BinaryWriter.new
            pos_writer  = BinaryWriter.new
            LineInfo.encode(body_writer, pos_writer, line_entries, inst_to_slot)
            line_body_bytes = body_writer.buffer
            line_pos_bytes  = pos_writer.buffer
          end

          # 4. insns_info body (IR-encoded; raw may include trailing pad)
          emit_section.call(:insns_body, :insns_body_abs) do
            if line_body_bytes
              writer.write_bytes(line_body_bytes)
              line_body_bytes
            else
              "".b
            end
          end

          # 5. insns_info positions (IR-encoded; re-encode to get pos bytes)
          emit_section.call(:insns_pos, :insns_pos_abs) do
            if line_pos_bytes
              writer.write_bytes(line_pos_bytes)
              line_pos_bytes
            else
              "".b
            end
          end

          # 6. local_table (raw; raw includes trailing pad to next section)
          emit_section.call(:local_table, :local_table_abs) do
            raw = misc[:local_table_raw] || "".b
            writer.write_bytes(raw)
            raw
          end

          # 7. lvar_states (raw)
          emit_section.call(:lvar_states, :lvar_states_abs) do
            raw = misc[:lvar_states_raw] || "".b
            writer.write_bytes(raw)
            raw
          end

          # 8. catch_table (IR-encoded; raw may include trailing pad)
          emit_section.call(:catch_table, :catch_table_abs) do
            catch_entries    = fn.catch_entries
            catch_table_size = misc[:catch_table_size]
            if catch_entries && catch_table_size && catch_table_size > 0 && inst_to_slot
              ct_writer = BinaryWriter.new
              CatchTable.encode(ct_writer, catch_entries, inst_to_slot)
              writer.write_bytes(ct_writer.buffer)
              ct_writer.buffer
            else
              "".b
            end
          end

          # 9. ci_entries (raw)
          emit_section.call(:ci_entries, :ci_entries_abs) do
            raw = misc[:ci_entries_raw] || "".b
            writer.write_bytes(raw)
            raw
          end

          # 10. outer_vars (raw)
          emit_section.call(:outer_vars, :outer_vars_abs) do
            raw = misc[:outer_vars_raw] || "".b
            writer.write_bytes(raw)
            raw
          end

          # Emit body record at current writer.pos.
          dro[:body_offset_abs] = writer.pos

          # Propagate nil offsets for absent sections (so rel offsets compute correctly as 0).
          dro[:bytecode_abs]    ||= misc[:bytecode_abs]
          dro[:opt_table_abs]   ||= misc[:opt_table_abs]
          dro[:kw_abs]          ||= misc[:kw_abs]
          dro[:insns_body_abs]  ||= misc[:insns_body_abs]
          dro[:insns_pos_abs]   ||= misc[:insns_pos_abs]
          dro[:local_table_abs] ||= misc[:local_table_abs]
          dro[:lvar_states_abs] ||= misc[:lvar_states_abs]
          dro[:catch_table_abs] ||= misc[:catch_table_abs]
          dro[:ci_entries_abs]  ||= misc[:ci_entries_abs]
          dro[:outer_vars_abs]  ||= misc[:outer_vars_abs]

          fresh_body_offsets << writer.pos

          # Encode body record from IR + fresh offsets.
          body_writer = BinaryWriter.new
          IseqEnvelope.encode(body_writer, fn, dro)
          emitted_body = body_writer.buffer
          original_body = misc[:raw_body]

          if emitted_body.bytesize != original_body.bytesize
            raise RuntimeError,
              "body record size mismatch: iseq=#{fn.name} was=#{original_body.bytesize} got=#{emitted_body.bytesize}"
          end

          if emitted_body != original_body
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
            orig_reader = BinaryReader.new(original_body)
            emit_reader = BinaryReader.new(emitted_body)
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

          writer.write_bytes(emitted_body)
        end

        # Append trailing bytes after the last body record (alignment padding, if any).
        writer.write_bytes(@raw_trailing)

        # Align to 4 bytes before writing the iseq offset array
        # (ibf_dump_align uses sizeof(ibf_offset_t) = 4).
        writer.align_to(4)

        # Verify fresh offsets match original for unmodified IR.
        fresh_body_offsets.each_with_index do |fresh, idx|
          original = original_body_offsets[idx]
          if fresh != original
            fn = @functions[idx]
            raise RuntimeError,
              "iseq offset array mismatch: iseq=#{fn.name} idx=#{idx} " \
              "original=#{original} fresh=#{fresh} " \
              "(layout divergence; IR may have changed section sizes)"
          end
        end

        # Write the fresh iseq offset array.
        writer.write_bytes(fresh_body_offsets.pack("V*"))
      end
    end
  end
end
