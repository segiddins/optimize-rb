# frozen_string_literal: true
require "test_helper"
require "ruby_opt/log"

class LogTest < Minitest::Test
  def test_records_entries_with_pass_name_and_reason
    log = RubyOpt::Log.new
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
    log = RubyOpt::Log.new
    log.skip(pass: :inlining, reason: :a, file: "x", line: 1)
    log.skip(pass: :arith, reason: :b, file: "x", line: 2)
    inlining_only = log.for_pass(:inlining)
    assert_equal 1, inlining_only.size
    assert_equal :inlining, inlining_only.first.pass
  end

  def test_empty_log_has_no_entries
    assert_empty RubyOpt::Log.new.entries
  end
end
