defmodule Phantom.ConformanceTest do
  use ExUnit.Case, async: false

  alias Phantom.Test.Conformance

  @moduletag :conformance
  @moduletag :clustered
  @moduletag timeout: :infinity

  # Requirement sets run these without scoring, so they cannot fail a run.
  @unscored_scenarios [
    {"server-session-lifecycle", "2025-11-25"},
    {"json-schema-2020-12", "2025-11-25"},
    {"json-schema-2020-12", "2026-07-28"}
  ]

  setup_all do
    Conformance.start()
  end

  for topology <- [:single, :distributed] do
    for revision <- ["2025-11-25", "2026-07-28"] do
      @tag topology: topology, revision: revision
      test "#{topology} node(s) meet the #{revision} requirements", context do
        {status, output} = Conformance.run(context.topology, context.revision)
        assert status == 0, output
      end
    end

    for {scenario, spec_version} <- @unscored_scenarios do
      @tag topology: topology, scenario: scenario, spec_version: spec_version
      test "#{topology} node(s) pass #{scenario} at #{spec_version}", context do
        {status, output} =
          Conformance.run_scenario(context.topology, context.scenario, context.spec_version)

        assert status == 0, output
      end
    end
  end
end
