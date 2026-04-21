# frozen_string_literal: true

module RubyOpt
  module IR
    # One call-site's calldata record. Mirrors the on-disk shape at
    # research/cruby/ibf-format.md §4.1 "call info (ci) entries":
    # per-cd: mid_idx, flag, argc, kwlen, kw_indices.
    #
    # mid_idx and kw_indices are OBJECT-TABLE indices (ID refs), not resolved
    # symbols — that mirrors how other operands are stored and preserves
    # byte-identical round-trip. Resolution to Symbol happens via the passed
    # object table (see IR::CallData#mid_symbol).
    CallData = Struct.new(:mid_idx, :flag, :argc, :kwlen, :kw_indices, keyword_init: true) do
      # Calldata flag bits we care about in v1. Values from
      # vm_callinfo.h (iseq.c). These are the exact C enum values.
      FLAG_ARGS_SPLAT    = 0x01
      FLAG_ARGS_BLOCKARG = 0x02
      FLAG_FCALL         = 0x04
      FLAG_VCALL         = 0x08
      FLAG_ARGS_SIMPLE   = 0x10
      FLAG_BLOCKISEQ     = 0x20
      FLAG_KWARG         = 0x40
      FLAG_KW_SPLAT      = 0x80
      FLAG_TAILCALL      = 0x100
      FLAG_SUPER         = 0x200
      FLAG_ZSUPER        = 0x400
      FLAG_OPT_SEND      = 0x800
      FLAG_KW_SPLAT_MUT  = 0x1000
      FLAG_FORWARDING    = 0x2000

      def fcall?        = (flag & FLAG_FCALL) != 0
      def args_simple?  = (flag & FLAG_ARGS_SIMPLE) != 0
      def blockarg?     = (flag & FLAG_ARGS_BLOCKARG) != 0
      def has_kwargs?   = kwlen.positive?
      def has_splat?    = (flag & FLAG_ARGS_SPLAT) != 0

      def mid_symbol(object_table)
        object_table.resolve(mid_idx)
      end
    end
  end
end
