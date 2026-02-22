defmodule Phantom.Stdio do
  @moduledoc """
  MCP server transport over stdin/stdout.

  This module implements the MCP stdio transport, allowing applications
  to expose an MCP server over stdin/stdout for local clients like
  Claude Desktop without needing an HTTP server.

  Messages are newline-delimited JSON, one JSON-RPC message per line.

  ## Usage

  Add to your supervision tree:

      children = [
        {Phantom.Stdio, router: MyApp.MCP.Router}
      ]

  ## Options

  - `:router` - The MCP router module (required)
  - `:input` - Input IO device (default: `:stdio`)
  - `:output` - Output IO device (default: `:stdio`)
  - `:session_timeout` - Session inactivity timeout (default: `:infinity`)
  - `:log` - Where to redirect the `:default` Logger handler at runtime.
    Defaults to `:stderr`. Set to a file path string to log to a file,
    or `false` to manage Logger configuration yourself (e.g. via
    `config :logger, :default_handler` in your application config).

  > #### Logger and stdout {: .warning}
  >
  > Elixir's default Logger handler writes to stdout, which would corrupt
  > the JSON-RPC stream. This option only redirects the `:default` handler.
  > If you have added custom Logger handlers that write to stdout, you must
  > redirect those yourself.

  To send logs to the MCP client, use `Phantom.ClientLogger` — it sends
  `notifications/message` notifications and works identically across
  stdio and HTTP transports.
  """

  alias Phantom.Cache
  alias Phantom.Session

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  def start_link(opts) do
    :proc_lib.start_link(__MODULE__, :init_stdio, [opts])
  end

  @doc false
  def init_stdio(opts) do
    router = Keyword.fetch!(opts, :router)
    input = Keyword.get(opts, :input, :stdio)
    output = Keyword.get(opts, :output, :stdio)
    timeout = Keyword.get(opts, :session_timeout, :infinity)

    configure_logger(Keyword.get(opts, :log, :stderr))

    if not Cache.initialized?(router), do: Cache.register(router)

    session =
      Session.new(nil,
        router: router,
        pid: self(),
        close_after_complete: false
      )

    case router.connect(session, %{headers: [], params: %{}}) do
      {:ok, session} ->
        :proc_lib.init_ack({:ok, self()})

        Session.start_loop(
          session: session,
          timeout: timeout,
          stream_fun: stream_fun(output),
          continue_fun: continue_fun(input)
        )

      {:error, reason} ->
        :proc_lib.init_ack({:error, reason})
        exit(:normal)

      {status, _} when status in [:unauthorized, 401, :forbidden, 403] ->
        :proc_lib.init_ack({:error, :unauthorized})
        exit(:normal)
    end
  end

  defp continue_fun(input) do
    fn state ->
      parent = self()

      spawn_link(fn ->
        Process.set_label({__MODULE__, :reader})
        read_loop(input, parent)
      end)

      state
    end
  end

  defp read_loop(input, parent) do
    case IO.read(input, :line) do
      :eof ->
        send(parent, {:phantom_reader_closed, :eof})

      {:error, reason} ->
        send(parent, {:phantom_reader_closed, reason})

      line when is_binary(line) ->
        line = String.trim(line)

        if line != "" do
          case JSON.decode(line) do
            {:ok, request} when is_list(request) ->
              send(parent, {:phantom_dispatch, request})

            {:ok, request} when is_map(request) ->
              send(parent, {:phantom_dispatch, [request]})

            {:error, _} ->
              send(parent, {:phantom_dispatch_error, :parse_error})
          end
        end

        read_loop(input, parent)
    end
  end

  defp configure_logger(false), do: :ok

  defp configure_logger(:stderr) do
    redirect_default_handler({:device, :stderr})
  end

  defp configure_logger(path) when is_binary(path) do
    redirect_default_handler({:file, String.to_charlist(path)})
  end

  defp redirect_default_handler(type) do
    with {:ok, config} <- :logger.get_handler_config(:default) do
      :logger.remove_handler(:default)

      :logger.add_handler(:default, :logger_std_h, %{
        config: Map.put(config.config, :type, type),
        formatter: config.formatter
      })
    end
  end

  defp stream_fun(output) do
    fn
      state, _id, "closed", _payload ->
        state

      state, _id, _event, payload when is_map(payload) and map_size(payload) == 0 ->
        IO.write(output, JSON.encode!(%{jsonrpc: "2.0", result: %{}}) <> "\n")
        state

      state, _id, _event, %{} = payload ->
        IO.write(output, JSON.encode!(payload) <> "\n")
        state

      state, _id, _event, _payload ->
        state
    end
  end
end
