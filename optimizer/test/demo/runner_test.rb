# frozen_string_literal: true
require "test_helper"
require "optimize/demo/runner"
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

      path = Optimize::Demo::Runner.run(
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
