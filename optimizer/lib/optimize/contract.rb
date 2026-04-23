# frozen_string_literal: true

module Optimize
  # The hardcoded ground rules the optimizer assumes. Accepting the
  # optimizer means accepting all five. Breaking any is a miscompile,
  # not a slowdown.
  module Contract
    CLAUSES = {
      no_bop_redefinition: "Core basic operations (Integer#+, Array#[], String#==, ...) are not redefined.",
      no_prepend_after_load: "No `prepend` into any class after load; method tables are stable.",
      rbs_signatures_truthful: "Inline RBS signatures accurately describe runtime types.",
      env_read_only: "`ENV` is read-only after load; `ENV[\"X\"]` resolves once.",
      no_constant_reassignment: "Top-level constants are assigned exactly once; no `const_set` after load.",
    }.freeze

    module_function

    def clauses
      CLAUSES.keys
    end

    def describe
      CLAUSES.map { |k, v| "- #{k}: #{v}" }.join("\n")
    end

    CLAUSES.each_key do |clause|
      define_method("#{clause}?") { true }
    end
  end
end
