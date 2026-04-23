# frozen_string_literal: true

SCALE = 6

class Polynomial
  # @rbs (Integer) -> Integer
  def compute(n)
    (n * 2 * SCALE / 12) + 0
  end

  # @rbs () -> Integer
  def run
    if SCALE == 6 then compute(42) else compute(0) end
  end
end
