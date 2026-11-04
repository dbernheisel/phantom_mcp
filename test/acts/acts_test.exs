defmodule Phantom.ACTSTest do
  use ExUnit.Case, async: false

  alias Phantom.Test.ACTS

  @moduletag :acts
  @moduletag timeout: :infinity

  setup_all do
    for child <- ACTS.children(), do: start_supervised!(child)
    :ok
  end

  test "the JSON-RPC and HTTP+JSON bindings pass the A2A conformance suite" do
    {_status, output, reports} = ACTS.run()
    assert Map.keys(reports) == ["jsonrpc", "rest"], output

    for {binding, report} <- reports do
      results = ACTS.results(report)
      failed = Map.get(results, "fail", []) ++ Map.get(results, "error", [])
      expected = ACTS.expected_failures()

      assert {binding, failed -- expected, expected -- failed} == {binding, [], []}, """
      Unexpected failures, then expected failures that passed. Update
      test/acts/expected-failures.yml as fixes land.

      #{output}
      """
    end
  end
end
