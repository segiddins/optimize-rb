# frozen_string_literal: true

module RubyOpt
  # Abstract base class for optimizer passes. Subclasses override #apply
  # and optionally #name.
  class Pass
    # Run this pass on a single IR::Function. The pass may mutate
    # `function.instructions` or `function.children` but must log any
    # skipped optimization decisions to `log`.
    #
    # @param function [RubyOpt::IR::Function]
    # @param type_env [RubyOpt::TypeEnv, nil]
    # @param log     [RubyOpt::Log]
    def apply(function, type_env:, log:, object_table: nil, **_extras)
      raise NotImplementedError
    end

    def name
      self.class.name.to_s.split("::").last.sub(/Pass$/, "").downcase.to_sym
    end
  end

  # Pass that does nothing. Used to exercise the pipeline without depending
  # on real passes.
  class NoopPass < Pass
    def apply(function, type_env:, log:, object_table: nil, **_extras)
      # Intentionally empty.
    end

    def name
      :noop
    end
  end
end
