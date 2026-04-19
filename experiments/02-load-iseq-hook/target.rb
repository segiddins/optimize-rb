# frozen_string_literal: true

# The "production" file. Ordinary Ruby — no awareness that it may be
# intercepted at load time.

class Greeter
  def greet(name, times)
    ("hi, #{name}! " * times).strip
  end
end
