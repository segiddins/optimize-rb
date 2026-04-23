# frozen_string_literal: true

def sum_of_squares(n)
  s = 0
  i = 1
  while i <= n
    s += i * i
    i += 1
  end
  s
end
