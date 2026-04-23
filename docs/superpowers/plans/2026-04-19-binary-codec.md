# Binary Codec Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a round-trippable decoder/encoder for the YARB ("Instruction Binary Format") output of `RubyVM::InstructionSequence#to_binary`, so the optimizer can modify iseqs and hand them back to `load_from_binary`.

**Architecture:** A single isolated module at `optimizer/lib/optimize/codec/` exposing `Codec.decode(String) -> IR::Function` and `Codec.encode(IR::Function) -> String`. Validated primarily by an identity round-trip: for any `to_binary` output, `encode(decode(bin))` produces a byte-identical result.

**Tech Stack:** Ruby 4.0.2, minitest, prism (already in experiments Gemfile). Codec is pure Ruby, reads and writes the packed binary format directly.

**Scope bounds:** This plan delivers the codec and a minimal IR shape (Function, BasicBlock stub, Instruction) sufficient for round-tripping. The CFG construction, type env, contract, and pipeline live in the next plan. The passes come later.

**Commit discipline:** Every commit step below is written as `jj commit -m "<msg>"` for readability. Executors MUST translate this to `jj split -m "<msg>" -- <files>` using the exact file list from the task's Files section. This keeps commits surgical and prevents parallel/subagent work from stomping unrelated changes in the working copy.

---

## File structure

```
optimizer/
  Gemfile                         # created in Task 1
  Rakefile                        # created in Task 1
  lib/
    optimize.rb                   # top-level require
    optimize/
      codec.rb                    # public API: Codec.decode / Codec.encode
      codec/
        binary_reader.rb          # primitive byte reader
        binary_writer.rb          # primitive byte writer
        header.rb                 # YARB header struct + decode/encode
        object_table.rb           # literals / object table
        iseq_envelope.rb          # per-iseq metadata
        instruction_stream.rb     # instruction operands
      ir/
        function.rb               # IR Function (wraps one iseq)
        instruction.rb            # single YARV op + operands
  test/
    test_helper.rb
    codec/
      round_trip_test.rb          # identity round-trip, the core contract
      corpus_test.rb              # larger zoo of compiled snippets
      binary_reader_test.rb
      binary_writer_test.rb
research/
  cruby/
    ibf-format.md                 # produced in Task 2
```

**Working directory convention:** all commands below run from `optimizer/` unless stated otherwise. When a step says "run the test," it means `bundle exec rake test TEST=<path>`.

---

### Task 1: Scaffold the `optimizer/` project

**Files:**
- Create: `optimizer/Gemfile`
- Create: `optimizer/Rakefile`
- Create: `optimizer/lib/optimize.rb`
- Create: `optimizer/test/test_helper.rb`
- Create: `optimizer/.ruby-version`

- [ ] **Step 1: Create `.ruby-version`**

```
4.0.2
```

- [ ] **Step 2: Create `Gemfile`**

```ruby
# frozen_string_literal: true
source "https://rubygems.org"
ruby "4.0.2"

gem "prism", "~> 1.2"

group :development do
  gem "debug", "~> 1.9"
  gem "minitest", "~> 5.25"
  gem "rake", "~> 13.2"
end
```

- [ ] **Step 3: Create `Rakefile`**

```ruby
# frozen_string_literal: true
require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "lib" << "test"
  t.pattern = "test/**/*_test.rb"
  t.warning = false
end

task default: :test
```

- [ ] **Step 4: Create `lib/optimize.rb`**

```ruby
# frozen_string_literal: true

module Optimize
  VERSION = "0.0.0"
end
```

- [ ] **Step 5: Create `test/test_helper.rb`**

```ruby
# frozen_string_literal: true
require "minitest/autorun"
require "optimize"
```

- [ ] **Step 6: Install and verify**

Run: `cd optimizer && bundle install && bundle exec rake test`
Expected: `0 runs, 0 assertions, 0 failures, 0 errors, 0 skips`

- [ ] **Step 7: Commit**

```bash
jj commit -m "Scaffold optimizer project"
```

---

### Task 2: Produce IBF format notes from CRuby source

**Files:**
- Create: `research/cruby/ibf-format.md`

Purpose: Before writing decoder/encoder code, build a reference. CRuby's `compile.c` contains the IBF (Instruction Binary Format) dump/load implementation. Key functions:

- `ibf_dump_object`, `ibf_load_object` — object table entries
- `ibf_dump_iseq`, `ibf_load_iseq_each` — per-iseq data
- `struct ibf_header` — file header
- `rb_iseq_ibf_dump`, `rb_iseq_ibf_load` — top-level entry points

Source location (Ruby 4.0.2): https://github.com/ruby/ruby/blob/v4_0_2/compile.c (or the closest tag).

- [ ] **Step 1: Write `research/cruby/ibf-format.md`**

The document must cover:

1. Header layout (magic `YARB`, version bytes, major/minor, size, number of iseqs, object table offset, global object table)
2. Section ordering in the binary
3. Object table entry format — which Ruby types are encodable (`Symbol`, `String`, `Integer`, `Float`, `Array`, `Hash`, `Class`, `Regexp`, etc.) and the per-type layout
4. Per-iseq record layout — header fields (type, name, path, args spec, local table, catch table, line info, parent iseq ref)
5. Instruction stream encoding — how opcodes and operands are packed; handling of operand types (lindex, voffset, ISE, ID, VALUE, etc.)
6. Endianness and alignment rules
7. Version compatibility — what changes between Ruby minors, why `RUBY_PLATFORM` appears in the header

Format: prose + byte-level diagrams. Cross-reference specific CRuby function names and line numbers. Aim for 500–1000 words.

- [ ] **Step 2: Commit**

```bash
jj commit -m "Add IBF format reference notes"
```

---

### Task 3: Byte primitives (`BinaryReader`, `BinaryWriter`)

**Files:**
- Create: `optimizer/lib/optimize/codec/binary_reader.rb`
- Create: `optimizer/lib/optimize/codec/binary_writer.rb`
- Test: `optimizer/test/codec/binary_reader_test.rb`
- Test: `optimizer/test/codec/binary_writer_test.rb`

Interface:

```ruby
# BinaryReader wraps a String, tracks a position, exposes:
#   #read_u8, #read_u16, #read_u32, #read_u64    (little-endian)
#   #read_bytes(n)                               (raw bytes)
#   #read_cstr                                   (null-terminated)
#   #seek(offset), #pos
#
# BinaryWriter accumulates a buffer and mirrors those as write_*.
```

- [ ] **Step 1: Write `BinaryReader` failing tests**

```ruby
# test/codec/binary_reader_test.rb
require "test_helper"
require "optimize/codec/binary_reader"

class BinaryReaderTest < Minitest::Test
  def test_read_u32_little_endian
    reader = Optimize::Codec::BinaryReader.new("\x04\x00\x00\x00".b)
    assert_equal 4, reader.read_u32
    assert_equal 4, reader.pos
  end

  def test_read_bytes
    reader = Optimize::Codec::BinaryReader.new("YARB".b)
    assert_equal "YARB".b, reader.read_bytes(4)
  end

  def test_seek_and_peek
    reader = Optimize::Codec::BinaryReader.new("\x00\x01\x02\x03".b)
    reader.seek(2)
    assert_equal 2, reader.read_u8
  end

  def test_reads_past_end_raise
    reader = Optimize::Codec::BinaryReader.new("\x00".b)
    reader.read_u8
    assert_raises(RangeError) { reader.read_u8 }
  end
end
```

- [ ] **Step 2: Run, expect failure**

Run: `bundle exec rake test TEST=test/codec/binary_reader_test.rb`
Expected: LoadError for `optimize/codec/binary_reader`.

- [ ] **Step 3: Implement `BinaryReader`**

```ruby
# lib/optimize/codec/binary_reader.rb
# frozen_string_literal: true

module Optimize
  module Codec
    class BinaryReader
      attr_reader :pos

      def initialize(buffer)
        @buffer = buffer.b
        @pos = 0
      end

      def read_u8  = read_int(1, "C")
      def read_u16 = read_int(2, "v")
      def read_u32 = read_int(4, "V")
      def read_u64 = read_int(8, "Q<")

      def read_bytes(n)
        raise RangeError, "read past end" if @pos + n > @buffer.bytesize
        bytes = @buffer.byteslice(@pos, n)
        @pos += n
        bytes
      end

      def read_cstr
        nul = @buffer.index("\x00".b, @pos)
        raise RangeError, "unterminated cstr" unless nul
        s = @buffer.byteslice(@pos, nul - @pos)
        @pos = nul + 1
        s
      end

      def seek(offset)
        raise RangeError if offset.negative? || offset > @buffer.bytesize
        @pos = offset
      end

      private

      def read_int(n, directive)
        read_bytes(n).unpack1(directive)
      end
    end
  end
end
```

- [ ] **Step 4: Run, expect pass**

Run: `bundle exec rake test TEST=test/codec/binary_reader_test.rb`
Expected: 4 runs, all pass.

- [ ] **Step 5: Write mirror tests for `BinaryWriter`**

```ruby
# test/codec/binary_writer_test.rb
require "test_helper"
require "optimize/codec/binary_writer"

class BinaryWriterTest < Minitest::Test
  def test_write_u32_little_endian
    writer = Optimize::Codec::BinaryWriter.new
    writer.write_u32(4)
    assert_equal "\x04\x00\x00\x00".b, writer.buffer
  end

  def test_write_bytes
    writer = Optimize::Codec::BinaryWriter.new
    writer.write_bytes("YARB".b)
    assert_equal "YARB".b, writer.buffer
  end

  def test_write_cstr
    writer = Optimize::Codec::BinaryWriter.new
    writer.write_cstr("hi")
    assert_equal "hi\x00".b, writer.buffer
  end

  def test_round_trip_with_reader
    writer = Optimize::Codec::BinaryWriter.new
    writer.write_u32(0xdeadbeef)
    writer.write_bytes("YARB".b)
    writer.write_cstr("hello")

    reader = Optimize::Codec::BinaryReader.new(writer.buffer)
    assert_equal 0xdeadbeef, reader.read_u32
    assert_equal "YARB".b, reader.read_bytes(4)
    assert_equal "hello".b, reader.read_cstr
  end
end
```

- [ ] **Step 6: Implement `BinaryWriter`**

```ruby
# lib/optimize/codec/binary_writer.rb
# frozen_string_literal: true

module Optimize
  module Codec
    class BinaryWriter
      def initialize
        @buffer = String.new(encoding: Encoding::ASCII_8BIT)
      end

      def buffer = @buffer

      def write_u8(v)  = write_int(v, "C")
      def write_u16(v) = write_int(v, "v")
      def write_u32(v) = write_int(v, "V")
      def write_u64(v) = write_int(v, "Q<")

      def write_bytes(bytes) = @buffer << bytes.b
      def write_cstr(s)      = @buffer << s.b << "\x00".b

      def pos = @buffer.bytesize

      private

      def write_int(v, directive)
        @buffer << [v].pack(directive)
      end
    end
  end
end
```

- [ ] **Step 7: Run both test files, expect pass**

Run: `bundle exec rake test`
Expected: all tests pass.

- [ ] **Step 8: Commit**

```bash
jj commit -m "Add binary reader/writer primitives"
```

---

### Task 4: Identity round-trip harness

**Files:**
- Create: `optimizer/test/codec/round_trip_test.rb`
- Create: `optimizer/lib/optimize/codec.rb` (stub)

Purpose: Set up the core contract test *before* the decoder/encoder exist. This test will initially fail (decoder not implemented), and we'll unfail it piece by piece.

- [ ] **Step 1: Write the stub for the public API**

```ruby
# lib/optimize/codec.rb
# frozen_string_literal: true
require "optimize/codec/binary_reader"
require "optimize/codec/binary_writer"

module Optimize
  module Codec
    # Decodes a YARB binary blob (from RubyVM::InstructionSequence#to_binary)
    # into an IR::Function.
    def self.decode(binary)
      raise NotImplementedError
    end

    # Encodes an IR::Function back into YARB binary form accepted by
    # RubyVM::InstructionSequence.load_from_binary.
    def self.encode(ir)
      raise NotImplementedError
    end
  end
end
```

- [ ] **Step 2: Write the round-trip test**

```ruby
# test/codec/round_trip_test.rb
require "test_helper"
require "optimize/codec"

class RoundTripTest < Minitest::Test
  # The core contract: encode(decode(bin)) == bin, for unmodified iseqs.
  # Each example is a Ruby snippet that #compile can handle.

  EXAMPLES = [
    "1 + 2",
    "def hi; 1 + 2; end",
    "def add(a, b); a + b; end",
    "class Point; def initialize(x,y); @x=x; @y=y; end; end",
    "[1,2,3].map { |n| n * 2 }",
  ]

  EXAMPLES.each_with_index do |src, i|
    define_method(:"test_identity_#{i}_#{src[0,20].gsub(/\W+/,'_')}") do
      original = RubyVM::InstructionSequence.compile(src).to_binary
      ir = Optimize::Codec.decode(original)
      re_encoded = Optimize::Codec.encode(ir)
      assert_equal original, re_encoded,
        "round-trip mismatch for #{src.inspect}"
    end

    define_method(:"test_executable_#{i}_#{src[0,20].gsub(/\W+/,'_')}") do
      original = RubyVM::InstructionSequence.compile(src).to_binary
      ir = Optimize::Codec.decode(original)
      re_encoded = Optimize::Codec.encode(ir)
      # The VM must accept it and running must not raise
      loaded = RubyVM::InstructionSequence.load_from_binary(re_encoded)
      assert_kind_of RubyVM::InstructionSequence, loaded
      loaded.eval
    end
  end
end
```

- [ ] **Step 3: Run, expect NotImplementedError failures across the board**

Run: `bundle exec rake test TEST=test/codec/round_trip_test.rb`
Expected: 10 failures, all raising `NotImplementedError`.

- [ ] **Step 4: Commit**

```bash
jj commit -m "Add identity round-trip test harness for codec"
```

---

### Task 5: Decode + encode the YARB header

**Files:**
- Create: `optimizer/lib/optimize/codec/header.rb`
- Modify: `optimizer/lib/optimize/codec.rb`
- Test: covered by round-trip test (header-only slice)

Purpose: First real section of the format. The header is fixed-layout; sections below it are offset-indexed from here. Per `research/cruby/ibf-format.md` (produced in Task 2), the header contains:

- Magic (`YARB`, 4 bytes)
- Version major / minor (4 bytes each, from `RUBY_API_VERSION_MAJOR`/`MINOR`)
- Platform string (from `RUBY_PLATFORM`)
- Various offset/size fields for downstream sections

- [ ] **Step 1: Write a header-only decode/encode test**

```ruby
# In test/codec/round_trip_test.rb, add:
def test_header_round_trip
  original = RubyVM::InstructionSequence.compile("1 + 2").to_binary
  reader = Optimize::Codec::BinaryReader.new(original)
  header = Optimize::Codec::Header.decode(reader)

  assert_equal "YARB", header.magic
  refute_nil header.major_version
  refute_nil header.platform

  writer = Optimize::Codec::BinaryWriter.new
  header.encode(writer)
  # Header section must reproduce its original bytes
  header_len = reader.pos
  assert_equal original.byteslice(0, header_len), writer.buffer
end
```

- [ ] **Step 2: Run, expect NameError for `Codec::Header`**

- [ ] **Step 3: Implement `Header` per the format notes**

Structure (fill in byte-level details from `research/cruby/ibf-format.md`):

```ruby
# lib/optimize/codec/header.rb
# frozen_string_literal: true

module Optimize
  module Codec
    Header = Struct.new(
      :magic, :major_version, :minor_version, :size,
      :extra_size, :iseq_list_size, :global_object_list_size,
      :iseq_list_offset, :global_object_list_offset, :platform,
      keyword_init: true
    ) do
      def self.decode(reader)
        # Per research/cruby/ibf-format.md, the header is a fixed-size
        # struct. Engineer fills in the exact field order and sizes
        # using the reference doc.
        raise NotImplementedError, "implement using research/cruby/ibf-format.md"
      end

      def encode(writer)
        raise NotImplementedError, "implement using research/cruby/ibf-format.md"
      end
    end
  end
end
```

Note: the `raise NotImplementedError` placeholders are there because the exact byte layout must come from the research doc. The engineer replaces each with the concrete sequence of `reader.read_u32`/`writer.write_u32` calls specified in the notes.

- [ ] **Step 4: Iterate: fill in decode/encode using format notes, run header round-trip test until it passes**

Expected end state: `test_header_round_trip` passes.

- [ ] **Step 5: Commit**

```bash
jj commit -m "Implement YARB header decode/encode"
```

---

### Task 6: Decode + encode the object table

**Files:**
- Create: `optimizer/lib/optimize/codec/object_table.rb`

Purpose: The object table holds all literals (strings, symbols, integers, floats, arrays, hashes, ranges, classes, regexps) referenced by instructions. Instructions carry indices into this table, not objects directly.

- [ ] **Step 1: Extend the round-trip test with an object-table section check**

```ruby
def test_object_table_round_trip
  original = RubyVM::InstructionSequence.compile(
    '[1, "two", :three, 4.5, /six/]'
  ).to_binary
  reader = Optimize::Codec::BinaryReader.new(original)
  header = Optimize::Codec::Header.decode(reader)
  table = Optimize::Codec::ObjectTable.decode(reader, header)

  # Table should contain literals seen in the snippet
  assert_includes table.objects, 1
  assert_includes table.objects, "two"
  assert_includes table.objects, :three
  assert_includes table.objects, 4.5

  writer = Optimize::Codec::BinaryWriter.new
  header.encode(writer)
  table.encode(writer, header)
  table_end = reader.pos
  assert_equal original.byteslice(0, table_end), writer.buffer
end
```

- [ ] **Step 2: Implement `ObjectTable` per the format notes**

```ruby
# lib/optimize/codec/object_table.rb
# frozen_string_literal: true

module Optimize
  module Codec
    class ObjectTable
      attr_reader :objects

      def initialize(objects)
        @objects = objects
      end

      # Object kinds from CRuby's ibf_object_kind_* enum. Engineer
      # fills the full set from research/cruby/ibf-format.md.
      KINDS = {
        # string:  0,
        # symbol:  1,
        # fixnum:  2,
        # ...
      }.freeze

      def self.decode(reader, header)
        raise NotImplementedError
      end

      def encode(writer, header)
        raise NotImplementedError
      end
    end
  end
end
```

- [ ] **Step 3: Iterate until the object-table test passes.**

Strategy: implement one object kind at a time (string → symbol → fixnum → float → array → …). Add a focused test per kind before implementing it.

- [ ] **Step 4: Commit**

```bash
jj commit -m "Implement YARB object table decode/encode"
```

---

### Task 7: Decode + encode the per-iseq envelope

**Files:**
- Create: `optimizer/lib/optimize/codec/iseq_envelope.rb`
- Create: `optimizer/lib/optimize/ir/function.rb`

Purpose: Each iseq is a record with its name, path, arg spec, local variable table, catch table, line-number info, a reference to instructions, and references to nested (block/method) iseqs. The instructions themselves are decoded in Task 8; this task handles the envelope.

- [ ] **Step 1: Define `IR::Function` as the decoded form**

```ruby
# lib/optimize/ir/function.rb
# frozen_string_literal: true

module Optimize
  module IR
    # One decoded iseq. Field names mirror the envelope fields
    # described in research/cruby/ibf-format.md.
    Function = Struct.new(
      :name, :path, :absolute_path, :first_lineno, :type,
      :arg_spec, :local_table, :catch_table, :line_info,
      :instructions,     # filled in Task 8
      :children,         # Array<Function>, for nested iseqs
      :misc,             # any leftover metadata for round-trip
      keyword_init: true
    )
  end
end
```

- [ ] **Step 2: Write an envelope round-trip test**

```ruby
def test_iseq_envelope_round_trip
  src = "def hi(name, times: 1); times.times { puts name }; end"
  original = RubyVM::InstructionSequence.compile(src).to_binary
  ir = Optimize::Codec.decode(original)

  # Outer Function has a child for `hi`, which has a child for the block.
  hi = ir.children.find { |f| f.name == "hi" }
  refute_nil hi
  block = hi.children.find { |f| f.type == :block }
  refute_nil block

  re_encoded = Optimize::Codec.encode(ir)
  assert_equal original, re_encoded
end
```

(This test depends on Task 8 for full round-trip; mark as skip until Task 8 completes, or run the envelope-only pieces inline.)

- [ ] **Step 3: Implement `IseqEnvelope` using the format notes**

```ruby
# lib/optimize/codec/iseq_envelope.rb
# frozen_string_literal: true

module Optimize
  module Codec
    module IseqEnvelope
      def self.decode(reader, header, object_table)
        raise NotImplementedError
      end

      def self.encode(writer, function, header, object_table)
        raise NotImplementedError
      end
    end
  end
end
```

- [ ] **Step 4: Iterate field-by-field: name/path first, then arg_spec, local_table, catch_table, line_info.**

- [ ] **Step 5: Wire `Codec.decode` to call Header → ObjectTable → envelopes for each iseq; `Codec.encode` to mirror.**

```ruby
# In codec.rb:
def self.decode(binary)
  reader = BinaryReader.new(binary)
  header = Header.decode(reader)
  object_table = ObjectTable.decode(reader, header)
  iseq_list = decode_iseq_list(reader, header, object_table)
  build_root_function(iseq_list, header)
end
```

(Engineer fills in `decode_iseq_list` and `build_root_function` following the format notes.)

- [ ] **Step 6: Commit**

```bash
jj commit -m "Decode/encode per-iseq envelope"
```

---

### Task 8: Decode + encode the instruction stream

**Files:**
- Create: `optimizer/lib/optimize/codec/instruction_stream.rb`
- Create: `optimizer/lib/optimize/ir/instruction.rb`

Purpose: Each iseq carries a packed instruction stream. Decoding means turning bytes into a list of `IR::Instruction`; encoding mirrors.

- [ ] **Step 1: Define `IR::Instruction`**

```ruby
# lib/optimize/ir/instruction.rb
# frozen_string_literal: true

module Optimize
  module IR
    # One YARV instruction after decoding. Operands are Ruby values,
    # not object-table indices — the codec resolves indices on
    # decode and re-interns them on encode.
    Instruction = Struct.new(:opcode, :operands, :line, keyword_init: true) do
      def to_s
        "#{opcode} #{operands.inspect}"
      end
    end
  end
end
```

- [ ] **Step 2: Write a decode-side test**

```ruby
def test_instruction_stream_decode_shape
  src = "def add(a, b); a + b; end"
  ir = Optimize::Codec.decode(
    RubyVM::InstructionSequence.compile(src).to_binary
  )
  add = ir.children.find { |f| f.name == "add" }
  opcodes = add.instructions.map(&:opcode)
  assert_includes opcodes, :getlocal_WC_0
  assert_includes opcodes, :opt_plus
  assert_includes opcodes, :leave
end
```

- [ ] **Step 3: Implement `InstructionStream` using the insn table**

```ruby
# lib/optimize/codec/instruction_stream.rb
# frozen_string_literal: true

module Optimize
  module Codec
    module InstructionStream
      # Maps opcode number -> [name_sym, operand_type_list].
      # Source: the CRuby insns.def file for Ruby 4.0.2. The engineer
      # builds this table in research/cruby/ibf-format.md (or a sibling
      # file) and references it here.
      INSN_TABLE = {
        # 0 => [:nop, []],
        # ...
      }.freeze

      def self.decode(reader, header, object_table)
        raise NotImplementedError
      end

      def self.encode(writer, instructions, header, object_table)
        raise NotImplementedError
      end
    end
  end
end
```

- [ ] **Step 4: Iterate opcode-by-opcode until the round-trip tests from Task 4 all pass.**

Strategy: the full round-trip test suite from Task 4 will guide which opcodes need coverage first. Start with opcodes that appear in the simplest snippets (`putobject`, `leave`, `opt_plus`, `opt_send_without_block`, `getlocal_WC_0`, `setlocal_WC_0`, `pop`, `duparray`, `newhash`, `newarray`).

- [ ] **Step 5: Verify all Task-4 round-trip tests pass**

Run: `bundle exec rake test TEST=test/codec/round_trip_test.rb`
Expected: all 10+ tests pass.

- [ ] **Step 6: Commit**

```bash
jj commit -m "Decode/encode YARV instruction stream"
```

---

### Task 9: Corpus round-trip test

**Files:**
- Create: `optimizer/test/codec/corpus_test.rb`
- Create: `optimizer/test/codec/corpus/` directory with snippet fixtures

Purpose: A larger zoo of realistic iseqs — catches format edges the hand-picked snippets miss.

- [ ] **Step 1: Add snippet fixtures**

Create files under `test/codec/corpus/` with representative Ruby snippets. Examples:

- `simple_method.rb`: `def hi; 1; end`
- `block_with_yield.rb`: `def each; yield 1; yield 2; end`
- `class_with_ivars.rb`: a small class definition
- `string_ops.rb`: `"hi" + "there"; "%s" % "x"`
- `array_literal.rb`: `[1, 2, [3, 4], {a: 1}]`
- `regexp_literal.rb`: `"abc".match(/b/)`
- `rescue_block.rb`: `begin; raise; rescue; end` (catch table exercise)
- `nested_blocks.rb`: `[1].each { |a| [2].each { |b| a + b } }`
- `keyword_args.rb`: `def k(a:, b: 2); a + b; end`

- [ ] **Step 2: Write the corpus test**

```ruby
# test/codec/corpus_test.rb
require "test_helper"
require "optimize/codec"

class CorpusTest < Minitest::Test
  Dir[File.join(__dir__, "corpus", "*.rb")].each do |path|
    name = File.basename(path, ".rb")
    define_method(:"test_corpus_#{name}") do
      source = File.read(path)
      original = RubyVM::InstructionSequence.compile(source, path).to_binary
      ir = Optimize::Codec.decode(original)
      re_encoded = Optimize::Codec.encode(ir)
      assert_equal original, re_encoded, "mismatch for #{name}"
      # Must also still run
      RubyVM::InstructionSequence.load_from_binary(re_encoded).eval
    end
  end
end
```

- [ ] **Step 3: Run; fix codec gaps exposed**

Expect some failures on first run; each failure names a snippet and points at an unhandled opcode or object kind. Add handlers and iterate.

- [ ] **Step 4: Commit**

```bash
jj commit -m "Add corpus round-trip tests for codec"
```

---

### Task 10: Fail loudly on unsupported constructs

**Files:**
- Modify: `optimizer/lib/optimize/codec/instruction_stream.rb`
- Modify: `optimizer/lib/optimize/codec/object_table.rb`
- Test: add to `corpus_test.rb`

Purpose: An unknown opcode or object kind must raise a clearly named exception, not silently miscompile. This is the codec's failure mode. The harness (next plan) will catch it and fall back to the original iseq unchanged.

- [ ] **Step 1: Define exception types**

```ruby
# In lib/optimize/codec.rb, add:
module Optimize
  module Codec
    class UnsupportedOpcode < StandardError; end
    class UnsupportedObjectKind < StandardError; end
    class MalformedBinary < StandardError; end
  end
end
```

- [ ] **Step 2: Wire the decoders to raise these**

In `InstructionStream.decode`, when `INSN_TABLE[op_num]` is missing:

```ruby
raise UnsupportedOpcode, "unknown opcode #{op_num} at offset #{reader.pos}"
```

Similarly for `ObjectTable.decode` on unknown kinds.

- [ ] **Step 3: Test the failure path**

```ruby
def test_malformed_binary_raises
  assert_raises(Optimize::Codec::MalformedBinary) do
    Optimize::Codec.decode("NOTYARB!".b)
  end
end
```

(Header decode should reject non-`YARB` magic with `MalformedBinary`.)

- [ ] **Step 4: Run tests, expect pass**

- [ ] **Step 5: Commit**

```bash
jj commit -m "Add explicit errors for unsupported codec constructs"
```

---

### Task 11: Smoke test — compile → decode → encode → load → eval

**Files:**
- Create: `optimizer/test/codec/smoke_test.rb`

Purpose: End-to-end check that what we produce is actually loadable and runnable, beyond just byte-equal.

- [ ] **Step 1: Write the smoke test**

```ruby
# test/codec/smoke_test.rb
require "test_helper"
require "optimize/codec"

class CodecSmokeTest < Minitest::Test
  def test_decode_encode_execute
    src = <<~RUBY
      def add(a, b); a + b; end
      def greet(name); "hello, \#{name}"; end
      add(2, 3) + greet("world").length
    RUBY
    original = RubyVM::InstructionSequence.compile(src).to_binary
    ir = Optimize::Codec.decode(original)
    re_encoded = Optimize::Codec.encode(ir)

    loaded = RubyVM::InstructionSequence.load_from_binary(re_encoded)
    result = loaded.eval
    # add(2,3) == 5, "hello, world".length == 12, total == 17
    assert_equal 17, result
  end
end
```

- [ ] **Step 2: Run; if it fails, the failure points at a semantic regression the byte-equal test didn't catch**

- [ ] **Step 3: Commit**

```bash
jj commit -m "Add end-to-end codec smoke test"
```

---

### Task 12: Clean up and document

**Files:**
- Create: `optimizer/README.md`
- Modify: `optimizer/lib/optimize/codec.rb` (docstring)

- [ ] **Step 1: Write `optimizer/README.md`**

```markdown
# optimizer

Talk-artifact Ruby optimizer. Companion to
`docs/superpowers/specs/2026-04-19-optimizer.md`.

## Status

- Binary codec: round-trippable decoder/encoder for YARB binaries
- IR: minimal (Function + Instruction)
- Everything else: to come

## Running tests

    bundle install
    bundle exec rake test

## Layout

- `lib/optimize/codec/` — YARB binary surgery
- `lib/optimize/ir/` — iseq IR
- `test/codec/` — round-trip and corpus tests
```

- [ ] **Step 2: Add module-level docstring to `codec.rb` summarizing the API**

- [ ] **Step 3: Run the full test suite one more time**

Run: `bundle exec rake test`
Expected: all pass.

- [ ] **Step 4: Commit**

```bash
jj commit -m "Document codec status and API"
```

---

## Self-review check

Run through the spec (`docs/superpowers/specs/2026-04-19-optimizer.md`, round-trip section) and confirm:

1. The codec is isolated to one module — ✓ (`lib/optimize/codec/`)
2. Identity round-trip is the primary contract — ✓ (Task 4, reinforced in Task 9)
3. Version-gated, fails loudly on mismatch — ✓ (Task 5 checks magic, Task 10 defines errors)
4. Preserves iseq metadata — ✓ (Task 7 envelope + Task 8 instructions)
5. Not-round-trippable iseqs fail loudly — ✓ (Task 10)

Gaps to call out:

- Nothing in this plan covers `stack_max` recomputation — by design, no transformations run here, so `stack_max` is preserved as-is from the original. The next plan (IR + pipeline) handles this.
- The CFG is not built yet — `IR::Function#instructions` is a flat list. CFG construction also lives in the next plan.
