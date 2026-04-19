class Point
  def initialize(x, y)
    @x = x
    @y = y
  end

  def distance_to(other)
    dx = @x - other.instance_variable_get(:@x)
    dy = @y - other.instance_variable_get(:@y)
    Math.sqrt(dx * dx + dy * dy)
  end
end

Point.new(0, 0).distance_to(Point.new(3, 4))
