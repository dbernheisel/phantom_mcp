defmodule Phantom.A2A.Test do
  @moduledoc """
  Test helpers for A2A agents served from a `Phantom.Router`.

  Each helper sends a request through `Phantom.A2A.Plug` in the test process,
  so `c:Phantom.Router.connect/2`, allow-lists, and validation all run.
  Results are the decoded JSON the client would receive.

      import Phantom.A2A.Test

      test "reviews a study" do
        assert {:task, %{"id" => task_id}} =
                 send_message(MyApp.MCP.Router, "research", "Review study 42",
                   headers: [{"authorization", "Bearer " <> token}]
                 )
      end

  ## Options

    * `:headers` - request headers, such as `authorization`
    * `:pubsub`, `:blocking_timeout` - passed to `Phantom.A2A.Plug`
    * `:configuration` - the `SendMessage` configuration, for `send_message/4`
  """

  alias Phantom.A2A.Message

  @doc "Fetch an agent's card"
  def get_card(router, agent_id, opts \\ []) do
    conn = request(:get, router, agent_id <> "/agent-card.json", nil, opts)
    JSON.decode!(conn.resp_body)
  end

  @doc """
  Send a message, given as text or a `Phantom.A2A.Message`. Returns
  `{:message, json}`, `{:task, json}`, or `{:error, json}`.
  """
  def send_message(router, agent_id, message, opts \\ [])

  def send_message(router, agent_id, text, opts) when is_binary(text),
    do: send_message(router, agent_id, Message.user(text), opts)

  def send_message(router, agent_id, %Message{} = message, opts) do
    params =
      Phantom.Utils.remove_nils(%{
        "message" => Message.to_json(message),
        "configuration" => opts[:configuration]
      })

    case rpc(router, agent_id, "SendMessage", params, opts) do
      {:ok, %{"message" => message}} -> {:message, message}
      {:ok, %{"task" => task}} -> {:task, task}
      error -> error
    end
  end

  @doc "Fetch a task. Returns `{:ok, json}` or `{:error, json}`."
  def get_task(router, agent_id, task_id, opts \\ []),
    do: rpc(router, agent_id, "GetTask", %{"id" => task_id}, opts)

  @doc "Cancel a task. Returns `{:ok, json}` or `{:error, json}`."
  def cancel_task(router, agent_id, task_id, opts \\ []),
    do: rpc(router, agent_id, "CancelTask", %{"id" => task_id}, opts)

  defp rpc(router, agent_id, method, params, opts) do
    body = %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params}

    case JSON.decode!(request(:post, router, agent_id, body, opts).resp_body) do
      %{"result" => result} -> {:ok, result}
      %{"error" => error} -> {:error, error}
    end
  end

  defp request(method, router, path, body, opts) do
    plug_opts =
      Phantom.A2A.Plug.init(
        Keyword.merge(
          [router: router, validate_origin: false],
          Keyword.take(opts, [:pubsub, :blocking_timeout])
        )
      )

    headers = [{"a2a-version", "1.0"} | Keyword.get(opts, :headers, [])]

    method
    |> Plug.Test.conn("/" <> path)
    |> Map.merge(%{body_params: body || %{}, params: body || %{}})
    |> then(fn conn ->
      Enum.reduce(headers, conn, fn {k, v}, conn -> Plug.Conn.put_req_header(conn, k, v) end)
    end)
    |> Phantom.A2A.Plug.call(plug_opts)
  end
end
