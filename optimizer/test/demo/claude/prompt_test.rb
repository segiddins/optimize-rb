# frozen_string_literal: true
require "test_helper"
require "optimize/demo/claude/prompt"

module Optimize
  module Demo
    module Claude
      class PromptTest < Minitest::Test
        FIXTURES = File.expand_path("fixtures", __dir__)

        def test_initial_matches_golden
          out = Prompt.initial(
            iseq_json: [["putobject", 2], ["putobject", 3], ["opt_plus", {"mid" => "+", "argc" => 1, "flag" => 16, "kwlen" => 0}], ["leave"]],
          )
          golden = File.read(File.join(FIXTURES, "initial_prompt.txt"))
          assert_equal golden, out
        end

        def test_retry_matches_golden
          out = Prompt.retry_message(errors: [
            "instruction 3: unknown opcode :opt_fastmath",
            "iseq returned 7; expected 5",
          ])
          golden = File.read(File.join(FIXTURES, "retry_prompt.txt"))
          assert_equal golden, out
        end
      end
    end
  end
end
