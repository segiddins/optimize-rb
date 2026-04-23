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

  class CalleeMapSpyPass < RubyOpt::Pass
    attr_reader :seen_callee_map
    def name = :callee_map_spy
    def apply(function, type_env:, log:, callee_map: {}, **_extras)
      @seen_callee_map = callee_map if function.type == :top
    end
  end

  def test_callee_map_keys_instance_methods_by_class_and_method
    method_fn = RubyOpt::IR::Function.new(
      name: "distance_to", type: :method, path: "t.rb", first_lineno: 3, misc: {},
      instructions: [], children: [],
    )
    class_fn = RubyOpt::IR::Function.new(
      name: "Point", type: :class, path: "t.rb", first_lineno: 1, misc: {},
      instructions: [], children: [method_fn],
    )
    top_fn = RubyOpt::IR::Function.new(
      name: "<main>", type: :top, path: "t.rb", first_lineno: 1, misc: {},
      instructions: [], children: [class_fn],
    )
    spy = CalleeMapSpyPass.new
    RubyOpt::Pipeline.new([spy]).run(top_fn, type_env: nil)

    assert_same method_fn, spy.seen_callee_map[["Point", :distance_to]]
  end

  def test_callee_map_still_keys_top_level_def_by_symbol
    top_level_method = RubyOpt::IR::Function.new(
      name: "inc", type: :method, path: "t.rb", first_lineno: 1, misc: {},
      instructions: [], children: [],
    )
    top_fn = RubyOpt::IR::Function.new(
      name: "<main>", type: :top, path: "t.rb", first_lineno: 1, misc: {},
      instructions: [], children: [top_level_method],
    )
    spy = CalleeMapSpyPass.new
    RubyOpt::Pipeline.new([spy]).run(top_fn, type_env: nil)

    assert_same top_level_method, spy.seen_callee_map[:inc]
  end

  def test_point_distance_fixture_roundtrips_through_pipeline
    fixture = File.read(File.expand_path("../examples/point_distance.rb", __dir__))
    # Append a call site so the inliner has something to resolve. The
    # fixture file itself only defines the class; call sites live in
    # the walkthrough sidecar's entry_call.
    source = "#{fixture.chomp}\n\np = Point.new(1, 2)\nq = Point.new(4, 6)\np.distance_to(q)\n"
    iseq = RubyVM::InstructionSequence.compile(source, "point_distance.rb", "point_distance.rb")
    ir = RubyOpt::Codec.decode(iseq.to_binary)
    type_env = RubyOpt::TypeEnv.from_source(source, "point_distance.rb")
    log = RubyOpt::Pipeline.default.run(ir, type_env: type_env)
    modified = RubyOpt::Codec.encode(ir)
    reloaded = RubyVM::InstructionSequence.load_from_binary(modified)
    assert_kind_of RubyVM::InstructionSequence, reloaded

    # At least one inlined OPT_SEND is expected.
    inlined_entries = log.entries.select { |e| e.reason == :inlined && e.pass == :inlining }
    refute_empty inlined_entries,
      "expected at least one inlined entry in log; skip reasons were: " \
      "#{log.entries.map { |e| [e.pass, e.reason] }.tally.inspect}"
  end

  def test_pass_defaults_to_not_one_shot
    refute RubyOpt::Pass.new.one_shot?
  end

  def test_inlining_pass_is_one_shot
    require "ruby_opt/passes/inlining_pass"
    assert RubyOpt::Passes::InliningPass.new.one_shot?
  end

  def test_other_passes_are_not_one_shot
    require "ruby_opt/passes/arith_reassoc_pass"
    require "ruby_opt/passes/const_fold_pass"
    refute RubyOpt::Passes::ArithReassocPass.new.one_shot?
    refute RubyOpt::Passes::ConstFoldPass.new.one_shot?
  end

  def cascade_ir_with_marker
    ir = RubyOpt::Codec.decode(
      RubyVM::InstructionSequence.compile("def f; 1; end").to_binary
    )
    walk = ->(fn) {
      (fn.instructions || []).each { |i| i.opcode = :x_marker if i.opcode == :putobject_INT2FIX_1_ }
      (fn.children || []).each { |c| walk.call(c) }
    }
    walk.call(ir)
    ir
  end

  def test_fixed_point_loop_cascades_across_passes
    ir = cascade_ir_with_marker
    pipeline = RubyOpt::Pipeline.new([CascadePassA.new, CascadePassB.new])
    log = pipeline.run(ir, type_env: nil)
    refute_empty log.for_pass(:cascade_a)
    refute_empty log.for_pass(:cascade_b)
    refute_empty log.convergence
  end

  def test_fixed_point_loop_converges_with_no_rewrites
    t1 = TrackingPass.new(:first)
    t2 = TrackingPass.new(:second)
    pipeline = RubyOpt::Pipeline.new([t1, t2])
    pipeline.run(ir, type_env: nil)
    assert_equal 4, t1.visited.size
    assert_equal 4, t2.visited.size
  end

  class ForeverRewritingPass < RubyOpt::Pass
    def apply(function, type_env:, log:, **_extras)
      log.rewrite(pass: :forever, reason: :always, file: function.path || "", line: 0)
    end

    def name; :forever; end
  end

  def test_fixed_point_loop_raises_on_overflow
    pipeline = RubyOpt::Pipeline.new([ForeverRewritingPass.new])
    assert_raises(RubyOpt::Pipeline::FixedPointOverflow) do
      pipeline.run(ir, type_env: nil)
    end
  end

  def test_one_shot_pass_runs_exactly_once_even_if_iterative_passes_loop
    one_shot_class = Class.new(RubyOpt::Pass) do
      attr_reader :call_count
      def initialize; @call_count = Hash.new(0); end
      def one_shot?; true; end
      def apply(function, type_env:, log:, **_extras)
        @call_count[function.name] += 1
      end
      def name; :one_shot_tracker; end
    end
    one_shot = one_shot_class.new

    ir = cascade_ir_with_marker
    pipeline = RubyOpt::Pipeline.new([one_shot, CascadePassA.new, CascadePassB.new])
    pipeline.run(ir, type_env: nil)
    assert one_shot.call_count.values.all? { |c| c == 1 }, one_shot.call_count.inspect
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

# A pass that rewrites instruction X→Y on each function that still contains X,
# logging :cascade_a. Idempotent once X is gone.
class CascadePassA < RubyOpt::Pass
  def apply(function, type_env:, log:, **_extras)
    return unless (function.instructions || []).any? { |i| i.opcode == :x_marker }
    function.instructions.each do |i|
      i.opcode = :y_marker if i.opcode == :x_marker
    end
    log.rewrite(pass: :cascade_a, reason: :x_to_y, file: function.path || "", line: 0)
  end

  def name; :cascade_a; end
end

# A pass that rewrites Y→Z, logging :cascade_b. Idempotent once Y is gone.
class CascadePassB < RubyOpt::Pass
  def apply(function, type_env:, log:, **_extras)
    return unless (function.instructions || []).any? { |i| i.opcode == :y_marker }
    function.instructions.each do |i|
      i.opcode = :z_marker if i.opcode == :y_marker
    end
    log.rewrite(pass: :cascade_b, reason: :y_to_z, file: function.path || "", line: 0)
  end

  def name; :cascade_b; end
end

class PipelineAccessorTest < Minitest::Test
  def test_passes_accessor_returns_configured_passes
    passes = [Object.new, Object.new]
    pipeline = RubyOpt::Pipeline.new(passes)
    assert_equal passes, pipeline.passes
  end

  def test_default_pipeline_pass_names_are_symbols
    names = RubyOpt::Pipeline.default.passes.map(&:name)
    assert(names.all? { |n| n.is_a?(Symbol) })
    assert_includes names, :inlining
  end
end
