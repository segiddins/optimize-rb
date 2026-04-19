# frozen_string_literal: true
require "test_helper"
require "ruby_opt/rbs_parser"

class RbsParserTest < Minitest::Test
  def test_captures_top_level_def_signature
    src = <<~RUBY
      # @rbs (Integer, Integer) -> Integer
      def add(a, b); a + b; end
    RUBY
    sigs = RubyOpt::RbsParser.parse(src, "test.rb")
    assert_equal 1, sigs.size
    s = sigs.first
    assert_equal :add, s.method_name
    assert_nil s.receiver_class
    assert_equal ["Integer", "Integer"], s.arg_types
    assert_equal "Integer", s.return_type
  end

  def test_captures_instance_method_signature
    src = <<~RUBY
      class Point
        # @rbs (Point) -> Float
        def distance_to(other)
          0.0
        end
      end
    RUBY
    sigs = RubyOpt::RbsParser.parse(src, "test.rb")
    s = sigs.find { |x| x.method_name == :distance_to }
    refute_nil s
    assert_equal "Point", s.receiver_class
    assert_equal ["Point"], s.arg_types
    assert_equal "Float", s.return_type
  end

  def test_defs_without_rbs_comment_are_skipped
    src = <<~RUBY
      def plain(a); a; end
      # @rbs (Integer) -> Integer
      def annotated(a); a; end
    RUBY
    sigs = RubyOpt::RbsParser.parse(src, "test.rb")
    assert_equal 1, sigs.size
    assert_equal :annotated, sigs.first.method_name
  end

  def test_returns_empty_array_when_no_annotations
    assert_empty RubyOpt::RbsParser.parse("def hi; end", "test.rb")
  end
end
