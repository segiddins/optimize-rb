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
