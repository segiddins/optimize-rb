# Demo Programs Wired with Benchmark Harness — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a `bin/demo` driver that produces committed slide-ready
markdown artifacts (per-pass iseq diffs + `benchmark-ips` numbers) for
the two talk fixtures `point_distance` and `sum_of_squares`.

**Architecture:** Offline-only driver script reads a YAML sidecar
declaring which passes to walk through for each fixture, re-parses the
fixture through a `Pipeline` prefix per walkthrough entry to snapshot
iseq text, runs `benchmark-ips` via a subprocess wrapper (harness-off
vs `Pipeline.default`), and renders a single markdown file per fixture
into `docs/demo_artifacts/`.

**Tech Stack:** Ruby 4.0, `RubyVM::InstructionSequence`, existing
`RubyOpt::Pipeline` / `Codec` / `TypeEnv` / `Harness`, `benchmark-ips`
gem, `diff-lcs` gem, `psych` (stdlib YAML), Minitest.

**Spec:** `docs/superpowers/specs/2026-04-22-demo-programs-benchmark-harness-design.md`

---

## File Structure

**Create:**
- `optimizer/lib/ruby_opt/demo.rb` — namespace shim
- `optimizer/lib/ruby_opt/demo/walkthrough.rb` — YAML sidecar loader + validator
- `optimizer/lib/ruby_opt/demo/disasm_normalizer.rb` — strips PC columns and headers from disasm text
- `optimizer/lib/ruby_opt/demo/iseq_snapshots.rb` — compiles a fixture through Pipeline prefixes and returns disasm strings
- `optimizer/lib/ruby_opt/demo/benchmark.rb` — benchmark-ips subprocess wrapper
- `optimizer/lib/ruby_opt/demo/markdown_renderer.rb` — assembles the five-section artifact
- `optimizer/lib/ruby_opt/demo/runner.rb` — top-level orchestration per fixture
- `optimizer/bin/demo` — CLI entry point (executable)
- `optimizer/examples/sum_of_squares.rb`
- `optimizer/examples/point_distance.walkthrough.yml`
- `optimizer/examples/sum_of_squares.walkthrough.yml`
- `optimizer/test/demo/walkthrough_test.rb`
- `optimizer/test/demo/disasm_normalizer_test.rb`
- `optimizer/test/demo/iseq_snapshots_test.rb`
- `optimizer/test/demo/benchmark_test.rb`
- `optimizer/test/demo/markdown_renderer_test.rb`
- `optimizer/test/demo/runner_test.rb`
- `optimizer/test/demo/sidecar_validation_test.rb`
- `docs/demo_artifacts/point_distance.md` (generated, committed)
- `docs/demo_artifacts/sum_of_squares.md` (generated, committed)

**Modify:**
- `optimizer/Gemfile` — add `diff-lcs`, `benchmark-ips`
- `optimizer/Gemfile.lock` — regenerate
- `optimizer/lib/ruby_opt/pipeline.rb` — expose `attr_reader :passes`
- `optimizer/examples/point_distance.rb` — strip trailing driver loop
- `optimizer/Rakefile` — add `demo:verify` task
- `docs/todo.md` — strike the shipped item

---

### Task 1: Add gem dependencies

**Files:**
- Modify: `optimizer/Gemfile`
- Modify: `optimizer/Gemfile.lock`

- [ ] **Step 1: Add gems to Gemfile**

Edit `optimizer/Gemfile`:

```ruby
# frozen_string_literal: true
source "https://rubygems.org"
ruby "4.0.2"

gem "prism", "~> 1.2"
gem "benchmark-ips", "~> 2.14"
gem "diff-lcs", "~> 1.5"

group :development do
  gem "debug", "~> 1.9"
  gem "minitest", "~> 5.25"
  gem "rake", "~> 13.2"
end
```

- [ ] **Step 2: Install and lock**

Run:
```
cd optimizer && bundle install
```
Expected: `Gemfile.lock` updated with both gems.

- [ ] **Step 3: Verify both load**

Run:
```
cd optimizer && bundle exec ruby -e 'require "benchmark/ips"; require "diff/lcs"; puts "ok"'
```
Expected: `ok`.

- [ ] **Step 4: Commit**

```
jj commit -m "build: add benchmark-ips and diff-lcs for demo driver"
```

---

### Task 2: Expose Pipeline#passes

**Files:**
- Modify: `optimizer/lib/ruby_opt/pipeline.rb:35-37`
- Test: `optimizer/test/pipeline_test.rb`

The demo driver needs `Pipeline.default.passes.map(&:name)` to validate
walkthrough YAML entries.

- [ ] **Step 1: Write the failing test**

Append to `optimizer/test/pipeline_test.rb` (add a new
`PipelineAccessorTest < Minitest::Test` class at the bottom):

```ruby
class PipelineAccessorTest < Minitest::Test
  def test_passes_accessor_returns_configured_passes
    passes = [Object.new, Object.new]
    pipeline = RubyOpt::Pipeline.new(passes)
    assert_equal passes, pipeline.passes
  end

  def test_default_pipeline_pass_names_are_symbols
    names = RubyOpt::Pipeline.default.passes.map(&:name)
    assert(names.all? { |n| n.is_a?(Symbol) })
    assert_includes names, :inlining
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```
cd optimizer && bundle exec rake test TEST=test/pipeline_test.rb
```
Expected: FAIL with `NoMethodError: undefined method 'passes'`.

- [ ] **Step 3: Add the accessor**

Edit `optimizer/lib/ruby_opt/pipeline.rb`, change:
```ruby
    def initialize(passes)
      @passes = passes
    end
```
to:
```ruby
    attr_reader :passes

    def initialize(passes)
      @passes = passes
    end
```

- [ ] **Step 4: Run test to verify it passes**

Run:
```
cd optimizer && bundle exec rake test TEST=test/pipeline_test.rb
```
Expected: PASS.

- [ ] **Step 5: Commit**

```
jj commit -m "feat: Pipeline exposes #passes for demo driver validation"
```

---

### Task 3: Walkthrough YAML loader

**Files:**
- Create: `optimizer/lib/ruby_opt/demo.rb`
- Create: `optimizer/lib/ruby_opt/demo/walkthrough.rb`
- Test: `optimizer/test/demo/walkthrough_test.rb`

- [ ] **Step 1: Write the failing test**

Create `optimizer/test/demo/walkthrough_test.rb`:

```ruby
# frozen_string_literal: true
require "test_helper"
require "ruby_opt/demo/walkthrough"
require "tmpdir"

class WalkthroughTest < Minitest::Test
  def with_yaml(body)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "x.walkthrough.yml")
      File.write(path, body)
      yield path, dir
    end
  end

  def test_loads_valid_sidecar
    body = <<~YAML
      fixture: x.rb
      entry_setup: "a = 1"
      entry_call: "a + 1"
      walkthrough:
        - const_fold
        - dead_branch_fold
    YAML
    with_yaml(body) do |path, _dir|
      wt = RubyOpt::Demo::Walkthrough.load(path)
      assert_equal "x.rb", wt.fixture
      assert_equal "a = 1", wt.entry_setup
      assert_equal "a + 1", wt.entry_call
      assert_equal %i[const_fold dead_branch_fold], wt.walkthrough
    end
  end

  def test_rejects_unknown_pass_name
    body = <<~YAML
      fixture: x.rb
      entry_setup: ""
      entry_call: "1"
      walkthrough:
        - no_such_pass
    YAML
    with_yaml(body) do |path, _dir|
      err = assert_raises(RubyOpt::Demo::Walkthrough::InvalidSidecar) do
        RubyOpt::Demo::Walkthrough.load(path)
      end
      assert_match(/no_such_pass/, err.message)
    end
  end

  def test_fixture_path_resolves_relative_to_sidecar
    body = <<~YAML
      fixture: x.rb
      entry_setup: ""
      entry_call: "1"
      walkthrough: [const_fold]
    YAML
    with_yaml(body) do |path, dir|
      wt = RubyOpt::Demo::Walkthrough.load(path)
      assert_equal File.join(dir, "x.rb"), wt.fixture_path
    end
  end

  def test_missing_field_raises
    body = <<~YAML
      fixture: x.rb
      entry_call: "1"
      walkthrough: [const_fold]
    YAML
    with_yaml(body) do |path, _dir|
      assert_raises(RubyOpt::Demo::Walkthrough::InvalidSidecar) do
        RubyOpt::Demo::Walkthrough.load(path)
      end
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```
cd optimizer && bundle exec rake test TEST=test/demo/walkthrough_test.rb
```
Expected: FAIL with `cannot load such file`.

- [ ] **Step 3: Create namespace shim**

Create `optimizer/lib/ruby_opt/demo.rb`:

```ruby
# frozen_string_literal: true

module RubyOpt
  module Demo
  end
end
```

- [ ] **Step 4: Implement Walkthrough**

Create `optimizer/lib/ruby_opt/demo/walkthrough.rb`:

```ruby
# frozen_string_literal: true
require "psych"
require "ruby_opt/demo"
require "ruby_opt/pipeline"

module RubyOpt
  module Demo
    class Walkthrough
      class InvalidSidecar < StandardError; end

      REQUIRED_FIELDS = %w[fixture entry_setup entry_call walkthrough].freeze

      attr_reader :fixture, :entry_setup, :entry_call, :walkthrough, :sidecar_path

      def self.load(path)
        data = Psych.safe_load_file(path, permitted_classes: [])
        raise InvalidSidecar, "sidecar is not a mapping: #{path}" unless data.is_a?(Hash)

        missing = REQUIRED_FIELDS - data.keys
        raise InvalidSidecar, "missing fields #{missing.inspect} in #{path}" unless missing.empty?

        wt_names = Array(data["walkthrough"]).map(&:to_sym)
        valid = Pipeline.default.passes.map(&:name)
        unknown = wt_names - valid
        unless unknown.empty?
          raise InvalidSidecar,
                "unknown pass name(s) in #{path}: #{unknown.inspect}; valid: #{valid.inspect}"
        end

        new(
          sidecar_path: path,
          fixture: data["fixture"],
          entry_setup: data["entry_setup"].to_s,
          entry_call: data["entry_call"],
          walkthrough: wt_names,
        )
      end

      def initialize(sidecar_path:, fixture:, entry_setup:, entry_call:, walkthrough:)
        @sidecar_path = sidecar_path
        @fixture = fixture
        @entry_setup = entry_setup
        @entry_call = entry_call
        @walkthrough = walkthrough
      end

      def fixture_path
        File.expand_path(@fixture, File.dirname(@sidecar_path))
      end
    end
  end
end
```

- [ ] **Step 5: Run test to verify it passes**

Run:
```
cd optimizer && bundle exec rake test TEST=test/demo/walkthrough_test.rb
```
Expected: PASS (4 tests).

- [ ] **Step 6: Commit**

```
jj commit -m "feat(demo): Walkthrough loads and validates sidecar YAML"
```

---

### Task 4: Disasm normalizer

**Files:**
- Create: `optimizer/lib/ruby_opt/demo/disasm_normalizer.rb`
- Test: `optimizer/test/demo/disasm_normalizer_test.rb`

Strips the iseq header block, the PC column, and trailing source-line
annotations from disasm text so that per-pass diffs show opcode
changes only.

- [ ] **Step 1: Write the failing test**

Create `optimizer/test/demo/disasm_normalizer_test.rb`:

```ruby
# frozen_string_literal: true
require "test_helper"
require "ruby_opt/demo/disasm_normalizer"

class DisasmNormalizerTest < Minitest::Test
  def test_strips_header_block
    raw = <<~DISASM
      == disasm: #<ISeq:<main>@/tmp/x.rb:1 (1,0)-(3,3)>
      local table (size: 0, argc: 0 [opts: 0, rest: -1, post: 0, block: -1, kw: -1@-1, kwrest: -1])
      0000 putobject_INT2FIX_1_                                          (   1)[Li]
      0001 leave
    DISASM
    normalized = RubyOpt::Demo::DisasmNormalizer.normalize(raw)
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
    normalized = RubyOpt::Demo::DisasmNormalizer.normalize(raw)
    refute_match(/^\d{4}\s/, normalized)
    assert_match(/putobject_INT2FIX_1_/, normalized)
  end

  def test_strips_trailing_location_annotations
    raw = <<~DISASM
      == disasm: #<ISeq:foo>
      0000 putobject_INT2FIX_1_                                          (   1)[Li]
      0001 leave                                                         (   2)[Li]
    DISASM
    normalized = RubyOpt::Demo::DisasmNormalizer.normalize(raw)
    refute_match(/\(\s*\d+\)\[/, normalized)
  end

  def test_handles_child_iseq_dumps
    raw = <<~DISASM
      == disasm: #<ISeq:outer>
      0000 leave
      == disasm: #<ISeq:inner@block>
      0000 leave
    DISASM
    normalized = RubyOpt::Demo::DisasmNormalizer.normalize(raw)
    assert_match(/== block: inner@block/, normalized)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```
cd optimizer && bundle exec rake test TEST=test/demo/disasm_normalizer_test.rb
```
Expected: FAIL (`cannot load such file`).

- [ ] **Step 3: Implement normalizer**

Create `optimizer/lib/ruby_opt/demo/disasm_normalizer.rb`:

```ruby
# frozen_string_literal: true
require "ruby_opt/demo"

module RubyOpt
  module Demo
    module DisasmNormalizer
      HEADER_RE   = /\A==\s+disasm:\s+#<ISeq:(?<label>[^>]+)>/
      DROPPED_RE  = /\A(?:local table|\(catch table|\|\s|\s*$)/
      PC_RE       = /\A\d{4}\s+/
      SUFFIX_RE   = /\s*\(\s*\d+\)\[[A-Za-z]+\]\s*\z/

      module_function

      def normalize(raw)
        out = []
        first_header = true
        raw.each_line do |line|
          line = line.chomp
          if (m = line.match(HEADER_RE))
            if first_header
              first_header = false
              next
            else
              out << "== block: #{m[:label]}"
              next
            end
          end
          next if DROPPED_RE.match?(line)
          stripped = line.sub(PC_RE, "").sub(SUFFIX_RE, "").rstrip
          next if stripped.empty?
          out << stripped
        end
        out.join("\n") + "\n"
      end
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run:
```
cd optimizer && bundle exec rake test TEST=test/demo/disasm_normalizer_test.rb
```
Expected: PASS.

- [ ] **Step 5: Commit**

```
jj commit -m "feat(demo): DisasmNormalizer strips PC column and header noise"
```

---

### Task 5: Iseq snapshot generator

**Files:**
- Create: `optimizer/lib/ruby_opt/demo/iseq_snapshots.rb`
- Test: `optimizer/test/demo/iseq_snapshots_test.rb`

Compiles a fixture source into: `before` (no passes), per-pass
snapshots (growing walkthrough prefixes), and `after_full` (full
`Pipeline.default`).

- [ ] **Step 1: Write the failing test**

Create `optimizer/test/demo/iseq_snapshots_test.rb`:

```ruby
# frozen_string_literal: true
require "test_helper"
require "ruby_opt/demo/iseq_snapshots"
require "tmpdir"

class IseqSnapshotsTest < Minitest::Test
  FIXTURE = <<~RUBY
    # frozen_string_literal: true
    def add_one(n)
      n + 1
    end
  RUBY

  def with_fixture
    Dir.mktmpdir do |dir|
      path = File.join(dir, "fx.rb")
      File.write(path, FIXTURE)
      yield path
    end
  end

  def test_before_returns_disasm_text
    with_fixture do |path|
      snaps = RubyOpt::Demo::IseqSnapshots.generate(
        fixture_path: path, walkthrough: [],
      )
      assert_kind_of String, snaps.before
      assert_match(/disasm/, snaps.before)
    end
  end

  def test_after_full_uses_pipeline_default
    with_fixture do |path|
      snaps = RubyOpt::Demo::IseqSnapshots.generate(
        fixture_path: path, walkthrough: [],
      )
      assert_kind_of String, snaps.after_full
      assert_match(/disasm/, snaps.after_full)
    end
  end

  def test_per_pass_snapshots_match_prefixes
    with_fixture do |path|
      snaps = RubyOpt::Demo::IseqSnapshots.generate(
        fixture_path: path,
        walkthrough: [:const_fold, :dead_branch_fold],
      )
      assert_equal [:const_fold, :dead_branch_fold], snaps.per_pass.keys
      snaps.per_pass.each_value do |disasm|
        assert_kind_of String, disasm
      end
    end
  end

  def test_unknown_walkthrough_name_raises
    with_fixture do |path|
      assert_raises(ArgumentError) do
        RubyOpt::Demo::IseqSnapshots.generate(
          fixture_path: path, walkthrough: [:no_such_pass],
        )
      end
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```
cd optimizer && bundle exec rake test TEST=test/demo/iseq_snapshots_test.rb
```
Expected: FAIL (`cannot load such file`).

- [ ] **Step 3: Implement IseqSnapshots**

Create `optimizer/lib/ruby_opt/demo/iseq_snapshots.rb`:

```ruby
# frozen_string_literal: true
require "ruby_opt/demo"
require "ruby_opt/codec"
require "ruby_opt/pipeline"
require "ruby_opt/type_env"

module RubyOpt
  module Demo
    module IseqSnapshots
      Result = Struct.new(:before, :after_full, :per_pass, keyword_init: true)

      module_function

      def generate(fixture_path:, walkthrough:)
        source = File.read(fixture_path)

        pass_index = Pipeline.default.passes.each_with_object({}) do |p, h|
          h[p.name] = p
        end
        unknown = walkthrough - pass_index.keys
        raise ArgumentError, "unknown pass name(s): #{unknown.inspect}" unless unknown.empty?

        before = compile_raw(source, fixture_path)
        after_full = run_with_passes(source, fixture_path, Pipeline.default.passes)

        per_pass = {}
        walkthrough.each_with_index do |name, idx|
          prefix = walkthrough[0..idx].map { |n| pass_index.fetch(n) }
          per_pass[name] = run_with_passes(source, fixture_path, prefix)
        end

        Result.new(before: before, after_full: after_full, per_pass: per_pass)
      end

      def compile_raw(source, path)
        RubyVM::InstructionSequence.compile(source, path, path).disasm
      end

      def run_with_passes(source, path, passes)
        iseq = RubyVM::InstructionSequence.compile(source, path, path)
        binary = iseq.to_binary
        ir = Codec.decode(binary)
        type_env = TypeEnv.from_source(source, path)
        Pipeline.new(passes).run(ir, type_env: type_env)
        modified = Codec.encode(ir)
        RubyVM::InstructionSequence.load_from_binary(modified).disasm
      end
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run:
```
cd optimizer && bundle exec rake test TEST=test/demo/iseq_snapshots_test.rb
```
Expected: PASS.

- [ ] **Step 5: Commit**

```
jj commit -m "feat(demo): IseqSnapshots compiles fixture through pass prefixes"
```

---

### Task 6: Benchmark subprocess wrapper

**Files:**
- Create: `optimizer/lib/ruby_opt/demo/benchmark.rb`
- Test: `optimizer/test/demo/benchmark_test.rb`

Runs `benchmark-ips` twice — once with the harness off, once with
`Pipeline.default` installed — as **isolated subprocess invocations**
of `ruby`. Each subprocess loads the fixture, runs a
`Benchmark.ips do ... end` block, and prints a machine-readable
`IPS_RESULT: <label> <ips_float>` line we parse. Subprocess isolation
means the harness install/uninstall cannot leak into the parent
driver or test process.

- [ ] **Step 1: Write the failing test**

Create `optimizer/test/demo/benchmark_test.rb`:

```ruby
# frozen_string_literal: true
require "test_helper"
require "ruby_opt/demo/benchmark"
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
      result = RubyOpt::Demo::Benchmark.compare(
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
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```
cd optimizer && bundle exec rake test TEST=test/demo/benchmark_test.rb
```
Expected: FAIL (`cannot load such file`).

- [ ] **Step 3: Implement Benchmark**

Create `optimizer/lib/ruby_opt/demo/benchmark.rb`:

```ruby
# frozen_string_literal: true
require "open3"
require "tempfile"
require "ruby_opt/demo"

module RubyOpt
  module Demo
    module Benchmark
      Result = Struct.new(:stdout, :plain_ips, :optimized_ips, keyword_init: true)
      Report = Struct.new(:label, :ips, :raw, keyword_init: true)

      LIB_DIR = File.expand_path("../../..", __dir__) # optimizer/lib

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
          require "benchmark/ips"
          #{preamble}
          require #{fixture_path.inspect}
          #{entry_setup}
          $stdout.sync = true
          _report = nil
          ::Benchmark.ips do |x|
            x.config(warmup: #{warmup}, time: #{time}, quiet: false)
            _report = x.report(#{label.inspect}) { #{entry_call} }
          end
          printf("IPS_RESULT: %s %.6f\\n", #{label.inspect}, _report.ips)
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
```

Note: the subprocess invocation inlines `entry_setup` and
`entry_call` as literal Ruby source into a tempfile. This is
equivalent to how a developer would write a `benchmark-ips` harness
by hand. Sidecar YAML lives in-repo and is author-controlled.

- [ ] **Step 4: Run test to verify it passes**

Run:
```
cd optimizer && bundle exec rake test TEST=test/demo/benchmark_test.rb
```
Expected: PASS. Test uses 0.1s warmup / 0.2s time to stay fast
(~0.6s per subprocess, ~1.2s total).

- [ ] **Step 5: Commit**

```
jj commit -m "feat(demo): Benchmark.compare runs harness-off vs Pipeline.default via subprocess"
```

---

### Task 7: Markdown renderer

**Files:**
- Create: `optimizer/lib/ruby_opt/demo/markdown_renderer.rb`
- Test: `optimizer/test/demo/markdown_renderer_test.rb`

Assembles the five sections from `IseqSnapshots::Result`,
`Benchmark::Result`, and the walkthrough list.

- [ ] **Step 1: Write the failing test**

Create `optimizer/test/demo/markdown_renderer_test.rb`:

```ruby
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
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```
cd optimizer && bundle exec rake test TEST=test/demo/markdown_renderer_test.rb
```
Expected: FAIL (`cannot load such file`).

- [ ] **Step 3: Implement MarkdownRenderer**

Create `optimizer/lib/ruby_opt/demo/markdown_renderer.rb`:

```ruby
# frozen_string_literal: true
require "diff/lcs"
require "diff/lcs/hunk"
require "ruby_opt/demo"
require "ruby_opt/demo/disasm_normalizer"

module RubyOpt
  module Demo
    module MarkdownRenderer
      PASS_DESCRIPTIONS = {
        inlining:         "Replace `send` with the callee's body when the receiver is resolvable.",
        arith_reassoc:    "Reassociate `+ - * /` chains of literal operands under the no-BOP-redef rule.",
        const_fold:       "Fold literal-operand operations (Tier 1).",
        const_fold_tier2: "Rewrite frozen top-level constant references to their literal values.",
        const_fold_env:   "Fold `ENV[\"LITERAL\"]` reads against a snapshot captured at optimize time.",
        identity_elim:    "Remove identity operations: `x + 0`, `x * 1`, `x - 0`, `x / 1`.",
        dead_branch_fold: "Collapse `<literal>; branch*` into `jump` (taken) or a drop (not taken).",
      }.freeze

      module_function

      def render(stem:, source:, walkthrough:, snapshots:, bench:)
        prev_norm = DisasmNormalizer.normalize(snapshots.before)
        sections = []
        sections << heading(stem, bench)
        sections << source_section(source)
        sections << summary_section(bench)
        sections << walkthrough_section(walkthrough, snapshots, prev_norm)
        sections << appendix_section(snapshots)
        sections << raw_benchmark_section(bench)
        sections.join("\n\n").rstrip + "\n"
      end

      def heading(stem, bench)
        ratio = bench.optimized_ips / bench.plain_ips
        "# #{stem} demo\n\n" \
          "Pipeline.default: **#{format('%.2f', ratio)}x** vs unoptimized."
      end

      def source_section(source)
        "## Source\n\n```ruby\n#{source.chomp}\n```"
      end

      def summary_section(bench)
        comparison = bench.stdout[/Comparison:.*/m] || ""
        "## Full-delta summary\n\n" \
          "`plain` = harness off; `optimized` = `Pipeline.default`.\n\n" \
          "```\n#{comparison.strip}\n```"
      end

      def walkthrough_section(walkthrough, snapshots, prev_norm)
        body = +"## Walkthrough\n\n"
        walkthrough.each do |name|
          current_norm = DisasmNormalizer.normalize(snapshots.per_pass.fetch(name))
          diff = unified_diff(prev_norm, current_norm, name)
          desc = PASS_DESCRIPTIONS[name] || "Pass `#{name}`."
          body << "### `#{name}`\n\n#{desc}\n\n```diff\n#{diff}```\n\n"
          prev_norm = current_norm
        end
        body.rstrip
      end

      def appendix_section(snapshots)
        "## Appendix: full iseq dumps\n\n" \
          "### Before (no optimization)\n\n```\n#{snapshots.before.rstrip}\n```\n\n" \
          "### After full `Pipeline.default`\n\n```\n#{snapshots.after_full.rstrip}\n```"
      end

      def raw_benchmark_section(bench)
        "## Raw benchmark output\n\n```\n#{bench.stdout.rstrip}\n```"
      end

      def unified_diff(a, b, label)
        a_lines = a.split("\n", -1)
        b_lines = b.split("\n", -1)
        diffs = Diff::LCS.diff(a_lines, b_lines)
        return "(no change)\n" if diffs.empty?

        out = +"--- before #{label}\n+++ after  #{label}\n"
        file_length_difference = 0
        diffs.each do |piece|
          hunk = Diff::LCS::Hunk.new(a_lines, b_lines, piece, 3, file_length_difference)
          file_length_difference = hunk.file_length_difference
          out << hunk.diff(:unified) << "\n"
        end
        out
      end
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run:
```
cd optimizer && bundle exec rake test TEST=test/demo/markdown_renderer_test.rb
```
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```
jj commit -m "feat(demo): MarkdownRenderer assembles five-section artifact"
```

---

### Task 8: Runner orchestration

**Files:**
- Create: `optimizer/lib/ruby_opt/demo/runner.rb`
- Test: `optimizer/test/demo/runner_test.rb`

- [ ] **Step 1: Write the failing test**

Create `optimizer/test/demo/runner_test.rb`:

```ruby
# frozen_string_literal: true
require "test_helper"
require "ruby_opt/demo/runner"
require "tmpdir"

class RunnerTest < Minitest::Test
  def test_writes_artifact_with_all_sections
    Dir.mktmpdir do |dir|
      fx = File.join(dir, "fx.rb")
      File.write(fx, <<~RUBY)
        # frozen_string_literal: true
        def add_one(n); n + 1; end
      RUBY
      sidecar = File.join(dir, "fx.walkthrough.yml")
      File.write(sidecar, <<~YAML)
        fixture: fx.rb
        entry_setup: ""
        entry_call: "add_one(1)"
        walkthrough:
          - const_fold
      YAML
      out_dir = File.join(dir, "artifacts")
      Dir.mkdir(out_dir)

      path = RubyOpt::Demo::Runner.run(
        sidecar_path: sidecar,
        output_dir: out_dir,
        bench_warmup: 0.1,
        bench_time: 0.2,
      )

      assert_equal File.join(out_dir, "fx.md"), path
      content = File.read(path)
      assert_match(/^# fx demo/, content)
      assert_match(/^## Source/, content)
      assert_match(/^## Walkthrough/, content)
      assert_match(/^### `const_fold`/, content)
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```
cd optimizer && bundle exec rake test TEST=test/demo/runner_test.rb
```
Expected: FAIL (`cannot load such file`).

- [ ] **Step 3: Implement Runner**

Create `optimizer/lib/ruby_opt/demo/runner.rb`:

```ruby
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
```

- [ ] **Step 4: Run test to verify it passes**

Run:
```
cd optimizer && bundle exec rake test TEST=test/demo/runner_test.rb
```
Expected: PASS.

- [ ] **Step 5: Commit**

```
jj commit -m "feat(demo): Runner orchestrates one fixture end-to-end"
```

---

### Task 9: CLI entry point

**Files:**
- Create: `optimizer/bin/demo`

- [ ] **Step 1: Write the script**

Create `optimizer/bin/demo`:

```ruby
#!/usr/bin/env ruby
# frozen_string_literal: true
require "bundler/setup"
require "fileutils"
require "ruby_opt/demo/runner"

EXAMPLES_DIR = File.expand_path("../examples", __dir__)
OUTPUT_DIR   = File.expand_path("../../docs/demo_artifacts", __dir__)

def sidecar_for(stem)
  File.join(EXAMPLES_DIR, "#{stem}.walkthrough.yml")
end

def run_stem(stem)
  sidecar = sidecar_for(stem)
  raise "sidecar not found: #{sidecar}" unless File.exist?(sidecar)
  FileUtils.mkdir_p(OUTPUT_DIR)
  path = RubyOpt::Demo::Runner.run(sidecar_path: sidecar, output_dir: OUTPUT_DIR)
  puts "wrote #{path}"
end

case ARGV.first
when "--all"
  Dir[File.join(EXAMPLES_DIR, "*.walkthrough.yml")].each do |sc|
    run_stem(File.basename(sc, ".walkthrough.yml"))
  end
when nil, "-h", "--help"
  warn "usage: bin/demo <stem> | bin/demo --all"
  exit 1
else
  run_stem(ARGV.first)
end
```

- [ ] **Step 2: Mark executable**

Run:
```
chmod +x optimizer/bin/demo
```

- [ ] **Step 3: Commit**

```
jj commit -m "feat(demo): add bin/demo CLI driver"
```

---

### Task 10: Update point_distance fixture

**Files:**
- Modify: `optimizer/examples/point_distance.rb`

- [ ] **Step 1: Replace contents**

Replace `optimizer/examples/point_distance.rb` with:

```ruby
# frozen_string_literal: true

class Point
  attr_reader :x, :y

  # @rbs (Integer, Integer) -> void
  def initialize(x, y)
    @x = x
    @y = y
  end

  # @rbs (Point) -> Integer
  def distance_to(other)
    (x - other.x) + (y - other.y)
  end
end
```

- [ ] **Step 2: Confirm it parses**

Run:
```
cd optimizer && bundle exec ruby -c examples/point_distance.rb
```
Expected: `Syntax OK`.

- [ ] **Step 3: Commit**

```
jj commit -m "refactor(examples): point_distance fixture defines class only"
```

---

### Task 11: Add sum_of_squares fixture

**Files:**
- Create: `optimizer/examples/sum_of_squares.rb`

- [ ] **Step 1: Write the file**

```ruby
# frozen_string_literal: true

# @rbs (Integer) -> Integer
def sum_of_squares(n)
  s = 0
  i = 1
  while i <= n
    s += i * i
    i += 1
  end
  s
end
```

- [ ] **Step 2: Smoke-test**

Run:
```
cd optimizer && bundle exec ruby -e 'require_relative "examples/sum_of_squares"; puts sum_of_squares(10)'
```
Expected: `385`.

- [ ] **Step 3: Commit**

```
jj commit -m "feat(examples): sum_of_squares fixture for numeric-kernel demo"
```

---

### Task 12: Add walkthrough sidecars

**Files:**
- Create: `optimizer/examples/point_distance.walkthrough.yml`
- Create: `optimizer/examples/sum_of_squares.walkthrough.yml`

Initial picks are tentative; Task 14 validates them against real
iseq deltas.

- [ ] **Step 1: Create point_distance sidecar**

`optimizer/examples/point_distance.walkthrough.yml`:

```yaml
fixture: point_distance.rb
entry_setup: |
  p = Point.new(1, 2)
  q = Point.new(4, 6)
entry_call: p.distance_to(q)
walkthrough:
  - inlining
  - const_fold
  - dead_branch_fold
```

- [ ] **Step 2: Create sum_of_squares sidecar**

`optimizer/examples/sum_of_squares.walkthrough.yml`:

```yaml
fixture: sum_of_squares.rb
entry_setup: ""
entry_call: sum_of_squares(1000)
walkthrough:
  - arith_reassoc
  - identity_elim
  - const_fold
```

- [ ] **Step 3: Commit**

```
jj commit -m "feat(examples): walkthrough sidecars for both demo fixtures"
```

---

### Task 13: Sidecar validation test

**Files:**
- Create: `optimizer/test/demo/sidecar_validation_test.rb`

- [ ] **Step 1: Write the test**

```ruby
# frozen_string_literal: true
require "test_helper"
require "ruby_opt/demo/walkthrough"

class SidecarValidationTest < Minitest::Test
  EXAMPLES_DIR = File.expand_path("../../examples", __dir__)

  Dir[File.join(EXAMPLES_DIR, "*.walkthrough.yml")].each do |sidecar|
    stem = File.basename(sidecar, ".walkthrough.yml")
    define_method("test_sidecar_valid_#{stem}") do
      wt = RubyOpt::Demo::Walkthrough.load(sidecar)
      assert File.exist?(wt.fixture_path),
             "fixture file #{wt.fixture_path} does not exist"
      refute_empty wt.walkthrough
    end
  end

  def test_at_least_one_sidecar_present
    refute_empty Dir[File.join(EXAMPLES_DIR, "*.walkthrough.yml")]
  end
end
```

- [ ] **Step 2: Run it**

Run:
```
cd optimizer && bundle exec rake test TEST=test/demo/sidecar_validation_test.rb
```
Expected: PASS (3 tests).

- [ ] **Step 3: Commit**

```
jj commit -m "test(demo): validate every walkthrough sidecar against Pipeline.default"
```

---

### Task 14: Generate and commit artifacts

**Files:**
- Create: `docs/demo_artifacts/point_distance.md`
- Create: `docs/demo_artifacts/sum_of_squares.md`

- [ ] **Step 1: Run the driver**

Run:
```
cd optimizer && bundle exec bin/demo --all
```
Expected: two `wrote …/docs/demo_artifacts/<stem>.md` lines.

- [ ] **Step 2: Eyeball each artifact**

Open each markdown file. Verify:
- All five sections present.
- Each walkthrough pass shows a non-trivial diff (not `(no change)`).
  If any is `(no change)`, edit the corresponding
  `*.walkthrough.yml`, swap to a pass that does move the iseq for
  that fixture, and re-run `bin/demo --all`.
- `benchmark-ips` output block is present.

Valid pass names (from `Pipeline.default`):
`inlining`, `arith_reassoc`, `const_fold_tier2`, `const_fold_env`,
`const_fold`, `identity_elim`, `dead_branch_fold`.

Picks likely to *move* the iseq on these fixtures:
`inlining`, `arith_reassoc`, `identity_elim`, `const_fold`,
`dead_branch_fold`. `const_fold_tier2` needs frozen top-level
constants (neither fixture has them). `const_fold_env` needs `ENV`
reads (neither fixture has them).

- [ ] **Step 3: Commit**

```
jj commit -m "docs: demo artifacts for point_distance and sum_of_squares"
```

If any sidecar was edited in Step 2, include it in the same commit.

---

### Task 15: Rakefile `demo:verify` freshness check

**Files:**
- Modify: `optimizer/Rakefile`

Regenerates every artifact into a tempdir, masks the raw benchmark
section (nondeterministic i/s numbers), diffs against the committed
file.

- [ ] **Step 1: Read the current Rakefile**

Run:
```
cat optimizer/Rakefile
```
Note the existing test-task definition so we don't break it.

- [ ] **Step 2: Add the verify task**

Append (or merge into existing structure) the following in
`optimizer/Rakefile`:

```ruby
require "tmpdir"
require "fileutils"

RAW_BENCH_SECTION_RE = /## Raw benchmark output\n\n```\n.*?```/m

def mask_nondeterministic(md)
  md.sub(RAW_BENCH_SECTION_RE, "## Raw benchmark output\n\n```\n<benchmark output>\n```")
end

namespace :demo do
  desc "Regenerate demo artifacts in a tempdir and diff against committed files"
  task :verify do
    require "ruby_opt/demo/runner"
    examples_dir = File.expand_path("examples", __dir__)
    committed_dir = File.expand_path("../docs/demo_artifacts", __dir__)
    sidecars = Dir[File.join(examples_dir, "*.walkthrough.yml")]
    abort "no sidecars found" if sidecars.empty?

    Dir.mktmpdir do |tmp|
      mismatches = []
      sidecars.each do |sc|
        stem = File.basename(sc, ".walkthrough.yml")
        regenerated = RubyOpt::Demo::Runner.run(sidecar_path: sc, output_dir: tmp)
        committed = File.join(committed_dir, "#{stem}.md")
        unless File.exist?(committed)
          mismatches << "missing committed artifact: #{committed}"
          next
        end
        if mask_nondeterministic(File.read(regenerated)) !=
           mask_nondeterministic(File.read(committed))
          mismatches << stem
        end
      end
      if mismatches.empty?
        puts "demo:verify OK (#{sidecars.size} fixtures)"
      else
        abort "demo:verify FAILED for: #{mismatches.join(', ')}. " \
              "Re-run `bin/demo --all` and commit the regenerated artifacts."
      end
    end
  end
end
```

- [ ] **Step 3: Run it**

Run:
```
cd optimizer && bundle exec rake demo:verify
```
Expected: `demo:verify OK (2 fixtures)`.

- [ ] **Step 4: Commit**

```
jj commit -m "build(rake): add demo:verify freshness check"
```

---

### Task 16: Strike the TODO

**Files:**
- Modify: `docs/todo.md`

- [ ] **Step 1: Strike item #2**

Edit `docs/todo.md`, replace the "Demo programs wired end-to-end"
bullet under "Roadmap gap, ranked by talk-ROI" with:

```markdown
2. ~~**Demo programs wired end-to-end** with benchmark harness
   output.~~ **Shipped 2026-04-22.** Plan:
   `docs/superpowers/plans/2026-04-22-demo-programs-benchmark-harness.md`.
   Spec: `docs/superpowers/specs/2026-04-22-demo-programs-benchmark-harness-design.md`.
   Artifacts committed under `docs/demo_artifacts/`; `bin/demo --all`
   regenerates; `rake demo:verify` is CI-ready.
```

- [ ] **Step 2: Commit**

```
jj commit -m "docs(todo): strike demo-programs item; point to artifacts"
```

---

## Self-Review

- **Spec coverage:**
  - Five-section artifact → Task 7.
  - File layout → Tasks 3–9 + 10–12.
  - Walkthrough YAML → Tasks 3 + 12.
  - Driver flow → Tasks 3, 5, 6, 7, 8.
  - Disasm normalization → Task 4 (consumed in Task 7).
  - `diff-lcs` dep → Task 1.
  - `benchmark-ips` in-process → Task 6 (via subprocess; preserves
    the "in-process gem, not the MCP tool" spec requirement —
    `Benchmark.ips do ... end` runs inside the subprocess's Ruby
    VM, not via any external tool invocation).
  - Strip trailing loops → Task 10.
  - `sum_of_squares` fixture → Task 11.
  - Driver unit test → Task 8.
  - Sidecar validation → Task 13.
  - Freshness check with raw-bench masking → Task 15.
  - TODO update → Task 16.
- **Placeholder scan:** no `TBD` / `TODO` / "fill in later" strings.
  Tentative pass picks in Task 12 are paired with Task 14's explicit
  swap procedure and a list of valid names — a resolution path, not a
  deferral.
- **Type consistency:**
  - `Walkthrough` → `fixture, entry_setup, entry_call, walkthrough,
    sidecar_path`, plus `#fixture_path`. Used consistently.
  - `IseqSnapshots::Result` → `before, after_full, per_pass`. Used
    consistently in Runner + MarkdownRenderer tests + implementations.
  - `Benchmark::Result` → `stdout, plain_ips, optimized_ips`. Used
    consistently.
  - Pass names (`:inlining`, `:arith_reassoc`, `:const_fold_tier2`,
    `:const_fold_env`, `:const_fold`, `:identity_elim`,
    `:dead_branch_fold`) match `Pipeline.default` pass `name`
    methods (verified by grepping `optimizer/lib/ruby_opt/passes/`).

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-04-22-demo-programs-benchmark-harness.md`. Two execution options:

1. **Subagent-Driven (recommended)** — dispatch a fresh subagent per task, review between tasks, fast iteration.
2. **Inline Execution** — execute tasks in this session using executing-plans, batch execution with checkpoints.

Which approach?
