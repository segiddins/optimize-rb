# frozen_string_literal: true
require "open3"
require "tempfile"
require "optimize/demo"

module Optimize
  module Demo
    module Benchmark
      Result = Struct.new(:stdout, :plain_ips, :optimized_ips, keyword_init: true)
      Report = Struct.new(:label, :ips, :raw, keyword_init: true)

      LIB_DIR = File.expand_path("../..", __dir__) # optimizer/lib

      module_function

      def compare(fixture_path:, entry_setup:, entry_call:, warmup: 2, time: 5)
        plain     = run_one(label: "plain",     with_harness: false,
                            fixture_path: fixture_path,
                            entry_setup: entry_setup, entry_call: entry_call,
                            warmup: warmup, time: time)
        optimized = run_one(label: "optimized", with_harness: true,
                            fixture_path: fixture_path,
                            entry_setup: entry_setup, entry_call: entry_call,
                            warmup: warmup, time: time)

        Result.new(
          stdout: compose(plain, optimized),
          plain_ips: plain.ips,
          optimized_ips: optimized.ips,
        )
      end

      def run_one(label:, with_harness:, fixture_path:, entry_setup:, entry_call:, warmup:, time:)
        script = build_script(
          label: label, with_harness: with_harness,
          fixture_path: fixture_path,
          entry_setup: entry_setup, entry_call: entry_call,
          warmup: warmup, time: time,
        )
        Tempfile.create(["demo_bench_#{label}", ".rb"]) do |f|
          f.write(script)
          f.flush
          stdout, status = Open3.capture2e(RbConfig.ruby, "-I", LIB_DIR, f.path)
          raise "benchmark subprocess (#{label}) failed:\n#{stdout}" unless status.success?
          ips_line = stdout.lines.grep(/\AIPS_RESULT:/).last
          raise "IPS_RESULT not found in subprocess output:\n#{stdout}" unless ips_line
          ips = ips_line.strip.split[2].to_f
          Report.new(label: label, ips: ips, raw: stdout.sub(/^IPS_RESULT:.*\n/, ""))
        end
      end

      def build_script(label:, with_harness:, fixture_path:, entry_setup:, entry_call:, warmup:, time:)
        preamble = with_harness ? <<~HARNESS : ""
          require "optimize/harness"
          require "optimize/pipeline"
          hook = Optimize::Harness::LoadIseqHook.new(passes: Optimize::Pipeline.default.passes)
          hook.install
        HARNESS

        <<~SCRIPT
          # frozen_string_literal: true
          require "bundler/setup"
          $LOAD_PATH.unshift(#{LIB_DIR.inspect})
          require "benchmark/ips"
          #{preamble}
          require #{fixture_path.inspect}
          #{entry_setup}
          $stdout.sync = true
          _job = ::Benchmark.ips do |x|
            x.config(warmup: #{warmup}, time: #{time}, quiet: false)
            x.report(#{label.inspect}) { #{entry_call} }
          end
          _entry = _job.entries.last
          printf("IPS_RESULT: %s %.6f\\n", #{label.inspect}, _entry.ips)
        SCRIPT
      end

      def compose(plain, optimized)
        ratio = [plain.ips, optimized.ips].max / [plain.ips, optimized.ips].min
        # Always emit `plain` before `optimized` so demo:verify's per-line
        # BENCH_LINE_RE mask produces byte-identical output across runs —
        # which one wins is data-dependent, but the block layout is not.
        # The slower line carries the ratio suffix.
        plain_line = "  #{plain.label}:   #{format('%.1f', plain.ips)} i/s"
        opt_line   = "  #{optimized.label}:   #{format('%.1f', optimized.ips)} i/s"
        suffix     = " - #{format('%.2f', ratio)}x  slower"
        if plain.ips <= optimized.ips
          plain_line += suffix
        else
          opt_line += suffix
        end
        <<~OUT
          #{plain.raw.rstrip}
          #{optimized.raw.rstrip}
          Comparison:
          #{plain_line}
          #{opt_line}
        OUT
      end
    end
  end
end
