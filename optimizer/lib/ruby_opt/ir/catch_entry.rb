# frozen_string_literal: true

module RubyOpt
  module IR
    # One entry in a function's catch table. Positions are references
    # to IR::Instruction objects by identity, so mutations to the
    # instruction list don't invalidate them.
    #
    #   type         — one of :rescue, :ensure, :retry, :break, :redo, :next
    #   iseq_index   — index into the iseq-list for the handler iseq
    #                  (nil for entries without a handler iseq, such as :retry)
    #   start_inst   — IR::Instruction marking the start of the covered range
    #   end_inst     — IR::Instruction marking the end (exclusive)
    #   cont_inst    — IR::Instruction where control resumes after handling
    #                  (always present; for :retry entries this points to slot 0)
    #   stack_depth  — operand-stack depth at which the handler runs
    CatchEntry = Struct.new(
      :type, :iseq_index, :start_inst, :end_inst, :cont_inst, :stack_depth,
      keyword_init: true,
    )
  end
end
