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
