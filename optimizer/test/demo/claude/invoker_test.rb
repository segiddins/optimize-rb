# frozen_string_literal: true
require "test_helper"
require "optimize/demo/claude/invoker"
require "open3"
require "json"

class InvokerTest < Minitest::Test
  Invoker = Optimize::Demo::Claude::Invoker

  def stub_status(code)
    Struct.new(:exitstatus, :success?).new(code, code.zero?)
  end

  def test_call_returns_parsed_assistant_json
    envelope = { "type" => "result", "result" => "[[\"putobject\",5],[\"leave\"]]" }
    result = Open3.stub(:capture3, [JSON.generate(envelope), "", stub_status(0)]) do
      Invoker.call(prompt: "x")
    end
    assert_equal [["putobject", 5], ["leave"]], result
  end

  def test_call_raises_CLIError_on_nonzero_exit
    err = assert_raises(Invoker::CLIError) do
      Open3.stub(:capture3, ["", "boom", stub_status(1)]) do
        Invoker.call(prompt: "x")
      end
    end
    assert_includes err.message, "boom"
  end

  def test_call_raises_CLIError_on_unparseable_envelope
    raised = assert_raises(Invoker::CLIError) do
      Open3.stub(:capture3, ["not json at all", "", stub_status(0)]) do
        Invoker.call(prompt: "x")
      end
    end
    refute_kind_of Invoker::ParseError, raised
  end

  def test_call_raises_CLIError_on_missing_result_field
    envelope = { "type" => "result", "subtype" => "success" }
    err = assert_raises(Invoker::CLIError) do
      Open3.stub(:capture3, [JSON.generate(envelope), "", stub_status(0)]) do
        Invoker.call(prompt: "x")
      end
    end
    assert_includes err.message, "missing 'result'"
  end

  def test_call_raises_ParseError_on_unparseable_assistant_output
    envelope = { "result" => "this is not json" }
    raised = assert_raises(Invoker::ParseError) do
      Open3.stub(:capture3, [JSON.generate(envelope), "", stub_status(0)]) do
        Invoker.call(prompt: "x")
      end
    end
    assert_kind_of Invoker::CLIError, raised
  end

  def test_ParseError_is_a_CLIError
    assert Invoker::ParseError < Invoker::CLIError
  end
end
