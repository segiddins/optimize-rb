def greet(name:, greeting: "hi", **opts)
  "#{greeting}, #{name}"
end

greet(name: "alice")
greet(name: "bob", greeting: "hola")
