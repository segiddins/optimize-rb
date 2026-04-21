def mult_right_identity(x)
  x * 1
end

def mult_left_identity(x)
  1 * x
end

def plus_right_identity(x)
  x + 0
end

def plus_left_identity(x)
  0 + x
end

def minus_right_identity(x)
  x - 0
end

def div_right_identity(x)
  x / 1
end

def cascade(x)
  x * 1 * 1 + 0 - 0
end

def pipeline_full_collapse(x)
  2 * 3 / 6 * x
end

def leave_alone_non_identity(x)
  x * 2 + 0 - 1
end

[1, 42, -7].each do |v|
  mult_right_identity(v)
  mult_left_identity(v)
  plus_right_identity(v)
  plus_left_identity(v)
  minus_right_identity(v)
  div_right_identity(v == 0 ? 1 : v)
  cascade(v)
  pipeline_full_collapse(v)
  leave_alone_non_identity(v)
end
