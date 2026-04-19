# frozen_string_literal: true
require "test_helper"
require "ruby_opt/harness"

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
