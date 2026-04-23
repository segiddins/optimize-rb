# frozen_string_literal: true
require "test_helper"
require "optimize/demo/walkthrough"
require "tmpdir"

class WalkthroughTest < Minitest::Test
  def with_yaml(body)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "x.walkthrough.yml")
      File.write(path, body)
      yield path, dir
    end
  end

  def test_loads_valid_sidecar
    body = <<~YAML
      fixture: x.rb
      entry_setup: "a = 1"
      entry_call: "a + 1"
      walkthrough:
        - const_fold
        - dead_branch_fold
    YAML
    with_yaml(body) do |path, _dir|
      wt = Optimize::Demo::Walkthrough.load(path)
      assert_equal "x.rb", wt.fixture
      assert_equal "a = 1", wt.entry_setup
      assert_equal "a + 1", wt.entry_call
      assert_equal %i[const_fold dead_branch_fold], wt.walkthrough
    end
  end

  def test_rejects_unknown_pass_name
    body = <<~YAML
      fixture: x.rb
      entry_setup: ""
      entry_call: "1"
      walkthrough:
        - no_such_pass
    YAML
    with_yaml(body) do |path, _dir|
      err = assert_raises(Optimize::Demo::Walkthrough::InvalidSidecar) do
        Optimize::Demo::Walkthrough.load(path)
      end
      assert_match(/no_such_pass/, err.message)
    end
  end

  def test_fixture_path_resolves_relative_to_sidecar
    body = <<~YAML
      fixture: x.rb
      entry_setup: ""
      entry_call: "1"
      walkthrough: [const_fold]
    YAML
    with_yaml(body) do |path, dir|
      wt = Optimize::Demo::Walkthrough.load(path)
      assert_equal File.join(dir, "x.rb"), wt.fixture_path
    end
  end

  def test_missing_field_raises
    body = <<~YAML
      fixture: x.rb
      entry_call: "1"
      walkthrough: [const_fold]
    YAML
    with_yaml(body) do |path, _dir|
      assert_raises(Optimize::Demo::Walkthrough::InvalidSidecar) do
        Optimize::Demo::Walkthrough.load(path)
      end
    end
  end
end
