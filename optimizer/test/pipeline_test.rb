# frozen_string_literal: true
require "test_helper"
require "ruby_opt/pipeline"
require "ruby_opt/pass"
require "ruby_opt/codec"

class PipelineTest < Minitest::Test
  class TrackingPass < RubyOpt::Pass
    attr_reader :visited

    def initialize(name_sym)
      @name_sym = name_sym
      @visited = []
    end

    def apply(function, type_env:, log:, object_table: nil)
      @visited << function.name
    end

    def name
      @name_sym
    end
  end

  class RaisingPass < RubyOpt::Pass
    def apply(function, type_env:, log:, object_table: nil)
      raise "boom"
    end

    def name
      :raising
    end
  end

  def ir
    RubyOpt::Codec.decode(
      RubyVM::InstructionSequence.compile("def a; 1; end; def b; 2; end").to_binary
    )
  end

  def test_runs_passes_in_order_over_each_function
    t1 = TrackingPass.new(:first)
    t2 = TrackingPass.new(:second)
    pipeline = RubyOpt::Pipeline.new([t1, t2])
    log = pipeline.run(ir, type_env: nil)
    # Each pass visits every Function (root + compiled + a + b)
    assert_equal 4, t1.visited.size
    assert_equal 4, t2.visited.size
    assert_kind_of RubyOpt::Log, log
  end

  def test_raising_pass_logs_and_continues
    raiser = RaisingPass.new
    tracker = TrackingPass.new(:tracker)
    pipeline = RubyOpt::Pipeline.new([raiser, tracker])
    log = pipeline.run(ir, type_env: nil)

    raised_entries = log.for_pass(:raising)
    refute_empty raised_entries, "expected raising pass to log a skip"
    assert_equal :pass_raised, raised_entries.first.reason

    # The subsequent pass still ran on every Function.
    assert_equal 4, tracker.visited.size
  end

  def test_default_pipeline_folds_integer_literals_in_every_function
    require "ruby_opt/pipeline"
    require "ruby_opt/passes/literal_value"
    ir = RubyOpt::Codec.decode(
      RubyVM::InstructionSequence.compile("def f; 2 + 3; end; f").to_binary
    )
    ot = ir.misc[:object_table]
    pipeline = RubyOpt::Pipeline.default
    pipeline.run(ir, type_env: nil)
    f = ir.children.flat_map { |c| [c, *(c.children || [])] }.find { |x| x.name == "f" }
    refute_nil f
    assert(f.instructions.any? { |i| RubyOpt::Passes::LiteralValue.read(i, object_table: ot) == 5 })
  end
end
