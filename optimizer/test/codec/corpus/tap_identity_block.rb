def my_tap; yield self; self; end
public :my_tap
x = 42
x.my_tap { |y| y }
