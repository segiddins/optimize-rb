# TODOs

- **Publish as `optimize` gem**: Get the optimizer ready for release on rubygems.org as the `optimize` gem. Whole repo becomes `optimize-rb` — no split.
  - [x] Name `optimize` confirmed available on rubygems.org.
  - [x] Module rename `RubyOpt` → `Optimize`, `lib/ruby_opt/` → `lib/optimize/`.
  - [x] Three entry points wired: `Optimize.optimize`, `Optimize::Pipeline.default.run`, `Optimize::Harness.install`.
  - [x] `optimize.gemspec` at `optimizer/optimize.gemspec` (MIT, `required_ruby_version >= 4.0`, prism runtime dep, homepage github.com/segiddins/optimize-rb, v0.0.1).
  - [x] `optimizer/LICENSE` (MIT).
  - [x] Root `README.md` reoriented around the `optimize` gem.
  - [ ] Rewrite `optimizer/README.md` — currently opens "Talk-artifact Ruby optimizer. Companion to `docs/superpowers/specs/...`"; needs a release-quality intro and drop the spec cross-reference.
  - [ ] Write `CHANGELOG.md`.
  - [ ] Rename the GitHub repo from `ruby-the-hard-way-bytecode-talk` to `optimize-rb`.
  - [ ] Set up rubygems.org trusted publishing (OIDC) and a GitHub Actions release workflow triggered on `v*` tags.
  - [ ] Tag `v0.0.1` and cut the first release.
