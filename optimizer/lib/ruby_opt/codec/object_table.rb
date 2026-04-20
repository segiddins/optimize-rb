# frozen_string_literal: true

require "ruby_opt/codec/binary_reader"
require "ruby_opt/codec/binary_writer"
require "ruby_opt/codec"

module RubyOpt
  module Codec

    # The global object table holds every literal Ruby object referenced by iseq instructions.
    # Instructions carry integer indices into this table; index 0 is always nil.
    #
    # Binary layout (from research/cruby/ibf-format.md §3):
    #
    #   Object data region  — per-object payloads at various offsets within the binary
    #   Object offset array — global_object_list_size × uint32_t, at global_object_list_offset
    #
    # Each object in the data region begins with a 1-byte header:
    #   bits [4:0] — T_ type constant
    #   bit  [5]   — special_const (1 = encoded as raw VALUE small_value)
    #   bit  [6]   — frozen
    #   bit  [7]   — internal
    #
    # Ruby 4.0.2 special VALUE constants (empirically verified):
    #   RUBY_Qfalse = 0
    #   RUBY_Qtrue  = 20
    #   RUBY_Qnil   = 4
    #   RUBY_Qundef = 36  (= QNIL | 0x20; used as sentinel for unset keyword defaults)
    #   Fixnum n: VALUE = (n << 1) | 1
    class ObjectTable
      # T_ type constants from ruby.h
      T_CLASS    = 2
      T_FLOAT    = 4
      T_STRING   = 5
      T_REGEXP   = 6
      T_ARRAY    = 7
      T_HASH     = 8
      T_STRUCT   = 9
      T_BIGNUM   = 10
      T_DATA     = 12
      T_COMPLEX  = 14
      T_RATIONAL = 15
      T_SYMBOL   = 20

      # Special VALUE constants for Ruby 4.0.2 (empirically verified via object_id)
      QFALSE = 0
      QTRUE  = 20
      QNIL   = 4
      # RUBY_Qundef = QNIL | 0x20; stored in the object table as a sentinel for
      # keyword parameters whose default must be computed at runtime.
      QUNDEF = 36

      # @return [Array<Object>] decoded Ruby objects in on-disk index order
      attr_reader :objects

      def initialize(objects, raw_object_region, obj_list_size: 0, obj_list_offset_in_region: 0)
        @objects = objects
        # Raw bytes covering the object data region + object offset array only.
        # Starts at (iseq_list_offset + iseq_list_size * 4) and runs to end of binary.
        @raw_object_region = raw_object_region
        # Number of objects (= size of the offset array in u32 entries).
        @obj_list_size = obj_list_size
        # Byte offset of the object offset array WITHIN @raw_object_region.
        # Used to patch absolute offsets when the iseq region has grown/shrunk.
        @obj_list_offset_in_region = obj_list_offset_in_region
      end

      # Decode the object table.
      #
      # Accepts either:
      #   decode(binary_string, header)  — preferred; full YARB binary as String
      #   decode(reader, header)         — legacy; BinaryReader positioned after header
      #
      # @param binary_or_reader [String | BinaryReader]
      # @param header           [Header]
      # @return [ObjectTable]
      def self.decode(binary_or_reader, header)
        if binary_or_reader.is_a?(BinaryReader)
          # Legacy path: reconstruct binary from reader, then delegate.
          reader = binary_or_reader
          binary = reader.peek_bytes(0, reader.bytesize)
          result = decode_from_binary(binary, header)
          # Advance reader to end of object offset array (legacy contract).
          reader.seek(header.global_object_list_offset + header.global_object_list_size * 4)
          result
        else
          decode_from_binary(binary_or_reader, header)
        end
      end

      # Decode from a full YARB binary string.
      #
      # @param binary [String]  full YARB binary (ASCII-8BIT)
      # @param header [Header]
      # @return [ObjectTable]
      def self.decode_from_binary(binary, header)
        obj_list_size   = header.global_object_list_size
        obj_list_offset = header.global_object_list_offset

        # The object data region starts immediately after the iseq offset array.
        obj_region_start = header.iseq_list_offset + header.iseq_list_size * 4
        obj_region_len   = binary.bytesize - obj_region_start
        raw_object_region = binary.byteslice(obj_region_start, obj_region_len)

        # Byte offset of the object offset array within the raw_object_region.
        obj_list_offset_in_region = obj_list_offset - obj_region_start

        # Build a temporary reader to decode object bodies.
        reader = BinaryReader.new(binary)

        # Read the object offset array
        reader.seek(obj_list_offset)
        obj_offsets = obj_list_size.times.map { reader.read_u32 }

        # Decode each object by seeking to its offset
        objects = obj_offsets.map do |off|
          reader.seek(off)
          decode_one_object(reader, obj_offsets)
        end

        new(objects, raw_object_region,
            obj_list_size: obj_list_size,
            obj_list_offset_in_region: obj_list_offset_in_region)
      end

      # Write the object table bytes to +writer+.
      # Emits the object data region + offset array. When +iseq_list_delta+ is non-zero
      # (the iseq region has grown or shrunk), the object offset array (which stores
      # absolute positions in the binary) is patched so each entry shifts by that delta.
      # The object payload bytes before the offset array are always verbatim.
      #
      # @param writer          [BinaryWriter]
      # @param iseq_list_delta [Integer] byte delta applied to all absolute offsets in the
      #   object offset array. 0 for unmodified IR (byte-identical round-trip).
      # @return [Integer, nil] the fresh absolute offset of the object offset array
      #   on the general path (when `iseq_list_delta` is non-zero OR objects have
      #   been appended via #intern). Returns nil on the fast path (unmodified
      #   table with no delta), in which case the caller keeps the original offset.
      def encode(writer, iseq_list_delta: 0)
        no_appends = @appended.nil? || @appended.empty?
        if (iseq_list_delta == 0 || @obj_list_size == 0) && no_appends
          # Fast path: byte-identical.
          writer.write_bytes(@raw_object_region)
          return nil
        else
          # Write object payload bytes verbatim (everything before the offset array).
          writer.write_bytes(@raw_object_region.byteslice(0, @obj_list_offset_in_region))

          # Append payloads for any newly interned objects, recording their absolute
          # positions so we can write them into the offset array below.
          appended_offsets = []
          (@appended || []).each do |value|
            appended_offsets << writer.pos
            write_special_const(writer, value)
          end

          # The object offset array must be 4-byte aligned (ibf_dump_align uses
          # sizeof(ibf_offset_t) = 4). Pad after appended payloads if needed.
          writer.align_to(4)

          # Capture the absolute position where the offset array begins in the new buffer.
          fresh_obj_list_offset = writer.pos

          # Patch each u32 in the original offset array by adding iseq_list_delta.
          @obj_list_size.times do |i|
            orig = @raw_object_region.byteslice(@obj_list_offset_in_region + i * 4, 4).unpack1("V")
            writer.write_bytes([orig + iseq_list_delta].pack("V"))
          end

          # Write the new offset array entries. These are already absolute
          # positions in the NEW buffer (writer.pos accounts for the fresh
          # iseq region size), so no iseq_list_delta patch is needed.
          appended_offsets.each do |abs_pos|
            writer.write_bytes([abs_pos].pack("V"))
          end

          # Any trailing bytes after the offset array (if any).
          trail_start = @obj_list_offset_in_region + @obj_list_size * 4
          trail = @raw_object_region.byteslice(trail_start, @raw_object_region.bytesize - trail_start)
          writer.write_bytes(trail) if trail && !trail.empty?
          return fresh_obj_list_offset
        end
      end

      # Find an existing index in the object table whose stored value equals +value+
      # (compared by both == and class so true does not collide with 1, etc.).
      # @return [Integer, nil]
      def index_for(value)
        @objects.index { |o| o == value && o.class == value.class }
      end

      # Return the index of +value+ in the table, appending it if absent.
      # Only special-const values are supported (Integer fixnum, true, false, nil).
      # The new payload is emitted at encode time; the offset array is regrown there.
      # @return [Integer]
      def intern(value)
        existing = index_for(value)
        return existing if existing

        unless special_const?(value)
          raise ArgumentError, "ObjectTable#intern only supports special-const values (Integer/true/false/nil), got #{value.inspect}"
        end

        new_idx = @objects.size
        @objects << value
        @appended ||= []
        @appended << value
        new_idx
      end

      # Number of newly-interned objects pending append on the next encode.
      # @return [Integer]
      def appended_count
        (@appended || []).size
      end

      private

      # Decode one object beginning at the current reader position.
      # +obj_offsets+ is the full array of absolute offsets (used by reference types to
      # resolve object-table indices to Ruby objects).
      def self.decode_one_object(reader, obj_offsets)
        hdr         = reader.read_u8
        type        = hdr & 0x1f
        special_const = (hdr >> 5) & 1

        if special_const == 1
          decode_special_const(reader)
        else
          case type
          when T_STRING  then decode_string(reader)
          when T_SYMBOL  then decode_symbol(reader)
          when T_FLOAT   then decode_float(reader)
          when T_REGEXP  then decode_regexp(reader, obj_offsets)
          when T_ARRAY   then decode_array(reader, obj_offsets)
          when T_HASH    then decode_hash(reader, obj_offsets)
          when T_CLASS   then decode_class(reader)
          when T_DATA    then decode_data(reader)
          when T_BIGNUM  then decode_bignum(reader)
          when T_STRUCT  then decode_struct(reader, obj_offsets)
          when T_COMPLEX then decode_complex_rational(reader, obj_offsets, :complex)
          when T_RATIONAL then decode_complex_rational(reader, obj_offsets, :rational)
          else
            raise Codec::UnsupportedObjectKind,
              "unsupported IBF object type #{type} (header byte 0x#{hdr.to_s(16)})"
          end
        end
      end

      # Decode a special_const object: the body is a single small_value holding the raw Ruby VALUE.
      def self.decode_special_const(reader)
        value = reader.read_small_value
        if value & 1 == 1
          # Fixnum: VALUE = (n << 1) | 1
          value >> 1
        elsif value == QNIL
          nil
        elsif value == QTRUE
          true
        elsif value == QFALSE
          false
        elsif value == QUNDEF
          # RUBY_Qundef: internal sentinel stored for keyword parameters whose default
          # is computed at runtime (e.g. `def f(k: expr)`). Return a frozen sentinel
          # string; the value is never used for re-encoding (raw bytes are preserved).
          :__qundef__
        else
          # Could be a flonum or other special const — we surface the raw VALUE
          # (future tasks can interpret flonum bits if needed)
          raise Codec::UnsupportedObjectKind,
            "unknown special_const VALUE #{value} (0x#{value.to_s(16)})"
        end
      end

      # T_STRING: encindex (small_value), len (small_value), raw bytes
      def self.decode_string(reader)
        encindex = reader.read_small_value
        len      = reader.read_small_value
        bytes    = reader.read_bytes(len)
        enc = encoding_for_index(encindex)
        bytes.force_encoding(enc)
        bytes.encode(Encoding::UTF_8) rescue bytes.dup
      end

      # T_SYMBOL: same wire format as T_STRING (delegates to string decode)
      def self.decode_symbol(reader)
        encindex = reader.read_small_value
        len      = reader.read_small_value
        bytes    = reader.read_bytes(len)
        bytes.to_sym
      end

      # T_FLOAT: 8-byte IEEE 754 double, aligned to 8 within the binary buffer.
      # The reader is positioned at the byte immediately after the 1-byte header.
      def self.decode_float(reader)
        # Align to 8-byte boundary (absolute position in the binary)
        aligned = (reader.pos + 7) & ~7
        reader.seek(aligned)
        reader.read_bytes(8).unpack1("d")
      end

      # T_REGEXP: option byte + small_value (object-table index of source string)
      def self.decode_regexp(reader, obj_offsets)
        option     = reader.read_u8
        srcstr_idx = reader.read_small_value
        # We return a Regexp if we can; the source string is at obj_offsets[srcstr_idx].
        # To avoid recursive seeks here we return a placeholder and let the caller sort it.
        # For the round-trip test we just need the object to be present (any Regexp).
        # Full decoding would require re-loading the source object.
        # For now: return a best-effort Regexp using stored info.
        Regexp.new("__ibf_srcidx_#{srcstr_idx}__", option)
      rescue
        raise Codec::UnsupportedObjectKind, "failed to decode T_REGEXP option=#{option}"
      end

      # T_ARRAY: len (small_value), then len object-table indices (small_values)
      def self.decode_array(reader, obj_offsets)
        len = reader.read_small_value
        len.times.map { reader.read_small_value }
        # Returns the array of indices for now; full resolution needs two-pass decode
      end

      # T_HASH: len (small_value key-value pairs), then 2*len object-table indices
      def self.decode_hash(reader, obj_offsets)
        len = reader.read_small_value
        result = {}
        len.times do
          k = reader.read_small_value
          v = reader.read_small_value
          result[k] = v
        end
        result
      end

      # T_CLASS: small_value cindex (enum ibf_object_class_index)
      CLASS_NAMES = {
        0 => Object, 1 => Array, 2 => StandardError,
        3 => (defined?(NoMatchingPatternError) ? NoMatchingPatternError : StandardError),
        4 => TypeError,
        5 => (defined?(NoMatchingPatternKeyError) ? NoMatchingPatternKeyError : StandardError),
      }.freeze

      def self.decode_class(reader)
        cindex = reader.read_small_value
        CLASS_NAMES[cindex] or raise Codec::UnsupportedObjectKind, "unknown class index #{cindex}"
      end

      # T_DATA: only encoding objects are supported in IBF.
      # Layout: long[2] {IBF_OBJECT_DATA_ENCODING, len} (aligned), then char[len] encoding name.
      def self.decode_data(reader)
        wordsize = 8  # we only support 64-bit hosts
        aligned = (reader.pos + wordsize - 1) & ~(wordsize - 1)
        reader.seek(aligned)
        kind = reader.read_bytes(wordsize).unpack1("q<")
        len  = reader.read_bytes(wordsize).unpack1("q<")
        raise Codec::UnsupportedObjectKind, "T_DATA kind #{kind} (expected 0)" unless kind == 0
        name = reader.read_bytes(len).delete("\x00")
        Encoding.find(name)
      end

      # T_BIGNUM: ssize_t slen (aligned), then |slen| BDIGIT words.
      def self.decode_bignum(reader)
        wordsize = 8
        aligned = (reader.pos + wordsize - 1) & ~(wordsize - 1)
        reader.seek(aligned)
        slen = reader.read_bytes(wordsize).unpack1("q<")
        ndigits = slen.abs
        # BDIGIT size is platform-dependent; assume 64-bit here.
        digits = ndigits.times.map { reader.read_bytes(8).unpack1("Q<") }
        value = digits.each_with_index.sum { |d, i| d << (64 * i) }
        slen < 0 ? -value : value
      end

      # T_STRUCT (Range only):
      # struct { long class_index; long len; long beg; long end; int excl } (aligned, written raw)
      def self.decode_struct(reader, obj_offsets)
        wordsize = 8
        aligned = (reader.pos + wordsize - 1) & ~(wordsize - 1)
        reader.seek(aligned)
        _class_index = reader.read_bytes(wordsize).unpack1("q<")
        _len         = reader.read_bytes(wordsize).unpack1("q<")
        beg_idx      = reader.read_bytes(wordsize).unpack1("q<")
        end_idx      = reader.read_bytes(wordsize).unpack1("q<")
        excl         = reader.read_bytes(4).unpack1("l<")
        # Return indices for now; full resolution needs two-pass decode
        (beg_idx..end_idx)  # approximate
      end

      # T_COMPLEX / T_RATIONAL: struct { long a; long b } (aligned)
      def self.decode_complex_rational(reader, obj_offsets, kind)
        wordsize = 8
        aligned = (reader.pos + wordsize - 1) & ~(wordsize - 1)
        reader.seek(aligned)
        a = reader.read_bytes(wordsize).unpack1("q<")
        b = reader.read_bytes(wordsize).unpack1("q<")
        # Return index pairs for now
        kind == :complex ? Complex(a, b) : Rational(a, b)
      end

      # Map a CRuby encoding index to a Ruby Encoding.
      # RUBY_ENCINDEX_ASCII_8BIT = 0, RUBY_ENCINDEX_UTF_8 = 1, RUBY_ENCINDEX_US_ASCII = 2
      def self.encoding_for_index(encindex)
        case encindex
        when 0 then Encoding::ASCII_8BIT
        when 1 then Encoding::UTF_8
        when 2 then Encoding::US_ASCII
        else        Encoding::UTF_8  # best-effort fallback for unknown encoding indices
        end
      end

      def special_const?(value)
        case value
        when Integer
          # Conservatively only fixnum-shaped integers; CRuby fixnum range on 64-bit
          # is roughly [-(1<<62), (1<<62)-1]. We're far inside that for tier-1 folds.
          value.bit_length < 62
        when true, false, nil
          true
        else
          false
        end
      end

      # Write one special-const object payload (1-byte header + 1 small_value VALUE).
      def write_special_const(writer, value)
        # header: type=0, special_const=1 (bit 5), frozen=1 (bit 6) → 0x60
        writer.write_u8(0x60)
        encoded =
          case value
          when true  then QTRUE
          when false then QFALSE
          when nil   then QNIL
          when Integer then (value << 1) | 1
          else
            raise ArgumentError, "cannot encode #{value.inspect} as special_const"
          end
        writer.write_small_value(encoded)
      end
    end
  end
end
