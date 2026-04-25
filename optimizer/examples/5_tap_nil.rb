def tap
  yield self
  self
end

5.tap { nil }
