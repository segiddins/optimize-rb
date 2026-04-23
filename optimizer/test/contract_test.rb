# frozen_string_literal: true
require "test_helper"
require "optimize/contract"

class ContractTest < Minitest::Test
  def test_all_five_clauses_are_asserted
    c = Optimize::Contract
    assert c.no_bop_redefinition?
    assert c.no_prepend_after_load?
    assert c.rbs_signatures_truthful?
    assert c.env_read_only?
    assert c.no_constant_reassignment?
  end

  def test_clauses_returns_all_five
    assert_equal 5, Optimize::Contract.clauses.size
    assert_includes Optimize::Contract.clauses, :no_bop_redefinition
  end

  def test_describe_returns_human_readable_strings
    text = Optimize::Contract.describe
    assert_kind_of String, text
    assert_match(/BOP/i, text)
    assert_match(/prepend/i, text)
    assert_match(/RBS/, text)
    assert_match(/ENV/, text)
    assert_match(/constant/i, text)
  end
end
