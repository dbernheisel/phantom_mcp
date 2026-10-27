defmodule Phantom.ACTSTest do
  use ExUnit.Case, async: false

  alias Phantom.Test.ACTS

  @moduletag :acts
  @moduletag timeout: :infinity

  setup_all do
    for child <- ACTS.children(), do: start_supervised!(child)
    :ok
  end

  test "the JSON-RPC binding passes the A2A conformance suite" do
    {_status, output, report} = ACTS.run()
    assert report, output

    results = ACTS.results(report)
    failed = Map.get(results, "fail", []) ++ Map.get(results, "error", [])
    expected = ACTS.expected_failures()

    assert {failed -- expected, expected -- failed} == {[], []}, """
    Unexpected failures, then expected failures that passed. Update
    test/acts/expected-failures.yml as fixes land.

    #{output}
    """
  end
end
