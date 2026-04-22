# frozen_string_literal: true
require "open3"
require "tempfile"
require "ruby_opt/demo"

module RubyOpt
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
          require "ruby_opt/harness"
          require "ruby_opt/pipeline"
          hook = RubyOpt::Harness::LoadIseqHook.new(passes: RubyOpt::Pipeline.default.passes)
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
        faster, slower = [plain, optimized].sort_by(&:ips).reverse
        ratio = faster.ips / slower.ips
        <<~OUT
          #{plain.raw.rstrip}
          #{optimized.raw.rstrip}
          Comparison:
            #{faster.label}:   #{format('%.1f', faster.ips)} i/s
            #{slower.label}:   #{format('%.1f', slower.ips)} i/s - #{format('%.2f', ratio)}x  slower
        OUT
      end
    end
  end
end
