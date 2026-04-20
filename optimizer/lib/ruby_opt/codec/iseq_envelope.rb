# frozen_string_literal: true

require "ruby_opt/ir/function"
require "ruby_opt/ir/instruction"
require "ruby_opt/codec/binary_reader"
require "ruby_opt/codec/binary_writer"
require "ruby_opt/codec/instruction_stream"
require "ruby_opt/codec/catch_table"
require "ruby_opt/codec/line_info"
require "ruby_opt/codec/arg_positions"

module RubyOpt
  module Codec
    # Encodes and decodes the per-iseq envelope (body record + data sections).
    #
    # Binary layout (from research/cruby/ibf-format.md §4):
    #
    #   Each iseq is serialized by ibf_dump_iseq_each:
    #     1. Data sections written first (bytecode, param opt table, keyword params,
    #        insns_info body, insns_info positions, local table, lvar states, catch table,
    #        ci entries, outer variables)
    #     2. Body record written last — a sequential stream of small_values (41 fields)
    #
    #   The iseq offset array (at header.iseq_list_offset) contains absolute offsets
    #   pointing to each body record (NOT the start of data sections).
    #
    #   Relative offsets in the body record are stored as (body_offset - actual_offset),
    #   i.e. a backward distance. Loading: actual_offset = body_offset - stored_value.
    #
    # Strategy for byte-identical round-trip:
    #   - Read the body record fields (41 small_values) to extract metadata.
    #   - Store raw body record bytes in misc[:raw_body] for verbatim re-emission.
    #   - Derive data section spans from body-record relative offsets and store each
    #     data section's raw bytes in misc for verbatim re-emission.
    #   - Decode high-value metadata fields (name, path, type, arg_spec, etc.) for IR use.
    #   - On encode: re-emit data sections verbatim, then re-emit raw body bytes.
    #
    module IseqEnvelope
      # ISEQ_TYPE_* enum values from Ruby (iseq.h / compile.c).
      ISEQ_TYPES = {
        0  => :top,
        1  => :method,
        2  => :block,
        3  => :class,
        4  => :rescue,
        5  => :ensure,
        6  => :eval,
        7  => :main,
        8  => :plain,
        9  => :defined_guard,
      }.freeze

      ISEQ_TYPE_NAMES = ISEQ_TYPES.invert.freeze

      # Decode one iseq envelope from +binary+ (the full YARB binary string).
      #
      # @param binary       [String]  full YARB binary (ASCII-8BIT)
      # @param body_offset  [Integer] absolute byte offset of the body record
      # @param header       [Header]  decoded header (for wordsize etc.)
      # @param object_table [ObjectTable] decoded object table (for label resolution)
      # @param all_functions [Array<IR::Function|nil>] iseq-list indexed array being built
      # @return [IR::Function]
      def self.decode(binary, body_offset, header, object_table, all_functions)
        reader = BinaryReader.new(binary)
        reader.seek(body_offset)

        body_start = body_offset

        # Read all 41 body record small_value fields in order.
        type_val                          = reader.read_small_value
        iseq_size                         = reader.read_small_value
        bytecode_offset_rel               = reader.read_small_value
        bytecode_size                     = reader.read_small_value
        param_flags                       = reader.read_small_value
        param_size                        = reader.read_small_value
        param_lead_num                    = reader.read_small_value
        param_opt_num                     = reader.read_small_value
        param_rest_start                  = reader.read_small_value
        param_post_start                  = reader.read_small_value
        param_post_num                    = reader.read_small_value
        param_block_start                 = reader.read_small_value
        param_opt_table_offset_rel        = reader.read_small_value
        param_keyword_offset              = reader.read_small_value
        location_pathobj_index            = reader.read_small_value
        location_base_label_index         = reader.read_small_value
        location_label_index              = reader.read_small_value
        location_first_lineno             = reader.read_small_value
        location_node_id                  = reader.read_small_value
        location_beg_lineno               = reader.read_small_value
        location_beg_column               = reader.read_small_value
        location_end_lineno               = reader.read_small_value
        location_end_column               = reader.read_small_value
        insns_info_body_offset_rel        = reader.read_small_value
        insns_info_positions_offset_rel   = reader.read_small_value
        insns_info_size                   = reader.read_small_value
        local_table_offset_rel            = reader.read_small_value
        lvar_states_offset_rel            = reader.read_small_value
        catch_table_size                  = reader.read_small_value
        catch_table_offset_rel           = reader.read_small_value
        parent_iseq_index                 = reader.read_small_value
        local_iseq_index                  = reader.read_small_value
        mandatory_only_iseq_index         = reader.read_small_value
        ci_entries_offset_rel             = reader.read_small_value
        outer_variables_offset_rel        = reader.read_small_value
        variable_flip_count               = reader.read_small_value
        local_table_size                  = reader.read_small_value
        ivc_size                          = reader.read_small_value
        icvarc_size                       = reader.read_small_value
        ise_size                          = reader.read_small_value
        ic_size                           = reader.read_small_value
        ci_size                           = reader.read_small_value
        stack_max                         = reader.read_small_value
        builtin_attrs                     = reader.read_small_value
        prism                             = reader.read_small_value

        body_end = reader.pos

        # Capture raw body bytes for verbatim re-emission.
        raw_body = binary.byteslice(body_start, body_end - body_start)

        # Resolve relative offsets → absolute offsets.
        # Formula: actual_offset = body_offset - stored_relative_value
        # A stored value of 0 means "not present" for optional sections.
        bytecode_abs     = bytecode_offset_rel > 0 ? body_offset - bytecode_offset_rel : nil
        opt_table_abs    = param_opt_table_offset_rel > 0 ? body_offset - param_opt_table_offset_rel : nil
        kw_abs           = param_keyword_offset > 0 ? param_keyword_offset : nil  # absolute, not relative
        insns_body_abs   = insns_info_body_offset_rel > 0 ? body_offset - insns_info_body_offset_rel : nil
        insns_pos_abs    = insns_info_positions_offset_rel > 0 ? body_offset - insns_info_positions_offset_rel : nil
        local_table_abs  = local_table_offset_rel > 0 ? body_offset - local_table_offset_rel : nil
        lvar_states_abs  = lvar_states_offset_rel > 0 ? body_offset - lvar_states_offset_rel : nil
        catch_table_abs  = catch_table_offset_rel > 0 ? body_offset - catch_table_offset_rel : nil
        ci_entries_abs   = ci_entries_offset_rel > 0 ? body_offset - ci_entries_offset_rel : nil
        outer_vars_abs   = outer_variables_offset_rel > 0 ? body_offset - outer_variables_offset_rel : nil

        # Resolve names from object table.
        objects = object_table.objects
        label     = objects[location_label_index]
        base_label = objects[location_base_label_index]
        pathobj    = objects[location_pathobj_index]

        # pathobj is either a String (path only) or an Array [path, realpath] (indices).
        path_str = abs_path_str = nil
        if pathobj.is_a?(Array)
          # Array stores object-table indices; resolve them.
          path_str     = objects[pathobj[0]]
          abs_path_str = objects[pathobj[1]]
        elsif pathobj.is_a?(String)
          path_str = pathobj
        end

        # Decode type symbol.
        type_sym = ISEQ_TYPES[type_val] || type_val

        # Decode param flags.
        arg_spec = {
          flags:         param_flags,
          size:          param_size,
          lead_num:      param_lead_num,
          opt_num:       param_opt_num,
          rest_start:    param_rest_start,
          post_start:    param_post_start,
          post_num:      param_post_num,
          block_start:   param_block_start,
          has_lead:      param_flags[0] == 1,
          has_opt:       param_flags[1] == 1,
          has_rest:      param_flags[2] == 1,
          has_post:      param_flags[3] == 1,
          has_kw:        param_flags[4] == 1,
          has_kwrest:    param_flags[5] == 1,
          has_block:     param_flags[6] == 1,
        }

        # Store all raw body fields in misc for faithful round-trip.
        misc = {
          raw_body:                       raw_body,
          type_val:                       type_val,
          iseq_size:                      iseq_size,
          bytecode_offset_rel:            bytecode_offset_rel,
          bytecode_size:                  bytecode_size,
          param_flags:                    param_flags,
          param_size:                     param_size,
          param_lead_num:                 param_lead_num,
          param_opt_num:                  param_opt_num,
          param_rest_start:               param_rest_start,
          param_post_start:               param_post_start,
          param_post_num:                 param_post_num,
          param_block_start:              param_block_start,
          param_opt_table_offset_rel:     param_opt_table_offset_rel,
          param_keyword_offset:           param_keyword_offset,
          location_pathobj_index:         location_pathobj_index,
          location_base_label_index:      location_base_label_index,
          location_label_index:           location_label_index,
          location_first_lineno:          location_first_lineno,
          location_node_id:               location_node_id,
          location_beg_lineno:            location_beg_lineno,
          location_beg_column:            location_beg_column,
          location_end_lineno:            location_end_lineno,
          location_end_column:            location_end_column,
          insns_info_body_offset_rel:     insns_info_body_offset_rel,
          insns_info_positions_offset_rel: insns_info_positions_offset_rel,
          insns_info_size:                insns_info_size,
          local_table_offset_rel:         local_table_offset_rel,
          lvar_states_offset_rel:         lvar_states_offset_rel,
          catch_table_size:               catch_table_size,
          catch_table_offset_rel:         catch_table_offset_rel,
          parent_iseq_index:              parent_iseq_index,
          local_iseq_index:               local_iseq_index,
          mandatory_only_iseq_index:      mandatory_only_iseq_index,
          ci_entries_offset_rel:          ci_entries_offset_rel,
          outer_variables_offset_rel:     outer_variables_offset_rel,
          variable_flip_count:            variable_flip_count,
          local_table_size:               local_table_size,
          ivc_size:                       ivc_size,
          icvarc_size:                    icvarc_size,
          ise_size:                       ise_size,
          ic_size:                        ic_size,
          ci_size:                        ci_size,
          stack_max:                      stack_max,
          builtin_attrs:                  builtin_attrs,
          prism:                          prism,
          # Absolute offsets (for layout tracking)
          bytecode_abs:                   bytecode_abs,
          opt_table_abs:                  opt_table_abs,
          kw_abs:                         kw_abs,
          insns_body_abs:                 insns_body_abs,
          insns_pos_abs:                  insns_pos_abs,
          local_table_abs:               local_table_abs,
          lvar_states_abs:                lvar_states_abs,
          catch_table_abs:                catch_table_abs,
          ci_entries_abs:                 ci_entries_abs,
          outer_vars_abs:                 outer_vars_abs,
        }

        # Decode the instruction stream from raw bytecode bytes into IR::Instruction array.
        # We keep raw operand indices (not resolved Ruby objects) so that re-encoding
        # produces byte-identical output.
        raw_bytecode = bytecode_abs && bytecode_size > 0 ?
                         binary.byteslice(bytecode_abs, bytecode_size) : "".b
        instructions = InstructionStream.decode(raw_bytecode, object_table, all_functions)
        # Store the raw bytecode in misc so IseqList can re-emit the region verbatim.
        misc[:raw_bytecode] = raw_bytecode

        # Decode the catch table into IR::CatchEntry objects.
        # The slot_map maps YARV slot index → IR::Instruction (by identity).
        catch_entries = nil
        if catch_table_size > 0 && catch_table_abs
          slot_to_inst = InstructionStream.slot_map(instructions)
          ct_reader = BinaryReader.new(binary)
          ct_reader.seek(catch_table_abs)
          catch_entries = CatchTable.decode(ct_reader, catch_table_size, slot_to_inst)
        end

        # Decode the insns_info (line info) table into IR::LineEntry objects.
        # CRuby splits this into two sections:
        #   - body section (insns_body_abs): N × (line_no, node_id, events) — absolute small_values
        #   - positions section (insns_pos_abs): N × pos_delta — delta-encoded slot positions
        line_entries = nil
        if insns_info_size > 0 && insns_body_abs && insns_pos_abs
          slot_to_inst     = InstructionStream.slot_map(instructions)
          inst_to_slot     = InstructionStream.inst_to_slot_map(instructions)
          slot_to_containing = InstructionStream.slot_to_containing_inst_map(instructions)
          body_reader = BinaryReader.new(binary)
          body_reader.seek(insns_body_abs)
          pos_reader = BinaryReader.new(binary)
          pos_reader.seek(insns_pos_abs)
          line_entries = LineInfo.decode(body_reader, pos_reader, insns_info_size, slot_to_inst, slot_to_containing, inst_to_slot)
        end

        # Decode the opt_table into IR::ArgPositions (instruction references).
        # Only present when param_opt_num > 0.
        arg_positions = nil
        if param_opt_num > 0 && opt_table_abs
          slot_to_inst = InstructionStream.slot_map(instructions)
          arg_positions = ArgPositions.decode(
            binary, opt_table_abs, param_opt_num, slot_to_inst
          )
        end

        # Build the IR::Function. children will be populated by the caller.
        IR::Function.new(
          name:          label.to_s,
          path:          path_str.to_s,
          absolute_path: abs_path_str,
          first_lineno:  location_first_lineno,
          type:          type_sym,
          arg_spec:      arg_spec,
          local_table:   nil,   # raw bytes stored in misc if needed
          catch_table:   nil,   # raw bytes stored in misc if needed
          line_info:     nil,   # raw bytes stored in misc if needed
          catch_entries: catch_entries,
          line_entries:  line_entries,
          arg_positions: arg_positions,
          instructions:  instructions,
          children:      [],
          misc:          misc,
        )
      end

      # Encode one iseq's body record into +writer+ by re-emitting all 45 small_values
      # from IR fields and data_region_offsets.
      #
      # Relative offset fields are computed as: body_offset - abs_offset
      # where body_offset = data_region_offsets[:body_offset_abs].
      # A stored value of 0 means the section is absent.
      # param_keyword_offset is stored absolute (not relative).
      #
      # @param writer              [BinaryWriter]
      # @param function            [IR::Function]
      # @param data_region_offsets [Hash] absolute byte offsets keyed by symbol
      #   (:body_offset_abs, :bytecode_abs, :opt_table_abs, :kw_abs, :insns_body_abs,
      #    :insns_pos_abs, :local_table_abs, :lvar_states_abs, :catch_table_abs,
      #    :ci_entries_abs, :outer_vars_abs)
      # @return [Integer] byte offset within the writer buffer where the body record starts
      def self.encode(writer, function, data_region_offsets)
        misc = function.misc
        body_offset = data_region_offsets[:body_offset_abs]

        # Helper: compute rel offset (body_offset - abs), or 0 if absent.
        rel = ->(key) {
          abs = data_region_offsets[key]
          (abs && abs > 0) ? body_offset - abs : 0
        }

        # Derive type_val from IR type symbol if possible, else fall back to misc.
        type_val = ISEQ_TYPE_NAMES[function.type] || misc[:type_val]

        # location_first_lineno from IR (should equal misc value for unmodified IR).
        location_first_lineno = function.first_lineno

        buf_start = writer.pos

        # Emit all 45 small_values in the exact order the decoder reads them.
        writer.write_small_value(type_val)
        writer.write_small_value(misc[:iseq_size])
        writer.write_small_value(rel.call(:bytecode_abs))
        writer.write_small_value(misc[:bytecode_size])
        writer.write_small_value(misc[:param_flags])
        writer.write_small_value(misc[:param_size])
        writer.write_small_value(misc[:param_lead_num])
        writer.write_small_value(misc[:param_opt_num])
        writer.write_small_value(misc[:param_rest_start])
        writer.write_small_value(misc[:param_post_start])
        writer.write_small_value(misc[:param_post_num])
        writer.write_small_value(misc[:param_block_start])
        writer.write_small_value(rel.call(:opt_table_abs))
        # param_keyword_offset is absolute (not relative).
        writer.write_small_value(misc[:param_keyword_offset])
        writer.write_small_value(misc[:location_pathobj_index])
        writer.write_small_value(misc[:location_base_label_index])
        writer.write_small_value(misc[:location_label_index])
        writer.write_small_value(location_first_lineno)
        writer.write_small_value(misc[:location_node_id])
        writer.write_small_value(misc[:location_beg_lineno])
        writer.write_small_value(misc[:location_beg_column])
        writer.write_small_value(misc[:location_end_lineno])
        writer.write_small_value(misc[:location_end_column])
        writer.write_small_value(rel.call(:insns_body_abs))
        writer.write_small_value(rel.call(:insns_pos_abs))
        writer.write_small_value(misc[:insns_info_size])
        writer.write_small_value(rel.call(:local_table_abs))
        writer.write_small_value(rel.call(:lvar_states_abs))
        writer.write_small_value(misc[:catch_table_size])
        writer.write_small_value(rel.call(:catch_table_abs))
        writer.write_small_value(misc[:parent_iseq_index])
        writer.write_small_value(misc[:local_iseq_index])
        writer.write_small_value(misc[:mandatory_only_iseq_index])
        writer.write_small_value(rel.call(:ci_entries_abs))
        writer.write_small_value(rel.call(:outer_vars_abs))
        writer.write_small_value(misc[:variable_flip_count])
        writer.write_small_value(misc[:local_table_size])
        writer.write_small_value(misc[:ivc_size])
        writer.write_small_value(misc[:icvarc_size])
        writer.write_small_value(misc[:ise_size])
        writer.write_small_value(misc[:ic_size])
        writer.write_small_value(misc[:ci_size])
        writer.write_small_value(misc[:stack_max])
        writer.write_small_value(misc[:builtin_attrs])
        writer.write_small_value(misc[:prism])

        buf_start
      end

      # Verify that the body-record relative offsets agree with +data_region_offsets+.
      #
      # Re-reads the stored small_value fields from misc[:raw_body] and resolves each
      # relative offset back to an absolute byte position using the same formula the
      # decoder uses (abs = body_offset - stored_rel). The original body_offset is
      # derived from bytecode_offset_rel + data_region_offsets[:bytecode_abs].
      #
      # Raises RuntimeError if any resolved absolute offset does not match the
      # corresponding entry in data_region_offsets.
      #
      # @param function            [IR::Function]
      # @param data_region_offsets [Hash] absolute byte offsets keyed by symbol
      def self.verify_offsets(function, data_region_offsets)
        misc = function.misc
        raw_body = misc[:raw_body]
        return unless raw_body && !raw_body.empty?

        # Re-read the 45 small_value fields from the raw body record.
        reader = BinaryReader.new(raw_body)

        _type_val                          = reader.read_small_value
        _iseq_size                         = reader.read_small_value
        bytecode_offset_rel                = reader.read_small_value
        _bytecode_size                     = reader.read_small_value
        _param_flags                       = reader.read_small_value
        _param_size                        = reader.read_small_value
        _param_lead_num                    = reader.read_small_value
        _param_opt_num                     = reader.read_small_value
        _param_rest_start                  = reader.read_small_value
        _param_post_start                  = reader.read_small_value
        _param_post_num                    = reader.read_small_value
        _param_block_start                 = reader.read_small_value
        param_opt_table_offset_rel         = reader.read_small_value
        param_keyword_offset               = reader.read_small_value
        _location_pathobj_index            = reader.read_small_value
        _location_base_label_index         = reader.read_small_value
        _location_label_index              = reader.read_small_value
        _location_first_lineno             = reader.read_small_value
        _location_node_id                  = reader.read_small_value
        _location_beg_lineno               = reader.read_small_value
        _location_beg_column               = reader.read_small_value
        _location_end_lineno               = reader.read_small_value
        _location_end_column               = reader.read_small_value
        insns_info_body_offset_rel         = reader.read_small_value
        insns_info_positions_offset_rel    = reader.read_small_value
        _insns_info_size                   = reader.read_small_value
        local_table_offset_rel             = reader.read_small_value
        lvar_states_offset_rel             = reader.read_small_value
        _catch_table_size                  = reader.read_small_value
        catch_table_offset_rel             = reader.read_small_value
        _parent_iseq_index                 = reader.read_small_value
        _local_iseq_index                  = reader.read_small_value
        _mandatory_only_iseq_index         = reader.read_small_value
        ci_entries_offset_rel              = reader.read_small_value
        outer_variables_offset_rel         = reader.read_small_value
        _variable_flip_count               = reader.read_small_value
        _local_table_size                  = reader.read_small_value
        _ivc_size                          = reader.read_small_value
        _icvarc_size                       = reader.read_small_value
        _ise_size                          = reader.read_small_value
        _ic_size                           = reader.read_small_value
        _ci_size                           = reader.read_small_value
        _stack_max                         = reader.read_small_value
        _builtin_attrs                     = reader.read_small_value
        _prism                             = reader.read_small_value

        # Derive original_body_offset from bytecode field (most reliably present).
        # Formula: body_offset - bytecode_offset_rel = bytecode_abs
        #       => body_offset = bytecode_abs + bytecode_offset_rel
        bytecode_abs_expected = data_region_offsets[:bytecode_abs]
        original_body_offset = nil
        if bytecode_offset_rel > 0 && bytecode_abs_expected && bytecode_abs_expected > 0
          original_body_offset = bytecode_abs_expected + bytecode_offset_rel
        end

        # If we cannot derive original_body_offset (no bytecode section), skip assertions.
        return unless original_body_offset

        # Fields with relative offsets (stored as body_offset - actual_offset).
        relative_fields = [
          [:bytecode_offset_rel,               bytecode_offset_rel,            :bytecode_abs],
          [:param_opt_table_offset_rel,         param_opt_table_offset_rel,     :opt_table_abs],
          [:insns_info_body_offset_rel,         insns_info_body_offset_rel,     :insns_body_abs],
          [:insns_info_positions_offset_rel,    insns_info_positions_offset_rel, :insns_pos_abs],
          [:local_table_offset_rel,             local_table_offset_rel,         :local_table_abs],
          [:lvar_states_offset_rel,             lvar_states_offset_rel,         :lvar_states_abs],
          [:catch_table_offset_rel,             catch_table_offset_rel,         :catch_table_abs],
          [:ci_entries_offset_rel,              ci_entries_offset_rel,          :ci_entries_abs],
          [:outer_variables_offset_rel,         outer_variables_offset_rel,     :outer_vars_abs],
        ]

        relative_fields.each do |name, stored_rel, key|
          next if stored_rel == 0
          expected_abs = data_region_offsets[key]
          next if expected_abs.nil? || expected_abs == 0

          resolved_abs = original_body_offset - stored_rel
          if resolved_abs != expected_abs
            raise RuntimeError,
              "body-record offset drift: field=#{name} stored_rel=#{stored_rel} " \
              "resolved_abs=#{resolved_abs} data_region_abs=#{expected_abs} " \
              "(iseq=#{function.name})"
          end
        end

        # param_keyword_offset is stored as an ABSOLUTE offset (not relative).
        kw_abs_expected = data_region_offsets[:kw_abs]
        if param_keyword_offset > 0 && kw_abs_expected && kw_abs_expected > 0
          if param_keyword_offset != kw_abs_expected
            raise RuntimeError,
              "body-record offset drift: field=param_keyword_offset stored_abs=#{param_keyword_offset} " \
              "data_region_abs=#{kw_abs_expected} (iseq=#{function.name})"
          end
        end
      end
    end
  end
end
