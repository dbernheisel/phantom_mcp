defmodule Phantom.TestDispatcher do
  import Plug.Conn
  import Plug.Test

  @opts Phantom.Plug.init(
          pubsub: Test.PubSub,
          router: Test.MCP.Router,
          validate_origin: false
        )

  @parser Plug.Parsers.init(
            parsers: [{:json, length: 1_000_000}],
            pass: ["application/json"],
            json_decoder: JSON
          )

  defmacro assert_response(id \\ 1, payload) do
    quote do
      assert_receive {:response, unquote(id), "message", unquote(payload)}
      assert_receive {:response, nil, "closed", "finished"}
    end
  end

  defmacro assert_exception_response(id \\ 1, payload, exception) do
    quote do
      assert_receive {:response, unquote(id), "message", unquote(payload)}
      assert_receive {:EXIT, _pid, unquote(exception)}
    end
  end

  defmacro assert_sse_connected() do
    quote do
      assert_receive {:plug_conn, :sent}
      refute_receive {:conn, _}
    end
  end

  defmacro assert_connected(conn) do
    quote do
      assert_receive {:plug_conn, :sent}
      assert_receive {:conn, unquote(conn)}
    end
  end

  defmacro assert_notify(payload) do
    quote do
      assert_receive {:response, nil, "message", unquote(payload)}
    end
  end

  def call(conn, opts \\ %{}) do
    opts = Map.new(opts)
    opts = Map.put_new(opts, :listener, self())
    {fun, opts} = Map.pop(opts, :before_call, & &1)
    {session_id, opts} = Map.pop(opts, :session_id)
    opts = Map.merge(@opts, opts)

    :proc_lib.spawn_link(fn ->
      result =
        conn
        |> Plug.Parsers.call(@parser)
        |> put_session_id(session_id)
        |> fun.()
        |> Phantom.Plug.call(opts)

      if pid = opts[:listener], do: send(pid, {:conn, result})
    end)
  end

  defp put_session_id(conn, nil), do: conn
  defp put_session_id(conn, id), do: put_req_header(conn, "mcp-session-id", id)

  def request_ping(init_opts \\ []) do
    :post
    |> conn("/mcp", %{jsonrpc: "2.0", method: "ping", id: 1})
    |> put_req_header("content-type", "application/json")
    |> call(Map.merge(@opts, Map.new(init_opts)))
  end

  def request_tool(name, args \\ %{}, init_opts \\ []) do
    {id, init_opts} = Keyword.pop(init_opts, :id, 1)

    :post
    |> conn("/mcp", %{
      jsonrpc: "2.0",
      id: id,
      method: "tools/call",
      params: %{"name" => name, "arguments" => args}
    })
    |> put_req_header("content-type", "application/json")
    |> call(Map.merge(@opts, Map.new(init_opts)))
  end

  def request_prompt_complete(name, attrs \\ []) do
    {id, attrs} = Keyword.pop(attrs, :id, 1)
    {arg, attrs} = Keyword.pop(attrs, :arg)
    {value, attrs} = Keyword.pop(attrs, :value)
    {context, attrs} = Keyword.pop(attrs, :context, %{})
    {init_opts, _attrs} = Keyword.pop(attrs, :init_opts, [])

    :post
    |> conn("/mcp", %{
      jsonrpc: "2.0",
      id: id,
      method: "completion/complete",
      params: %{
        ref: %{type: "ref/prompt", name: name},
        argument: %{name: arg, value: value},
        context: context
      }
    })
    |> put_req_header("content-type", "application/json")
    |> call(Map.merge(@opts, Map.new(init_opts)))
  end

  def request_resource_complete(name, attrs \\ []) do
    {id, attrs} = Keyword.pop(attrs, :id, 1)
    {arg, attrs} = Keyword.pop(attrs, :arg)
    {value, attrs} = Keyword.pop(attrs, :value)
    {context, attrs} = Keyword.pop(attrs, :context, %{})
    {init_opts, _attrs} = Keyword.pop(attrs, :init_opts, [])

    :post
    |> conn("/mcp", %{
      jsonrpc: "2.0",
      id: id,
      method: "completion/complete",
      params: %{
        ref: %{type: "ref/resource", name: name},
        argument: %{name: arg, value: value},
        context: context
      }
    })
    |> put_req_header("content-type", "application/json")
    |> call(Map.merge(@opts, Map.new(init_opts)))
  end

  def request_tool_list(cursor \\ nil, init_opts \\ []) do
    {id, init_opts} = Keyword.pop(init_opts, :id, 1)

    :post
    |> conn("/mcp", %{jsonrpc: "2.0", id: id, method: "tools/list", params: %{"cursor" => cursor}})
    |> put_req_header("content-type", "application/json")
    |> call(Map.merge(@opts, Map.new(init_opts)))
  end

  def request_prompt(name, args \\ %{}, init_opts \\ []) do
    {id, init_opts} = Keyword.pop(init_opts, :id, 1)

    :post
    |> conn("/mcp", %{
      jsonrpc: "2.0",
      id: id,
      method: "prompts/get",
      params: %{"name" => name, "arguments" => args}
    })
    |> put_req_header("content-type", "application/json")
    |> call(Map.merge(@opts, Map.new(init_opts)))
  end

  def request_prompt_list(cursor \\ nil, init_opts \\ []) do
    {id, init_opts} = Keyword.pop(init_opts, :id, 1)

    :post
    |> conn("/mcp", %{
      jsonrpc: "2.0",
      id: id,
      method: "prompts/list",
      params: %{"cursor" => cursor}
    })
    |> put_req_header("content-type", "application/json")
    |> call(Map.merge(@opts, Map.new(init_opts)))
  end

  def request_resource_list(cursor \\ nil, init_opts \\ []) do
    {id, init_opts} = Keyword.pop(init_opts, :id, 1)

    :post
    |> conn("/mcp", %{
      jsonrpc: "2.0",
      id: id,
      method: "resources/list",
      params: %{"cursor" => cursor}
    })
    |> put_req_header("content-type", "application/json")
    |> call(Map.merge(@opts, Map.new(init_opts)))
  end

  def request_resource_read(uri, init_opts \\ []) do
    {id, init_opts} = Keyword.pop(init_opts, :id, 1)

    :post
    |> conn("/mcp", %{jsonrpc: "2.0", id: id, method: "resources/read", params: %{"uri" => uri}})
    |> put_req_header("content-type", "application/json")
    |> call(Map.merge(@opts, Map.new(init_opts)))
  end

  def request_resource_subscribe(uri, init_opts \\ []) do
    {id, init_opts} = Keyword.pop(init_opts, :id, 1)

    :post
    |> conn("/mcp", %{
      jsonrpc: "2.0",
      id: id,
      method: "resources/subscribe",
      params: %{"uri" => uri}
    })
    |> put_req_header("content-type", "application/json")
    |> call(Map.merge(@opts, Map.new(init_opts)))
  end

  def request_set_log_level(level, init_opts \\ []) do
    {id, init_opts} = Keyword.pop(init_opts, :id, 1)

    :post
    |> conn("/mcp", %{
      jsonrpc: "2.0",
      id: id,
      method: "logging/setLevel",
      params: %{"level" => level}
    })
    |> put_req_header("content-type", "application/json")
    |> call(Map.merge(@opts, Map.new(init_opts)))
  end

  def request_initialize do
    :post
    |> conn("/mcp", %{
      jsonrpc: "2.0",
      id: 1,
      method: "initialize",
      params: %{
        protocolVersion: "2024-11-05",
        capabilities: %{
          roots: %{
            listChanged: true
          },
          sampling: %{},
          elicitation: %{}
        },
        clientInfo: %{
          name: "ExampleClient",
          title: "Example Client Display Name",
          version: "1.0.0"
        }
      }
    })
    |> put_req_header("content-type", "application/json")
    |> call(@opts)
  end

  def request_sse_stream(init_opts \\ []) do
    :get
    |> conn("/mcp")
    |> put_req_header("content-type", "event-stream/sse")
    |> call(Map.merge(@opts, Map.new(init_opts)))
  end
end
