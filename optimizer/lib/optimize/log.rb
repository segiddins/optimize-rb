# frozen_string_literal: true

module Optimize
  class Log
    Entry = Struct.new(:pass, :reason, :file, :line, keyword_init: true)

    def initialize
      @entries = []
      @rewrite_count = 0
      @convergence = {}
    end

    def entries
      @entries.dup.freeze
    end

    attr_reader :rewrite_count, :convergence

    # An optimization site that actually rewrote IR. Feeds fixed-point
    # termination via rewrite_count.
    def rewrite(pass:, reason:, file:, line:)
      @entries << Entry.new(pass: pass, reason: reason, file: file, line: line)
      @rewrite_count += 1
    end

    # An optimization site that declined to rewrite. Does NOT count toward
    # rewrite_count — fixed-point iteration must not treat a decline as a
    # change.
    def skip(pass:, reason:, file:, line:)
      @entries << Entry.new(pass: pass, reason: reason, file: file, line: line)
    end

    def record_convergence(function_key, iterations)
      @convergence[function_key] = iterations
    end

    def for_pass(pass)
      @entries.select { |e| e.pass == pass }
    end
  end
end
