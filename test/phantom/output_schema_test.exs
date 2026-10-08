defmodule Phantom.OutputSchemaTest do
  use ExUnit.Case, async: true

  defmodule Router do
    use Phantom.Router, name: "OutputSchema", vsn: "1.0"

    @output_schema %{
      type: "object",
      required: [:message],
      properties: %{message: %{type: "string"}}
    }

    tool :failing_tool, description: "Always fails", output_schema: @output_schema
    tool :invalid_output_tool, description: "Breaks its schema", output_schema: @output_schema

    def failing_tool(_params, session) do
      {:reply, Phantom.Tool.error("reason"), session}
    end

    def invalid_output_tool(_params, session) do
      {:reply, %{message: 1}, session}
    end
  end

  import Phantom.Test

  setup do
    Phantom.Test.start(router: Router)
    {:ok, session: build_session(Router)}
  end

  test "an error reply skips output schema validation", %{session: session} do
    session
    |> call_tool(:failing_tool, %{})
    |> assert_tool_error("reason")
  end

  test "a success reply that violates the output schema is rejected", %{session: session} do
    session
    |> call_tool(:invalid_output_tool, %{})
    |> assert_tool_error(~r/Invalid tool output/)
  end
end
