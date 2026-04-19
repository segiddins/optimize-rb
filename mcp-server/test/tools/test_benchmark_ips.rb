# frozen_string_literal: true

require_relative "../test_helper"

class TestBenchmarkIps < Minitest::Test
  include TestHelper

  def test_runs_two_scenarios_and_reports_ips
    skip_without_docker!
    response = RubyBytecodeMcp::Tools::BenchmarkIps.call(
      scenarios: [
        { "name" => "plus", "code" => "1 + 2" },
        { "name" => "times", "code" => "2 * 3" },
      ],
      warmup: 1,
      time: 1,
      server_context: nil,
    )
    text = response.content.first[:text]
    assert_match(/plus/, text)
    assert_match(/times/, text)
    assert_match(/i\/s/, text)
  end
end
