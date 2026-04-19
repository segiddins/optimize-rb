def each_pair; yield 1, 2; yield 3, 4; end
each_pair { |a, b| a + b }
