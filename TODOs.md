# TODOs

- **Research kickoff**: "Let's start populating `research/yarv/`. Give me a rundown of the YARV instruction categories and we'll add a notes file per category."
- **Verify MCP wiring**: "Use the ruby-bytecode MCP to disasm `def add(a,b); a+b; end; add(1,2)` — I want to confirm everything's hooked up before we dig in."
- **Talk structure**: "Look at `talk/outline.md` and help me brainstorm the cold open for section 0 — I want a concrete production hotspot story."
- **Prior art pass**: "Search RubyKaigi talks from the last 3 years for anything that touches YARV/bytecode and add entries to `research/prior-art/`."
- **Publish as `optimize` gem**: Get the optimizer ready for release on rubygems.org as the `optimize` gem.
  - [x] Name `optimize` confirmed available on rubygems.org.
  - [x] Module rename `RubyOpt` → `Optimize`, `lib/ruby_opt/` → `lib/optimize/`.
  - [x] Three entry points wired: `Optimize.optimize`, `Optimize::Pipeline.default.run`, `Optimize::Harness.install`.
  - [x] `optimize.gemspec` at `optimizer/optimize.gemspec` (MIT, `required_ruby_version >= 4.0`, prism runtime dep, homepage github.com/segiddins/optimize-rb, v0.0.1).
  - [ ] Create the `segiddins/optimize-rb` GitHub repo; decide whether to split the code out of this talk repo or publish from here.
  - [ ] Write `CHANGELOG.md`, confirm `README.md` is release-quality (current README is talk-artifact-flavored).
  - [ ] Set up rubygems.org trusted publishing (OIDC) and a GitHub Actions release workflow triggered on `v*` tags.
  - [ ] Tag `v0.0.1` and cut the first release.
