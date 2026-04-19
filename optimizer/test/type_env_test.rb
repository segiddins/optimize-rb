# frozen_string_literal: true
require "test_helper"
require "ruby_opt/type_env"

class TypeEnvTest < Minitest::Test
  def test_lookup_by_class_and_method_returns_signature
    src = <<~RUBY
      # @rbs (Integer, Integer) -> Integer
      def add(a, b); a + b; end

      class Point
        # @rbs (Point) -> Float
        def distance_to(other); 0.0; end
      end
    RUBY
    env = RubyOpt::TypeEnv.from_source(src, "test.rb")

    top = env.signature_for(receiver_class: nil, method_name: :add)
    refute_nil top
    assert_equal "Integer", top.return_type

    inst = env.signature_for(receiver_class: "Point", method_name: :distance_to)
    refute_nil inst
    assert_equal "Float", inst.return_type
  end

  def test_lookup_with_no_signature_returns_nil
    env = RubyOpt::TypeEnv.from_source("def hi; end", "test.rb")
    assert_nil env.signature_for(receiver_class: nil, method_name: :hi)
  end

  def test_empty_env_for_empty_source
    env = RubyOpt::TypeEnv.from_source("", "test.rb")
    assert_kind_of RubyOpt::TypeEnv, env
  end
end
