def same_op_mult(x)
  x * 2 * 3
end

def same_op_div(x)
  x / 2 / 3
end

def mixed_trailing_div(x)
  x * 2 * 3 / 4 / 5
end

def boundary_no_fold(x)
  x * 2 / 3 * 4
end

def literal_prefix(x)
  2 * 3 / 6 * x
end

def with_two_non_literals(x, y)
  x * y * 2 * 3
end

def divisor_zero_runtime_trap(x)
  x / 2 / 0
end

def divisor_negative(x)
  x / -3 / -2
end

[1, 42, -7].each do |v|
  same_op_mult(v)
  same_op_div(60)
  mixed_trailing_div(100)
  boundary_no_fold(v)
  literal_prefix(v)
  with_two_non_literals(v, v + 1)
  divisor_negative(12)
end
