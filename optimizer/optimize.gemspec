# frozen_string_literal: true

require_relative "lib/optimize"

Gem::Specification.new do |spec|
  spec.name = "optimize"
  spec.version = Optimize::VERSION
  spec.authors = ["Samuel Giddins"]
  spec.email = ["segiddins@segiddins.me"]

  spec.summary = "Hand-rolled ISEQ optimizer for hot paths in pure Ruby"
  spec.description = <<~DESC
    Optimize is an ahead-of-time YARV bytecode optimizer for CRuby. It decodes
    iseq binaries into an in-memory IR, runs a configurable pipeline of passes
    (constant folding, inlining, dead-stash elimination, arithmetic
    reassociation, and others) under a narrow contract that the program's hot
    path respects, and re-emits an optimized iseq. Intended as a demo and an
    experiment, not a production compiler.
  DESC
  spec.homepage = "https://github.com/segiddins/optimize-rb"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 4.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir.chdir(__dir__) do
    `git ls-files -z`.split("\x0").reject do |f|
      f.start_with?("test/", "examples/", "bin/", "vendor/", "tmp/") ||
        f.match?(%r{\A(Gemfile(\.lock)?|Rakefile|\.rubocop\.yml|\.gitignore)\z})
    end
  end
  spec.require_paths = ["lib"]

  spec.add_dependency "prism", "~> 1.2"
end
