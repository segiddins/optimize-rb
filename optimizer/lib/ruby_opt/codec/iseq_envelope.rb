# frozen_string_literal: true

require "ruby_opt/ir/function"
require "ruby_opt/codec/binary_reader"
require "ruby_opt/codec/binary_writer"

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
          instructions:  bytecode_abs && bytecode_size > 0 ?
                           binary.byteslice(bytecode_abs, bytecode_size) : "".b,
          children:      [],
          misc:          misc,
        )
      end

      # Encode one iseq's data sections and body record into +writer+.
      #
      # For byte-identical round-trip: the data sections are stored in the IseqList
      # raw_iseq_data region (written verbatim before the body records). The body
      # record bytes are stored in misc[:raw_body] and written verbatim here.
      #
      # @param writer   [BinaryWriter]
      # @param function [IR::Function]
      # @return [Integer] absolute offset of the body record in the writer buffer
      def self.encode(writer, function)
        # The body record is written verbatim.
        body_offset = writer.pos
        writer.write_bytes(function.misc[:raw_body])
        body_offset
      end
    end
  end
end
