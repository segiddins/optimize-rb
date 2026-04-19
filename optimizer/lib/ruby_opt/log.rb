# frozen_string_literal: true

module RubyOpt
  class Log
    Entry = Struct.new(:pass, :reason, :file, :line, keyword_init: true)

    def initialize
      @entries = []
    end

    def entries
      @entries.dup.freeze
    end

    def skip(pass:, reason:, file:, line:)
      @entries << Entry.new(pass: pass, reason: reason, file: file, line: line)
    end

    def for_pass(pass)
      @entries.select { |e| e.pass == pass }
    end
  end
end
