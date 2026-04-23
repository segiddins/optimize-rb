# frozen_string_literal: true
require "json"

module RubyOpt
  module Demo
    module Claude
      # Accumulates the per-iteration state of a Claude "gag pass" run
      # and renders a Markdown transcript suitable for inclusion in
      # demo artifacts. Stateful — instantiate one per fixture run.
      class Transcript
        def initialize(fixture:, source:, cases:)
          @fixture = fixture
          @source = source
          @cases = cases
          @iterations = []
          @outcome = nil
        end

        def record(iteration:, prompt:, raw:, parsed:, errors:)
          @iterations << {
            iteration: iteration,
            prompt: prompt,
            raw: raw,
            parsed: parsed,
            errors: errors,
          }
        end

        def finish(outcome:)
          unless %i[success gave_up].include?(outcome)
            raise ArgumentError, "unknown outcome: #{outcome.inspect}"
          end
          @outcome = outcome
        end

        def render
          unless %i[success gave_up].include?(@outcome)
            raise ArgumentError, "transcript outcome not set (got #{@outcome.inspect}); call finish(outcome:) first"
          end

          out = +""
          out << "# Claude gag — #{@fixture}\n"
          out << "\n"
          out << "**Fixture source:**\n"
          out << "\n"
          out << "```ruby\n"
          out << "#{@source.strip}\n"
          out << "```\n"
          out << "\n"
          out << "**Validation cases:**\n"
          out << "\n"
          @cases.each { |entry, expected| out << "- `#{entry}` → `#{expected.inspect}`\n" }

          @iterations.each do |rec|
            out << "\n"
            out << "## Iteration #{rec[:iteration]}\n"
            out << "\n"
            out << "**Prompt:**\n"
            out << "\n"
            out << "```\n"
            out << "#{rec[:prompt]}\n"
            out << "```\n"
            out << "\n"
            out << "**Raw response:**\n"
            out << "\n"
            out << "```\n"
            out << "#{rec[:raw]}\n"
            out << "```\n"
            out << "\n"
            out << "**Parsed IR:**\n"
            out << "\n"
            out << "```json\n"
            out << "#{JSON.generate(rec[:parsed])}\n"
            out << "```\n"
            out << "\n"
            if rec[:errors].empty?
              out << "**Validator errors:** (none)\n"
            else
              out << "**Validator errors:**\n"
              rec[:errors].each { |e| out << "- #{e}\n" }
            end
          end

          out << "\n"
          case @outcome
          when :success
            out << "## Outcome: success\n"
          when :gave_up
            out << "## Outcome: gave up after #{@iterations.length} attempts\n"
          end

          out
        end
      end
    end
  end
end
