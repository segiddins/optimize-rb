# frozen_string_literal: true
require "test_helper"
require "ruby_opt/demo/markdown_renderer"
require "ruby_opt/demo/iseq_snapshots"
require "ruby_opt/demo/benchmark"

class MarkdownRendererTest < Minitest::Test
  def build_snapshots(per_pass)
    RubyOpt::Demo::IseqSnapshots::Result.new(
      before: "0000 putobject_INT2FIX_1_\n0001 leave\n",
      after_full: "0000 putobject_INT2FIX_2_\n0001 leave\n",
      per_pass: per_pass,
    )
  end

  def build_bench
    RubyOpt::Demo::Benchmark::Result.new(
      stdout: "plain raw\noptimized raw\nComparison:\n  optimized: 2.0x  faster\n",
      plain_ips: 100.0,
      optimized_ips: 200.0,
    )
  end

  def test_renders_all_five_sections
    snaps = build_snapshots({
      const_fold: "0000 putobject_INT2FIX_2_\n0001 leave\n",
    })
    md = RubyOpt::Demo::MarkdownRenderer.render(
      stem: "x",
      source: "def f; 1 + 1; end\n",
      walkthrough: [:const_fold],
      snapshots: snaps,
      bench: build_bench,
    )
    assert_match(/^# x demo/, md)
    assert_match(/^## Source/, md)
    assert_match(/^## Full-delta summary/, md)
    assert_match(/^## Walkthrough/, md)
    assert_match(/^### `const_fold`/, md)
    assert_match(/^## Appendix: full iseq dumps/, md)
    assert_match(/^## Raw benchmark output/, md)
  end

  def test_walkthrough_diffs_are_unified_format
    snaps = build_snapshots({
      const_fold: "0000 putobject_INT2FIX_2_\n0001 leave\n",
    })
    md = RubyOpt::Demo::MarkdownRenderer.render(
      stem: "x", source: "def f; 1 + 1; end\n",
      walkthrough: [:const_fold],
      snapshots: snaps,
      bench: build_bench,
    )
    assert_match(/^-.*INT2FIX_1_/, md)
    assert_match(/^\+.*INT2FIX_2_/, md)
  end

  def test_benchmark_headline_cites_ratio
    snaps = build_snapshots({})
    md = RubyOpt::Demo::MarkdownRenderer.render(
      stem: "x", source: "def f; 1; end\n",
      walkthrough: [],
      snapshots: snaps,
      bench: build_bench,
    )
    assert_match(/2\.00x/, md)
  end
end
