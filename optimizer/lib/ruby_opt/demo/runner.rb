# frozen_string_literal: true
require "ruby_opt/demo"
require "ruby_opt/demo/walkthrough"
require "ruby_opt/demo/iseq_snapshots"
require "ruby_opt/demo/benchmark"
require "ruby_opt/demo/markdown_renderer"

module RubyOpt
  module Demo
    module Runner
      module_function

      def run(sidecar_path:, output_dir:, bench_warmup: 2, bench_time: 5)
        wt = Walkthrough.load(sidecar_path)
        stem = File.basename(sidecar_path, ".walkthrough.yml")
        source = File.read(wt.fixture_path)

        snapshots = IseqSnapshots.generate(
          fixture_path: wt.fixture_path,
          walkthrough: wt.walkthrough,
        )
        bench = Benchmark.compare(
          fixture_path: wt.fixture_path,
          entry_setup: wt.entry_setup,
          entry_call: wt.entry_call,
          warmup: bench_warmup,
          time: bench_time,
        )
        md = MarkdownRenderer.render(
          stem: stem,
          source: source,
          walkthrough: wt.walkthrough,
          snapshots: snapshots,
          bench: bench,
        )
        out_path = File.join(output_dir, "#{stem}.md")
        File.write(out_path, md)
        out_path
      end
    end
  end
end
