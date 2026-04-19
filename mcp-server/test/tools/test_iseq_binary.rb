# frozen_string_literal: true

require_relative "../test_helper"
require "json"

class TestIseqBinary < Minitest::Test
  include TestHelper

  def test_round_trip_prints_expected_output
    skip_without_docker!

    dump = RubyBytecodeMcp::Tools::IseqToBinary.call(
      code: "puts 40 + 2",
      server_context: nil,
    )
    payload = JSON.parse(dump.content.first[:text])
    assert payload["blob_b64"].is_a?(String)
    assert payload["size"].to_i.positive?

    load = RubyBytecodeMcp::Tools::LoadIseqBinary.call(
      blob_b64: payload["blob_b64"],
      call: true,
      server_context: nil,
    )
    text = load.content.first[:text]
    assert_match(/42/, text)
  end
end
