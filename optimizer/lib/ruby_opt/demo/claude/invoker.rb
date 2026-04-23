# frozen_string_literal: true
require "open3"
require "json"

module RubyOpt
  module Demo
    module Claude
      # Thin shell wrapper around `claude -p --output-format json`. Single-shot,
      # no retries — the caller is responsible for orchestration.
      module Invoker
        class CLIError < StandardError; end
        class ParseError < CLIError; end

        module_function

        # Shells out to `claude -p --output-format json`, pipes +prompt+ on
        # stdin. Returns the JSON-parsed assistant output (the contents of the
        # envelope's "result" field, re-parsed as JSON).
        #
        # @param prompt [String] prompt body, fed on stdin.
        # @param binary [String] path or name of the claude CLI.
        # @return [Object] parsed assistant JSON.
        # @raise [CLIError] on non-zero exit, missing "result" field, or
        #   unparseable outer envelope.
        # @raise [ParseError] when the assistant's "result" string cannot be
        #   parsed as JSON. ParseError < CLIError.
        def call(prompt:, binary: "claude")
          stdout, stderr, status = Open3.capture3(
            binary, "-p", "--output-format", "json", stdin_data: prompt
          )

          unless status.exitstatus.zero?
            raise CLIError, "#{binary} exited #{status.exitstatus}: #{stderr}"
          end

          envelope =
            begin
              JSON.parse(stdout)
            rescue JSON::ParserError => e
              raise CLIError, "could not parse #{binary} envelope: #{e.message}"
            end

          unless envelope.is_a?(Hash) && envelope.key?("result")
            raise CLIError,
                  "#{binary} envelope missing 'result' field: #{envelope.inspect[0, 200]}"
          end

          result_text = envelope["result"]

          begin
            JSON.parse(result_text)
          rescue JSON::ParserError => e
            raise ParseError, "could not parse assistant JSON: #{e.message}\n---\n#{result_text}"
          end
        end
      end
    end
  end
end
