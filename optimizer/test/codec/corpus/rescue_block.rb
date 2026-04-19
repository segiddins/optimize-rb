def safe_divide(a, b)
  a / b
rescue ZeroDivisionError => e
  :nope
end

safe_divide(10, 2)
safe_divide(10, 0)
