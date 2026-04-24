defmodule Test.Stdio do
  @moduledoc false

  def main(_args) do
    # Redirect Logger to stderr — stdout is reserved for JSON-RPC.
    # Use Erlang's logger_formatter directly since the Logger app
    # isn't loaded yet in the escript.
    :logger.remove_handler(:default)

    :logger.add_handler(:default, :logger_std_h, %{
      config: %{type: {:device, :standard_error}},
      formatter: {:logger_formatter, %{template: [:time, " [", :level, "] ", :msg, "\n"]}}
    })

    Application.ensure_all_started(:telemetry)
    Application.ensure_all_started(:plug)

    {:ok, _} =
      Supervisor.start_link(
        [{Phantom.Stdio, router: Test.MCP.Router, log: false}],
        strategy: :one_for_one
      )

    Process.sleep(:infinity)
  end
end
