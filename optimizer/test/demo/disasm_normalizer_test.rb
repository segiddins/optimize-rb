# frozen_string_literal: true
require "test_helper"
require "optimize/demo/disasm_normalizer"

class DisasmNormalizerTest < Minitest::Test
  def test_strips_header_block
    raw = <<~DISASM
      == disasm: #<ISeq:<main>@/tmp/x.rb:1 (1,0)-(3,3)>
      local table (size: 0, argc: 0 [opts: 0, rest: -1, post: 0, block: -1, kw: -1@-1, kwrest: -1])
      0000 putobject_INT2FIX_1_                                          (   1)[Li]
      0001 leave
    DISASM
    normalized = Optimize::Demo::DisasmNormalizer.normalize(raw)
    refute_match(/disasm:/, normalized)
    refute_match(/local table/, normalized)
    assert_match(/putobject_INT2FIX_1_/, normalized)
    assert_match(/leave/, normalized)
  end

  def test_strips_pc_column
    raw = <<~DISASM
      == disasm: #<ISeq:foo>
      0000 putobject_INT2FIX_1_
      0001 leave
    DISASM
    normalized = Optimize::Demo::DisasmNormalizer.normalize(raw)
    refute_match(/^\d{4}\s/, normalized)
    assert_match(/putobject_INT2FIX_1_/, normalized)
  end

  def test_strips_trailing_location_annotations
    raw = <<~DISASM
      == disasm: #<ISeq:foo>
      0000 putobject_INT2FIX_1_                                          (   1)[Li]
      0001 leave                                                         (   2)[Li]
    DISASM
    normalized = Optimize::Demo::DisasmNormalizer.normalize(raw)
    refute_match(/\(\s*\d+\)\[/, normalized)
  end

  def test_handles_child_iseq_dumps
    raw = <<~DISASM
      == disasm: #<ISeq:outer>
      0000 leave
      == disasm: #<ISeq:inner@block>
      0000 leave
    DISASM
    normalized = Optimize::Demo::DisasmNormalizer.normalize(raw)
    assert_match(/== block: inner@block/, normalized)
  end
end
