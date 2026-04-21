# frozen_string_literal: true
require "test_helper"
require "ruby_opt/harness"
require "ruby_opt/pass"

class HarnessOptOutTest < Minitest::Test
  def test_opt_out_detected_in_top_comment
    src = "# rbs-optimize: false\nputs 1\n"
    assert RubyOpt::Harness.opted_out?(src)
  end

  def test_default_is_opted_in
    assert_equal false, RubyOpt::Harness.opted_out?("puts 1\n")
  end

  def test_opt_out_in_deep_comment_is_ignored
    src = "puts 1\n" * 20 + "# rbs-optimize: false\n"
    assert_equal false, RubyOpt::Harness.opted_out?(src),
      "only the top of the file is scanned for the opt-out"
  end

  def test_matches_with_loose_whitespace
    assert RubyOpt::Harness.opted_out?("#rbs-optimize:false\n")
    assert RubyOpt::Harness.opted_out?("#   rbs-optimize:   false   \n")
  end
end

class HarnessLoadIseqTest < Minitest::Test
  FIXTURE_DIR = File.expand_path("harness_fixtures", __dir__)

  def setup
    @passes_seen = []
    passes = [TrackingNoopPass.new(@passes_seen)]
    @harness = RubyOpt::Harness::LoadIseqHook.new(passes: passes)
  end

  class TrackingNoopPass < RubyOpt::Pass
    def initialize(tracker)
      @tracker = tracker
    end

    def apply(function, type_env:, log:, object_table: nil, **_extras)
      @tracker << function.name
    end

    def name
      :tracking_noop
    end
  end

  def test_install_and_load_runs_pipeline_and_returns_iseq
    @harness.install
    load File.join(FIXTURE_DIR, "plain.rb")
    assert_equal 42, HarnessPlainFixture.answer
    refute_empty @passes_seen
  ensure
    @harness.uninstall
    Object.send(:remove_const, :HarnessPlainFixture) if defined?(HarnessPlainFixture)
  end

  def test_opted_out_file_bypasses_pipeline
    @harness.install
    load File.join(FIXTURE_DIR, "opted_out.rb")
    assert_equal 99, HarnessOptedOutFixture.answer
    assert_empty @passes_seen,
      "opted-out file must not be visited by any pass"
  ensure
    @harness.uninstall
    Object.send(:remove_const, :HarnessOptedOutFixture) if defined?(HarnessOptedOutFixture)
  end
end
