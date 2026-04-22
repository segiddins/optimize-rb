# frozen_string_literal: true
require "test_helper"
require "ruby_opt/demo/walkthrough"

class SidecarValidationTest < Minitest::Test
  EXAMPLES_DIR = File.expand_path("../../examples", __dir__)

  Dir[File.join(EXAMPLES_DIR, "*.walkthrough.yml")].each do |sidecar|
    stem = File.basename(sidecar, ".walkthrough.yml")
    define_method("test_sidecar_valid_#{stem}") do
      wt = RubyOpt::Demo::Walkthrough.load(sidecar)
      assert File.exist?(wt.fixture_path),
             "fixture file #{wt.fixture_path} does not exist"
      refute_empty wt.walkthrough
    end
  end

  def test_at_least_one_sidecar_present
    refute_empty Dir[File.join(EXAMPLES_DIR, "*.walkthrough.yml")]
  end
end
