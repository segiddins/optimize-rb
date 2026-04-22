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

  FnStub = Struct.new(:name, :type, :path, :first_lineno, :misc, keyword_init: true) unless defined?(FnStub)

  def test_signature_for_function_matches_top_level_def
    env = RubyOpt::TypeEnv.from_source(<<~RUBY, "t.rb")
      # @rbs (Integer) -> Integer
      def inc(a); a + 1; end
    RUBY

    fn = FnStub.new(name: "inc", type: :method, path: "t.rb", first_lineno: 2, misc: {})
    sig = env.signature_for_function(fn, class_context: nil)
    refute_nil sig
    assert_equal :inc, sig.method_name
  end

  def test_signature_for_function_matches_instance_method_with_class_context
    env = RubyOpt::TypeEnv.from_source(<<~RUBY, "t.rb")
      class Point
        # @rbs (Point) -> Float
        def distance_to(o); 0.0; end
      end
    RUBY
    fn = FnStub.new(name: "distance_to", type: :method, path: "t.rb", first_lineno: 3, misc: {})
    sig = env.signature_for_function(fn, class_context: "Point")
    refute_nil sig
    assert_equal "Float", sig.return_type
  end

  def test_signature_for_function_returns_nil_for_non_method
    env = RubyOpt::TypeEnv.from_source("", "t.rb")
    fn = FnStub.new(name: "<main>", type: :top, path: "t.rb", first_lineno: 1, misc: {})
    assert_nil env.signature_for_function(fn, class_context: nil)
  end

  def test_new_returns_identity
    env = RubyOpt::TypeEnv.from_source("", "t.rb")
    assert_equal "Point", env.new_returns?("Point")
  end
end
