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
  - **Blockers for promoting `optimizer/*` to repo root:**
    - [ ] Resolve `bin/` collision — root `bin/ruby-bytecode-mcp` vs `optimizer/bin/{demo,demo-claude}`. Decide whether to fold the MCP launcher under `mcp-server/bin/` or keep a merged `bin/`.
    - [ ] Resolve `README.md` collision — merge the root gem-oriented README with `optimizer/README.md` (see rewrite item above); path reference `optimizer/optimize.gemspec` on line 7 goes stale after the move.
    - [ ] Lock down gemspec `files =` to an explicit allowlist (lib/, bin/ entries, LICENSE, README, CHANGELOG) before moving. At repo root a `git ls-files`-based glob would package `post.md`, `talk/`, `research/`, `docs/`, `mcp-server/`, `experiments/` into the gem.
    - [ ] Update `mcp-server` path coupling: `mcp-server/lib/ruby_bytecode_mcp/tools/run_optimizer_tests.rb` computes `File.join(repo_root, "optimizer")` and mounts it RW for Bundler's `vendor/bundle`. Post-move it needs a narrower mount set, not the whole talk repo RW. Also update comments in `mcp-server/Dockerfile.test` and `mcp-server/lib/ruby_bytecode_mcp/docker_runner.rb`.
    - [ ] Audit `.gitignore` for `optimizer/`-prefixed entries (e.g. `optimizer/vendor/bundle`, `optimizer/tmp`) and rewrite to root-relative paths.
