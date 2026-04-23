# frozen_string_literal: true
require "json"
require "ruby_opt/codec"
require "ruby_opt/demo/claude/serializer"
require "ruby_opt/demo/claude/validator"
require "ruby_opt/demo/claude/prompt"
require "ruby_opt/demo/claude/invoker"
require "ruby_opt/demo/claude/transcript"

module RubyOpt
  module Demo
    module Claude
      # Orchestrator for the "gag pass" demo: wires Serializer, Validator,
      # Prompt, Invoker, and Transcript into a retry loop.
      #
      # `invoker` is dependency-injected. Production uses Invoker (shell out);
      # tests pass a stub whose `.call(prompt:)` returns a pre-parsed Array.
      Outcome = Struct.new(:outcome, :transcript, keyword_init: true)

      module_function

      # @param entry [Symbol] method name to locate in the iseq tree
      # @param cases [Array<Array(String, Object)>] list of
      #   [entry_source, expected] pairs. `entry_source` is evaluated via
      #   TOPLEVEL_BINDING after the iseq is loaded; result compared with ==.
      #   Validation must pass for EVERY case; multiple cases catch Claude
      #   table-looking-up a single expected answer instead of rewriting.
      # @return [Outcome]
      def run(fixture_path:, entry:, cases:, invoker: Invoker, max_iterations: 3)
        raise ArgumentError, "cases must not be empty" if cases.empty?

        source = File.read(fixture_path)
        iseq = RubyVM::InstructionSequence.compile_file(fixture_path)
        envelope = RubyOpt::Codec.decode(iseq.to_binary)
        object_table = envelope.misc[:object_table]

        target_fn = find_function(envelope, entry.to_s) or
          raise ArgumentError, "entry method #{entry} not found"

        iseq_json = Serializer.serialize(target_fn, object_table: object_table)

        transcript = Transcript.new(
          fixture: File.basename(fixture_path, ".rb"),
          source: source,
          cases: cases,
        )

        initial_prompt = Prompt.initial(iseq_json: iseq_json)

        accumulated_prompt = initial_prompt
        last_errors = nil

        max_iterations.times do |i|
          prompt_for_this_call =
            if i.zero?
              initial_prompt
            else
              accumulated_prompt + "\n\n" + Prompt.retry_message(errors: last_errors)
            end
          accumulated_prompt = prompt_for_this_call

          parsed = nil
          raw_display = nil
          errors = nil

          begin
            parsed = invoker.call(prompt: prompt_for_this_call)
            raw_display = JSON.generate(parsed)
          rescue Invoker::ParseError => e
            errors = ["could not parse assistant JSON: #{e.message}"]
            parsed = nil
            raw_display = "(parse failed)"
          end

          if errors.nil?
            # Try deserialize.
            attempt = nil
            begin
              attempt = Serializer.deserialize(
                parsed,
                template: target_fn,
                object_table: object_table,
                strict: false,
              )
            rescue Serializer::DeserializeError => e
              errors = ["deserialize failed: #{e.message}"]
            end

            if errors.nil?
              errors = Validator.structural(attempt)
              if errors.empty?
                modified = substitute_function(envelope, target_fn, attempt)
                errors = Validator.semantic(modified, cases: cases)
              end
            end
          end

          transcript.record(
            iteration: i + 1,
            prompt: prompt_for_this_call,
            raw: raw_display,
            parsed: parsed,
            errors: errors,
          )

          if errors.empty?
            transcript.finish(outcome: :success)
            return Outcome.new(outcome: :success, transcript: transcript)
          end

          last_errors = errors
        end

        transcript.finish(outcome: :gave_up)
        Outcome.new(outcome: :gave_up, transcript: transcript)
      end

      # Recursive walk of the iseq tree to find a function by name.
      def find_function(node, name)
        return node if node.name == name
        (node.children || []).each do |child|
          found = find_function(child, name)
          return found if found
        end
        nil
      end

      # Returns a shallow-copied envelope where `original_fn` (matched by
      # object identity) is replaced by `replacement`. The envelope's
      # iseq_list — which is what Codec.encode actually reads — is also
      # cloned with an updated functions array, so the replacement makes
      # it into the encoded binary.
      def substitute_function(envelope, original_fn, replacement)
        new_functions = envelope.children.map do |fn|
          fn.equal?(original_fn) ? replacement : fn
        end
        return envelope if new_functions.each_with_index.all? { |fn, i| fn.equal?(envelope.children[i]) }

        original_iseq_list = envelope.misc[:iseq_list]
        new_iseq_list = original_iseq_list.dup
        new_iseq_list.instance_variable_set(:@functions, new_functions)
        if original_iseq_list.root.equal?(original_fn)
          new_iseq_list.instance_variable_set(:@root, replacement)
        end

        cloned = envelope.dup
        cloned.children = new_functions
        cloned.misc = envelope.misc.merge(iseq_list: new_iseq_list)
        cloned
      end
    end
  end
end
