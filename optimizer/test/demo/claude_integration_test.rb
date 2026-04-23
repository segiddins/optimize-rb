# frozen_string_literal: true
require "test_helper"
require "ruby_opt/demo/claude"
require "ruby_opt/demo/claude/serializer"
require "ruby_opt/codec"

module RubyOpt
  module Demo
    module Claude
      class ClaudeIntegrationTest < Minitest::Test
        FIXTURE_PATH = File.expand_path("../../examples/claude_gag.rb", __dir__)

        class FakeInvoker
          def initialize(responses)
            @responses = responses.dup
            @calls = 0
          end
          attr_reader :calls

          def call(prompt:)
            @calls += 1
            raise "out of responses" if @responses.empty?
            @responses.shift
          end
        end

        class FakeInvokerWithParseErrors
          def initialize(parse_error_count:, then_response:)
            @remaining_errors = parse_error_count
            @then_response = then_response
          end

          def call(prompt:)
            if @remaining_errors > 0
              @remaining_errors -= 1
              raise Invoker::ParseError, "simulated parse error"
            end
            @then_response
          end
        end

        def correct_json_for_fixture
          iseq = RubyVM::InstructionSequence.compile_file(FIXTURE_PATH)
          envelope = RubyOpt::Codec.decode(iseq.to_binary)
          object_table = envelope.misc[:object_table]
          target = find_fn(envelope, "answer") or raise "no answer fn"
          Serializer.serialize(target, object_table: object_table)
        end

        def find_fn(fn, name)
          return fn if fn.name == name
          (fn.children || []).each do |c|
            found = find_fn(c, name)
            return found if found
          end
          nil
        end

        def teardown
          Object.send(:remove_method, :answer) if Object.method_defined?(:answer) || Object.private_method_defined?(:answer)
        rescue NameError
          nil
        end

        def test_success_on_first_try
          invoker = FakeInvoker.new([correct_json_for_fixture])
          outcome = Claude.run(
            fixture_path: FIXTURE_PATH,
            entry: :answer,
            expected: 5,
            invoker: invoker,
            max_iterations: 3,
          )
          assert_equal :success, outcome.outcome
          assert_equal 1, outcome.transcript.instance_variable_get(:@iterations).size
        end

        def test_success_on_third_try
          bogus1 = [["bogus_opcode"]]
          bogus2 = [["putobject", 999], ["leave"]] # wrong return (and missing leave arity ok)
          correct = correct_json_for_fixture
          invoker = FakeInvoker.new([bogus1, bogus2, correct])
          outcome = Claude.run(
            fixture_path: FIXTURE_PATH,
            entry: :answer,
            expected: 5,
            invoker: invoker,
            max_iterations: 3,
          )
          assert_equal :success, outcome.outcome
          assert_equal 3, outcome.transcript.instance_variable_get(:@iterations).size
        end

        def test_gave_up_after_three_failures
          bad = [["bogus_opcode"]]
          invoker = FakeInvoker.new([bad, bad, bad])
          outcome = Claude.run(
            fixture_path: FIXTURE_PATH,
            entry: :answer,
            expected: 5,
            invoker: invoker,
            max_iterations: 3,
          )
          assert_equal :gave_up, outcome.outcome
          assert_equal 3, outcome.transcript.instance_variable_get(:@iterations).size
        end

        def test_parse_failure_gets_fed_back
          invoker = FakeInvokerWithParseErrors.new(
            parse_error_count: 1,
            then_response: correct_json_for_fixture,
          )
          outcome = Claude.run(
            fixture_path: FIXTURE_PATH,
            entry: :answer,
            expected: 5,
            invoker: invoker,
            max_iterations: 3,
          )
          assert_equal :success, outcome.outcome
          iters = outcome.transcript.instance_variable_get(:@iterations)
          assert_equal 2, iters.size
          assert(iters[0][:errors].any? { |e| e.include?("could not parse assistant JSON") },
                 "expected parse-error message, got: #{iters[0][:errors].inspect}")
          assert_equal "(parse failed)", iters[0][:raw]
        end

        def test_raises_when_entry_not_found
          assert_raises(ArgumentError) do
            Claude.run(
              fixture_path: FIXTURE_PATH,
              entry: :nonexistent,
              expected: 5,
              invoker: FakeInvoker.new([]),
              max_iterations: 1,
            )
          end
        end
      end
    end
  end
end
