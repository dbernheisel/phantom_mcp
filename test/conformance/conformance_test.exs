defmodule Phantom.ConformanceTest do
  use ExUnit.Case, async: false

  alias Phantom.Test.Conformance

  @moduletag :conformance
  @moduletag :clustered
  @moduletag timeout: :infinity

  setup_all do
    Conformance.start()
  end

  for topology <- [:single, :distributed], revision <- ["2025-11-25", "2026-07-28"] do
    @tag topology: topology, revision: revision
    test "#{topology} node(s) meet the #{revision} requirements", context do
      {status, output} = Conformance.run(context.topology, context.revision)
      assert status == 0, output
    end
  end
end
