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

    def apply(function, type_env:, log:, object_table: nil, **_extras)
      @visited << function.name
    end

    def name
      @name_sym
    end
  end

  class RaisingPass < RubyOpt::Pass
    def apply(function, type_env:, log:, object_table: nil, **_extras)
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

  def test_inlining_pass_runs_end_to_end
    src = File.read(File.expand_path("codec/corpus/inlining_zero_arg.rb", __dir__))
    bin = RubyVM::InstructionSequence.compile(src).to_binary
    ir  = RubyOpt::Codec.decode(bin)

    log = RubyOpt::Pipeline.default.run(ir, type_env: nil)

    use_it = ir.children.find { |c| c.name == "use_it" }
    refute_nil use_it
    refute use_it.instructions.any? { |i| i.opcode == :opt_send_without_block },
      "expected `use_it` to have its call to `magic` inlined"
    assert log.entries.any? { |e| e.pass == :inlining && e.reason == :inlined }

    loaded = RubyVM::InstructionSequence.load_from_binary(RubyOpt::Codec.encode(ir))
    assert_equal 42, loaded.eval
  end

  def test_inlining_v2_end_to_end
    src = File.read(File.expand_path("codec/corpus/inlining_one_arg.rb", __dir__))
    bin = RubyVM::InstructionSequence.compile(src).to_binary
    ir  = RubyOpt::Codec.decode(bin)

    log = RubyOpt::Pipeline.default.run(ir, type_env: nil)

    use_it = ir.children.find { |c| c.name == "use_it" }
    refute_nil use_it
    refute use_it.instructions.any? { |i| i.opcode == :opt_send_without_block },
      "expected `use_it` to have its call to `double` inlined"
    assert log.entries.any? { |e| e.pass == :inlining && e.reason == :inlined }

    loaded = RubyVM::InstructionSequence.load_from_binary(RubyOpt::Codec.encode(ir))
    assert_equal 14, loaded.eval
  end

  def test_pipeline_threads_env_snapshot_to_passes
    captured = []
    recorder = Class.new(RubyOpt::Pass) do
      define_method(:apply) do |fn, type_env:, log:, object_table: nil, **extras|
        captured << extras[:env_snapshot]
      end
      def name = :recorder
    end

    ir = RubyOpt::Codec.decode(
      RubyVM::InstructionSequence.compile("def f; 1; end").to_binary
    )
    snap = { "FOO" => "bar" }.freeze
    RubyOpt::Pipeline.new([recorder.new]).run(ir, type_env: nil, env_snapshot: snap)

    refute_empty captured
    assert_equal snap, captured.first
  end
end
