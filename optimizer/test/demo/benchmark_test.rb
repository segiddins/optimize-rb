# frozen_string_literal: true
require "test_helper"
require "optimize/demo/benchmark"
require "tmpdir"

class DemoBenchmarkTest < Minitest::Test
  FIXTURE = <<~RUBY
    # frozen_string_literal: true
    def noop; 1; end
  RUBY

  def with_fixture
    Dir.mktmpdir do |dir|
      path = File.join(dir, "fx.rb")
      File.write(path, FIXTURE)
      yield path
    end
  end

  def test_compose_emits_plain_then_optimized_regardless_of_which_is_faster
    # demo:verify uses BENCH_LINE_RE to mask the ips values, but the mask
    # is per-line and cannot reconcile reordered lines. compose must emit
    # `plain` before `optimized` in the Comparison block so the masked
    # output is byte-identical across runs.
    # Optimized faster than plain: current compose would put optimized first.
    plain = Optimize::Demo::Benchmark::Report.new(label: "plain", ips: 500.0, raw: "")
    opt   = Optimize::Demo::Benchmark::Report.new(label: "optimized", ips: 1000.0, raw: "")
    out = Optimize::Demo::Benchmark.compose(plain, opt)
    block = out[/Comparison:.*\z/m]
    plain_at = block.index("plain:")
    opt_at   = block.index("optimized:")
    refute_nil plain_at, "Comparison block missing `plain:` line"
    refute_nil opt_at, "Comparison block missing `optimized:` line"
    assert plain_at < opt_at,
      "expected `plain` before `optimized` even when plain is faster, got:\n#{block}"
  end

  def test_compare_runs_both_labels_and_captures_output
    with_fixture do |path|
      result = Optimize::Demo::Benchmark.compare(
        fixture_path: path,
        entry_setup: "",
        entry_call: "noop",
        warmup: 0.1,
        time: 0.2,
      )
      assert_kind_of String, result.stdout
      assert_match(/plain/, result.stdout)
      assert_match(/optimized/, result.stdout)
      assert_match(/Comparison:/, result.stdout)
      assert_kind_of Float, result.plain_ips
      assert_kind_of Float, result.optimized_ips
      assert result.plain_ips > 0.0
      assert result.optimized_ips > 0.0
    end
  end
end
