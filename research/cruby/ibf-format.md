# IBF (Instruction Binary Format) Reference Notes

**CRuby tag consulted:** `v4.0.2`
**Primary source:** `compile.c` lines 12480–15010
**Empirically verified against:** Ruby 4.0.2 sandbox

---

## 1. Header Layout (`struct ibf_header`, compile.c:12507)

The file begins with a fixed-size header written directly as a C struct (`ibf_dump_write(dump, &header, sizeof(header))`). All multi-byte integers are **native endian** (little-endian on x86-64); the `endian` field records which.

```
Offset  Size  Type        Field
------  ----  ----------  ----------------------------------------
     0     4  char[4]     magic — always b"YARB"
     4     4  uint32_t    major_version — IBF_MAJOR_VERSION = ruby_api_version[0] (4 for Ruby 4.0.2)
     8     4  uint32_t    minor_version — IBF_MINOR_VERSION = ruby_api_version[1] (0 for Ruby 4.0.2)
    12     4  uint32_t    size — total byte length of the binary up to (not including) extra_data
    16     4  uint32_t    extra_size — byte length of optional extra payload appended after size
    20     4  uint32_t    iseq_list_size — number of iseq records
    24     4  uint32_t    global_object_list_size — number of entries in the global object table
    28     4  uint32_t    iseq_list_offset — byte offset of the iseq offset array
    32     4  uint32_t    global_object_list_offset — byte offset of the object offset array
    36     1  uint8_t     endian — 'l' (0x6c) for little-endian, 'b' for big-endian
    37     1  uint8_t     wordsize — sizeof(VALUE), e.g. 8 on 64-bit platforms
    38     2  (padding)   implicit C struct padding to align to 4 bytes; always zero
```

Total header size: 40 bytes (38 bytes of defined fields + 2 bytes compiler padding).

**Empirical check:** `RubyVM::InstructionSequence.compile("1+2").to_binary` produces 180 bytes with
major=4, minor=0, size=180, wordsize=8, endian='l', iseq_list_size=1, global_object_list_size=4,
iseq_list_offset=132, global_object_list_offset=164.

`IBF_MAJOR_VERSION` and `IBF_MINOR_VERSION` are defined in terms of `ISEQ_MAJOR_VERSION` / `ISEQ_MINOR_VERSION` (iseq.h:19-20), which resolve to `ruby_api_version[0]` and `[1]` respectively. On development builds (`RUBY_DEVEL`), `IBF_MINOR_VERSION = ISEQ_MINOR_VERSION * 10000 + 5` (compile.c:12493-12494).

---

## 2. Section Ordering

```
[0]     Header (40 bytes)
[40]    Iseq data region — interleaved bytecode, tables, and body records for all iseqs
        (each iseq written by ibf_dump_iseq_each; body record written last per iseq)
[X]     Iseq offset array — iseq_list_size × uint32_t, 4-byte aligned
        (pointed to by header.iseq_list_offset)
[Y]     Object data region — per-object payloads (symbols, strings, floats, etc.)
[Z]     Object offset array — global_object_list_size × uint32_t, 4-byte aligned
        (pointed to by header.global_object_list_offset)
[W]     Optional extra data — header.extra_size bytes; present only if caller passed opt
```

Both offset arrays are aligned to `sizeof(ibf_offset_t)` = 4 bytes before being written
(`ibf_dump_align(dump, sizeof(ibf_offset_t))`). All offsets in these arrays are absolute byte
offsets within the binary.

**Object index 0 is always `nil`** — it is pre-inserted into the object table at dump setup
(`ibf_dump_object_table_new`, compile.c:12740) so operands that reference nil use index 0 and never
appear in the object data region.

---

## 3. Object Table

### 3.1 Object Header (1 byte, compile.c:14011–14016, 14509–14518)

Every object in the data region begins with exactly one packed byte:

```
Bit(s)  Field          Description
------  -------------  ----------------------------------------
 4:0    type           Ruby T_ type constant (T_STRING=5, T_FLOAT=4, etc.)
   5    special_const  1 if SPECIAL_CONST_P(obj) (Fixnum, true, false, nil, Symbol flonum)
   6    frozen         1 if OBJ_FROZEN(obj)
   7    internal       1 if class pointer is 0 (hidden/internal object)
```

If `special_const == 1`, the body is a single **small_value** (see §5) encoding the raw Ruby VALUE
(the integer representation of nil/true/false/Fixnum/flonum/Symbol). Otherwise, the body is
type-specific (see below).

### 3.2 Per-Type Encodings

All lengths and indices in object bodies use **small_value** encoding (§5) unless noted.

**T_STRING (type=5)** — `ibf_dump_object_string` / `ibf_load_object_string` (compile.c:14171)
```
small_value  encindex   — encoding index; if > RUBY_ENCINDEX_BUILTIN_MAX, it is
                          BUILTIN_MAX + object_index_of_enc_name_string
small_value  len        — byte length of string content
byte[len]    content    — raw string bytes (no NUL)
```

**T_SYMBOL (type=20=0x14)** — `ibf_dump_object_symbol` (compile.c:14449)
Same layout as T_STRING (delegates to `ibf_dump_object_string` on the symbol's string representation).

**T_FLOAT (type=4)** — `ibf_dump_object_float` (compile.c:14153)
```
8 bytes (double, native byte order, alignment-padded)
```
The body is aligned to `RUBY_ALIGNOF(double)` before writing.

**T_ARRAY (type=7)** — `ibf_dump_object_array` (compile.c:14244)
```
small_value  len          — number of elements
small_value  elem[0..len) — object-table index of each element
```

**T_HASH (type=8)** — `ibf_dump_object_hash` (compile.c:14291)
```
small_value  len         — number of key-value pairs
(small_value key_idx, small_value val_idx) × len
```

**T_STRUCT (Range only) (type=9)** — `ibf_dump_object_struct` (compile.c:14325)
```
struct ibf_object_struct_range {   (aligned to RUBY_ALIGNOF, written raw)
    long  class_index;   — always 0 for Range
    long  len;           — always 3
    long  beg;           — object-table index of range begin
    long  end;           — object-table index of range end
    int   excl;          — 1 if exclusive (...)
}
```
Other Struct subclasses raise `NotImplementedError`.

**T_BIGNUM (type=10)** — `ibf_dump_object_bignum` (compile.c:14360)
```
ssize_t  slen      — +len if positive, -len if negative (aligned)
BDIGIT   digits[]  — slen.abs digit words, least-significant word first
```

**T_REGEXP (type=6)** — `ibf_dump_object_regexp` (compile.c:14216)
```
byte         option   — Regexp options byte (rb_reg_options)
small_value  srcstr   — object-table index of the source string
```

**T_CLASS (type=2)** — `ibf_dump_object_class` (compile.c:14099)
```
small_value  cindex   — enum ibf_object_class_index value:
                        0=Object, 1=Array, 2=StandardError,
                        3=NoMatchingPatternError, 4=TypeError,
                        5=NoMatchingPatternKeyError
```
Only a fixed set of classes is supported; anything else raises `rb_bug`.

**T_DATA (type=12)** — `ibf_dump_object_data` (compile.c:14388)
Only encoding objects are supported (`IBF_OBJECT_DATA_ENCODING = 0`):
```
long[2]  {IBF_OBJECT_DATA_ENCODING, len}   (aligned)
char[len]  encoding name with NUL terminator
```

**T_COMPLEX / T_RATIONAL (types=14,15)** — `ibf_dump_object_complex_rational` (compile.c:14425)
```
struct ibf_object_complex_rational {  (aligned)
    long  a;   — object-table index of real/numerator
    long  b;   — object-table index of imag/denominator
}
```
Type in header distinguishes Complex from Rational.

**Fixnum / true / false / nil** — encoded as `special_const=1` objects: header byte followed by
one small_value holding the raw Ruby VALUE integer.

---

## 4. Per-Iseq Record Layout

Each iseq is serialized by `ibf_dump_iseq_each` (compile.c:13591). Data sections are written first,
then the **body record** — a sequential stream of **small_values** — is written last. The iseq list
stores the absolute offset of the body record, not the start of bytecode.

### 4.1 Data Sections (written before body, offsets stored in body)

| Section                  | Writer function                    | Notes |
|--------------------------|------------------------------------|-------|
| bytecode                 | `ibf_dump_code`                    | variable-length small_value stream |
| param opt table          | `ibf_dump_param_opt_table`         | VALUE[] array, VALUE-aligned |
| param keyword            | `ibf_dump_param_keyword`           | struct + ID[] + VALUE[], 0 if absent |
| insns_info body          | `ibf_dump_insns_info_body`         | per-insn: (line_no, [node_id,] events) |
| insns_info positions     | `ibf_dump_insns_info_positions`    | delta-encoded uint positions |
| local table              | `ibf_dump_local_table`             | ID[] (object-table indices), ID-aligned |
| lvar states              | `ibf_dump_lvar_states`             | enum lvar_state[], state-aligned |
| catch table              | `ibf_dump_catch_table`             | per-entry: iseq_idx, type, start, end, cont, sp |
| call info (ci) entries   | `ibf_dump_ci_entries`              | per-cd: mid_idx, flag, argc, kwlen, kw_indices |
| outer variables          | `ibf_dump_outer_variables`         | count, then (id_idx, value) pairs |

### 4.2 Body Record (small_value stream, compile.c:13666–13711)

Fields are read back in the same order by `ibf_load_iseq_each` (compile.c:13778–13824).

```
Field                          Notes
-----------------------------  --------------------------------------------------
type                           iseq type (ISEQ_TYPE_* enum)
iseq_size                      number of VALUE slots in the decoded insn array
bytecode_offset                body_offset - bytecode_start (relative)
bytecode_size                  byte length of encoded bytecode stream
param_flags                    14-bit packed field (see §4.3)
param.size
param.lead_num
param.opt_num
param.rest_start
param.post_start
param.post_num
param.block_start
param_opt_table_offset         relative offset
param_keyword_offset           absolute offset (0 = no keyword params)
location_pathobj_index         object-table index (String or [path,realpath] Array)
location_base_label_index      object-table index (String)
location_label_index           object-table index (String)
location.first_lineno
location.node_id
location.code_location.beg_pos.lineno
location.code_location.beg_pos.column
location.code_location.end_pos.lineno
location.code_location.end_pos.column
insns_info_body_offset         relative offset
insns_info_positions_offset    relative offset
insns_info.size
local_table_offset             relative offset
lvar_states_offset             relative offset
catch_table_size               0 = no catch table
catch_table_offset             relative offset
parent_iseq_index              iseq-list index (-1 = none)
local_iseq_index               iseq-list index
mandatory_only_iseq_index      iseq-list index (-1 = none)
ci_entries_offset              relative offset
outer_variables_offset         relative offset
variable.flip_count
local_table_size
ivc_size                       inline variable cache count
icvarc_size                    inline class-variable ref cache count
ise_size                       inline storage entry count
ic_size                        inline constant cache count
ci_size                        call info count
stack_max
builtin_attrs
prism                          1 if compiled from Prism AST, else 0
```

Relative offsets are stored as `body_offset - actual_offset` (i.e. a backward distance from the
body record), so loading is: `actual_offset = body_offset - stored_value`.

### 4.3 param_flags bit-packing (compile.c:13644–13658)

```
Bit  Flag
---  ---------------
  0  has_lead
  1  has_opt
  2  has_rest
  3  has_post
  4  has_kw
  5  has_kwrest
  6  has_block
  7  ambiguous_param0
  8  accepts_no_kwarg
  9  ruby2_keywords
 10  anon_rest
 11  anon_kwrest
 12  use_block
 13  forwardable
```

### 4.4 Catch Table Entry (compile.c:13367–13373)

Each entry in the catch table is 6 small_values written in this order:
```
iseq_index  — iseq-list index of the handler iseq; stored as full uint64 max (0xFFFF…FF,
               9-byte small_value) when there is no associated iseq (C sentinel: -1)
type        — rb_catch_type enum value (see below)
start       — YARV slot index (start of guarded range, inclusive)
end         — YARV slot index (end of guarded range, exclusive)
cont        — YARV slot index (continuation point; always present, may be slot 0)
sp          — operand-stack depth at the catch point
```

**rb_catch_type enum values** are stored as Ruby Fixnums (`INT2FIX(n)` = `(n << 1) | 1`):
```
Raw value  Enum constant        Symbol
---------  -------------------  ------
        3  CATCH_TYPE_RESCUE    :rescue
        5  CATCH_TYPE_ENSURE    :ensure
        7  CATCH_TYPE_RETRY     :retry
        9  CATCH_TYPE_BREAK     :break
       11  CATCH_TYPE_REDO      :redo
       13  CATCH_TYPE_NEXT      :next
```
(Verified empirically against Ruby 4.0.2 binaries — the iseq.h enum uses `INT2FIX(1..6)`.)

**No-iseq sentinel:** stored as a 9-byte small_value encoding `0xFFFFFFFFFFFFFFFF` (uint64 max,
i.e. C `-1` cast to `ibf_offset_t`). The 4-byte sentinel 0xFFFFFFFF is **not** used here.

**YARV slot indices** in start/end/cont are absolute slot numbers in the decoded VALUE array
(same coordinate system as `slot_to_insn_idx` built during instruction stream decode). They are
NOT byte offsets.

---

## 5. Instruction Stream Encoding

The bytecode stream is encoded by `ibf_dump_code` / `ibf_load_code` (compile.c:12903, 12976).
It is a flat byte stream of small_values with no padding or alignment.

For each instruction:
1. **Opcode** — one small_value (opcode < 0x100 enforced at dump; Ruby 4.0.2 empirically: `putobject`=19=0x13, `leave`=70=0x46)
2. **Operands** — one value per operand type character from `insn_op_types(insn)`:

| Type token  | Encoding in IBF                                      |
|-------------|------------------------------------------------------|
| `TS_VALUE`  | small_value → object-table index                     |
| `TS_CDHASH` | small_value → object-table index (frozen Hash)       |
| `TS_ISEQ`   | small_value → iseq-list index (-1 = nil)             |
| `TS_IC`     | small_value → object-table index of ID Array         |
| `TS_ISE`    | small_value → inline-storage entry index             |
| `TS_IVC`    | small_value → inline-storage entry index             |
| `TS_ICVARC` | small_value → inline-storage entry index             |
| `TS_CALLDATA`| *nothing written* — slot assigned from cd_entries at load |
| `TS_ID`     | small_value → object-table index of Symbol (0 = ID 0) |
| `TS_BUILTIN`| small_value(index) + small_value(name_len) + name bytes |
| `TS_FUNCPTR`| raises RuntimeError — not supported in IBF           |
| default     | small_value → raw operand VALUE                      |

---

## 6. Small_Value Encoding (compile.c:12796–12865)

A variable-length unsigned integer encoding. The number of bytes is signaled by the trailing zero
bits in the first byte:

```
Pattern of first byte  Bytes  Max value
---------------------  -----  ---------------------------
XXXXXXX1               1      0x7f (127)
XXXXXX10               2      0x3fff
XXXXX100               3      0x1fffff
XXXX1000               4      0x0fffffff
XXX10000               5      0x7ffffffff (approx)
...
00000000               9      full uint64
```

Decoding: `n = trailing_zeros_of_first_byte + 1` (9 bytes if first byte is 0x00).
Value = first_byte >> n, then for each subsequent byte i in [1..n): `value = (value << 8) | byte[i]`.

---

## 7. Endianness and Alignment

- **Byte order:** Host native. Recorded in header byte `endian` ('l' = little-endian, 'b' = big-endian). Load raises if endian does not match the loading host (compile.c:14904).
- **Word size:** `sizeof(VALUE)` (8 on 64-bit). Load raises if `header.wordsize != SIZEOF_VALUE` (compile.c:14907).
- **Alignment:** Before writing any typed struct or array, the encoder calls `ibf_dump_align(dump, RUBY_ALIGNOF(type))` via the `IBF_W_ALIGN(type)` macro (compile.c:12695). Object bodies use `IBF_OBJBODY(type, offset)` which aligns the offset before reading (compile.c:14062). The iseq list array and global object list array are each aligned to `sizeof(ibf_offset_t)` = 4 bytes. The small_value stream itself has no alignment requirements.

---

## 8. Version Compatibility

`ibf_load_setup_bytes` (compile.c:14877) raises `RuntimeError` if any of these checks fail:

1. `header.magic != "YARB"` → "unknown binary format"
2. `header.major_version != IBF_MAJOR_VERSION || header.minor_version != IBF_MINOR_VERSION` → "unmatched version file"
3. `header.endian != IBF_ENDIAN_MARK` → "unmatched endian"
4. `header.wordsize != SIZEOF_VALUE` → "unmatched word size"
5. `header.iseq_list_offset % RUBY_ALIGNOF(ibf_offset_t) != 0` → "unaligned iseq list offset"
6. `header.global_object_list_offset % RUBY_ALIGNOF(ibf_offset_t) != 0` → "unaligned object list offset"

Versions are checked for **exact equality** — there is no backward-compatibility window. A binary
compiled with Ruby 4.0.2 will not load in Ruby 4.0.1 or any future version unless the api version
numbers happen to match. This is by design: the format is an internal cache, not a stable ABI.

---

## 9. Fields Requiring Clarification

- **`IBF_ISEQ_ENABLE_LOCAL_BUFFER`**: defaulting to 0 in Ruby 4.0.2. When 1, each iseq carries its
  own local object table and the iseq-list entry format changes (three additional small_values:
  `iseq_start`, `iseq_length_bytes`, `body_offset` plus `local_obj_list_offset`/`size`). The
  non-local-buffer path (default) is documented above.
- **`node_id` in insns_info**: conditionally compiled with `USE_ISEQ_NODE_ID`; present in Ruby 4.0.2
  release builds but technically platform-dependent. Each insns_info entry is
  (line_no, node_id, events) when enabled.
- **insns_info serialization — two sections**: CRuby splits insns_info into two separate data
  sections (not one):
  - **body** (`insns_info_body_offset_rel`): `N × (line_no, node_id, events)` — each field is an
    absolute small_value (no delta encoding on line_no or node_id).
  - **positions** (`insns_info_positions_offset_rel`): `N × pos_delta` — delta-encoded YARV slot
    positions. The first delta is relative to 0; each subsequent delta is relative to the previous
    entry's slot position. All deltas are non-negative (positions are strictly non-decreasing).
  - Body section always precedes positions section in the data region (empirically verified for
    Ruby 4.0.2). The two sections are adjacent: `insns_body_abs + 3*N_bytes == insns_pos_abs`.
  - **Adjust entries**: CRuby occasionally emits insns_info entries whose slot position falls
    inside an instruction's operand VALUE slots (not at the instruction's own opcode slot). These
    are "adjust" entries emitted by `add_adjust_info`. The slot position is still a valid YARV slot
    index but does not correspond to any instruction's first slot. Empirically observed in
    `invokeblock` (opcode 69, `[:CALLDATA, :NUM]`, 3 YARV slots): an adjust entry can point to
    the NUM operand slot (offset +2 from the opcode slot). The decoder must handle these by mapping
    to the containing instruction plus an intra-instruction offset.
  - **No signed values**: neither line_no deltas nor node_id values use CRuby's signed small_value
    encoding in practice. line_no and node_id are stored as raw absolute unsigned small_values.
    (The sketch in the implementation plan suggesting signed deltas for line_no is incorrect.)
- **BDIGIT size**: platform-dependent (32 or 64 bits). Bignum round-trips correctly only between
  same-BDIGIT builds; no explicit BDIGIT size is recorded in the header.
