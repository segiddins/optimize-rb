# frozen_string_literal: true
require "json"

module Optimize
  module Demo
    module Claude
      # Builds the user-facing prompts sent to `claude -p` during the
      # LLM "gag pass" optimization demo. Kept as a plain string builder
      # (no network, no IO) so it can be unit-tested against golden
      # fixtures.
      module Prompt
        module_function

        INITIAL_TEMPLATE = <<~PROMPT
          You are given a YARV iseq as a JSON array of instructions. Emit a semantically equivalent but optimized iseq. The rewrite must preserve behavior for all inputs.

          Constraints:
          - Output a single JSON array of [opcode_string, ...operands] tuples.
          - Each opcode must be a real YARV opcode (examples: putobject, opt_plus, opt_minus, opt_mult, opt_div, opt_mod, leave, pop, dup, getlocal_WC_0, setlocal_WC_0).
          - Preserve stack discipline: the iseq must end with a value on the stack, consumed by `leave`.
          - Do not add or remove locals; the local table is fixed.
          - Call-data operands are objects of the form {"mid": String, "argc": Integer, "flag": Integer}.

          Input iseq:
          %<iseq_json>s

          Reply with ONLY the JSON array. No prose, no fences.
        PROMPT

        RETRY_TEMPLATE = <<~PROMPT
          Your previous response was rejected:
          %<errors>s

          Emit a corrected iseq as a JSON array. Reply with ONLY the JSON array.
        PROMPT

        # Returns a String: the initial user message sent to `claude -p`.
        #
        # Deliberately minimal: the prompt carries only the iseq and
        # generalized constraints. No source, no test cases, no expected
        # values. Claude must infer the behavior from the instruction
        # stream alone — otherwise the comparison between its rewrite and
        # our peephole pipeline is unfair. The orchestrator validates
        # behavior on multiple inputs post-hoc.
        def initial(iseq_json:)
          format(INITIAL_TEMPLATE, iseq_json: JSON.generate(iseq_json))
        end

        # Returns a String: the retry user message appended after a rejection.
        def retry_message(errors:)
          bullets = errors.map { |e| "- #{e}" }.join("\n")
          format(RETRY_TEMPLATE, errors: bullets)
        end
      end
    end
  end
end
