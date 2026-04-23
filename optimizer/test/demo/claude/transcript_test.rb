# frozen_string_literal: true
require "test_helper"
require "optimize/demo/claude/transcript"

module Optimize
  module Demo
    module Claude
      class TranscriptTest < Minitest::Test
        FIXTURES = File.expand_path("fixtures", __dir__)

        def build_transcript
          Transcript.new(
            fixture: "claude_gag",
            source: "def answer\n  2 + 3\nend",
            cases: [["answer", 5]],
          )
        end

        def test_renders_success_after_two_failures
          t = build_transcript
          t.record(
            iteration: 1,
            prompt: "p1",
            raw: "[[\"bad\"]]",
            parsed: [["bad"]],
            errors: ["instruction 0: unknown opcode :bad"],
          )
          t.record(
            iteration: 2,
            prompt: "p2",
            raw: "[[\"putobject\",7],[\"leave\"]]",
            parsed: [["putobject", 7], ["leave"]],
            errors: ["iseq returned 7; expected 5"],
          )
          t.record(
            iteration: 3,
            prompt: "p3",
            raw: "[[\"putobject\",5],[\"leave\"]]",
            parsed: [["putobject", 5], ["leave"]],
            errors: [],
          )
          t.finish(outcome: :success)

          golden = File.read(File.join(FIXTURES, "transcript_success.md"))
          assert_equal golden, t.render
        end

        def test_renders_gave_up
          t = build_transcript
          t.record(iteration: 1, prompt: "p", raw: "r", parsed: [], errors: ["err0"])
          t.record(iteration: 2, prompt: "p", raw: "r", parsed: [], errors: ["err1"])
          t.record(iteration: 3, prompt: "p", raw: "r", parsed: [], errors: ["err2"])
          t.finish(outcome: :gave_up)

          golden = File.read(File.join(FIXTURES, "transcript_gave_up.md"))
          assert_equal golden, t.render
        end

        def test_renders_error_on_unknown_outcome
          t = build_transcript
          err = assert_raises(ArgumentError) { t.render }
          assert_match(/outcome/i, err.message)

          assert_raises(ArgumentError) { t.finish(outcome: :weird) }
        end
      end
    end
  end
end
