# frozen_string_literal: true
require "test_helper"
require "optimize/log"

class LogTest < Minitest::Test
  def test_records_entries_with_pass_name_and_reason
    log = Optimize::Log.new
    log.skip(pass: :inlining, reason: :receiver_not_resolvable, file: "a.rb", line: 12)
    log.skip(pass: :const_fold, reason: :mutable_receiver, file: "a.rb", line: 15)
    assert_equal 2, log.entries.size
    first = log.entries.first
    assert_equal :inlining, first.pass
    assert_equal :receiver_not_resolvable, first.reason
    assert_equal "a.rb", first.file
    assert_equal 12, first.line
  end

  def test_for_pass_filters_entries
    log = Optimize::Log.new
    log.skip(pass: :inlining, reason: :a, file: "x", line: 1)
    log.skip(pass: :arith, reason: :b, file: "x", line: 2)
    inlining_only = log.for_pass(:inlining)
    assert_equal 1, inlining_only.size
    assert_equal :inlining, inlining_only.first.pass
  end

  def test_empty_log_has_no_entries
    assert_empty Optimize::Log.new.entries
  end

  def test_rewrite_appends_entry_and_bumps_rewrite_count
    log = Optimize::Log.new
    assert_equal 0, log.rewrite_count

    log.rewrite(pass: :const_fold, reason: :folded, file: "f.rb", line: 3)
    assert_equal 1, log.rewrite_count
    assert_equal 1, log.entries.size
    entry = log.entries.first
    assert_equal :const_fold, entry.pass
    assert_equal :folded, entry.reason
  end

  def test_skip_does_not_bump_rewrite_count
    log = Optimize::Log.new
    log.skip(pass: :const_fold, reason: :would_raise, file: "f.rb", line: 3)
    assert_equal 0, log.rewrite_count
    assert_equal 1, log.entries.size
  end

  def test_convergence_map_round_trips
    log = Optimize::Log.new
    log.record_convergence("fnA", 3)
    log.record_convergence("fnB", 1)
    assert_equal({ "fnA" => 3, "fnB" => 1 }, log.convergence)
  end
end
