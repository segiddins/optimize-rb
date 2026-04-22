# frozen_string_literal: true
require "test_helper"
require "ruby_opt/pipeline"
require "ruby_opt/pass"
require "ruby_opt/codec"
require "ruby_opt/type_env"
require "ruby_opt/ir/function"
require "ruby_opt/ir/slot_type_table"

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

  def test_pipeline_collapses_env_feature_flag_to_boolean
    require "ruby_opt/passes/literal_value"
    src = 'def f; ENV["FLAG"] == "true"; end'
    ir = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    ot = ir.misc[:object_table]
    snap = { "FLAG" => "true" }.freeze

    RubyOpt::Pipeline.default.run(ir, type_env: nil, env_snapshot: snap)

    f = find_iseq(ir, "f")
    # ENV["FLAG"] folds to "true", then "true"=="true" folds to true in the same run.
    assert(f.instructions.any? { |i| RubyOpt::Passes::LiteralValue.read(i, object_table: ot) == true },
           "expected ENV[FLAG] == 'true' to collapse to true")
    refute(f.instructions.any? { |i| i.opcode == :opt_getconstant_path })
    refute(f.instructions.any? { |i| i.opcode == :opt_aref })
  end

  # End-to-end: `"a" == "a"` → ConstFoldPass folds to `true` →
  # DeadBranchFoldPass drops the `putobject true; branchunless ...` pair.
  def test_pipeline_collapses_const_equality_branch
    src = <<~RUBY
      def f(x)
        if "a" == "a"
          x + 1
        else
          x - 1
        end
      end
      f(10)
    RUBY
    ir = RubyOpt::Codec.decode(RubyVM::InstructionSequence.compile(src).to_binary)
    RubyOpt::Pipeline.default.run(ir, type_env: nil)

    f = find_iseq(ir, "f")
    refute(f.instructions.any? { |i| i.opcode == :branchunless },
           "expected branchunless to be folded away by the pipeline")
    loaded = RubyVM::InstructionSequence.load_from_binary(RubyOpt::Codec.encode(ir))
    assert_equal 11, loaded.eval
  end

  class ExtrasSpyPass < RubyOpt::Pass
    attr_reader :seen_slot_map, :seen_signature_map
    def name = :extras_spy
    def apply(function, type_env:, log:, object_table: nil, slot_type_map: nil, signature_map: nil, **_extras)
      @seen_slot_map = slot_type_map
      @seen_signature_map = signature_map
    end
  end

  def test_pipeline_threads_slot_type_map_and_signature_map
    ir = RubyOpt::IR::Function.new(
      name: "<main>", type: :top, path: "t.rb", first_lineno: 1,
      instructions: [], children: [], misc: {},
    )
    spy = ExtrasSpyPass.new
    pipeline = RubyOpt::Pipeline.new([spy])
    type_env = RubyOpt::TypeEnv.from_source("", "t.rb")
    pipeline.run(ir, type_env: type_env)
    refute_nil spy.seen_slot_map
    refute_nil spy.seen_signature_map
    assert_kind_of RubyOpt::IR::SlotTypeTable, spy.seen_slot_map[ir]
  end

  private

  def find_iseq(ir, name)
    return ir if ir.name == name
    ir.children&.each do |c|
      found = find_iseq(c, name)
      return found if found
    end
    nil
  end
end
