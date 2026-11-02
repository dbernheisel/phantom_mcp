defmodule Phantom.A2A.ClientConformanceTest do
  use ExUnit.Case, async: true

  alias Phantom.A2A.{Card, Client, Error, Message, StatusUpdate}

  defp card(interfaces, capabilities \\ %{"streaming" => true}) do
    %Card{
      name: "Peer",
      description: "A peer",
      supported_interfaces: interfaces,
      capabilities: capabilities
    }
  end

  defp interface(binding, url \\ "http://peer.test/a", extra \\ %{}) do
    Map.merge(
      %{"url" => url, "protocolBinding" => binding, "protocolVersion" => "1.0"},
      extra
    )
  end

  defp client(interfaces, plug, opts \\ []) do
    {:ok, client} = Client.new(card(interfaces), [req_options: [plug: plug]] ++ opts)
    client
  end

  # Tells the test about each request and answers with `body`.
  defp capture(test, status \\ 200, content_type \\ "application/json", body) do
    fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test, {:request, conn.method, conn.request_path, raw})

      conn
      |> Plug.Conn.put_resp_content_type(content_type, nil)
      |> Plug.Conn.send_resp(status, body)
    end
  end

  @empty_result ~s({"jsonrpc":"2.0","id":1,"result":{"message":{"messageId":"m","role":"ROLE_AGENT","parts":[{"text":"ok"}]}}})

  describe "choosing an interface" do
    test "prefers the card's earlier entries" do
      interfaces = [interface("HTTP+JSON"), interface("JSONRPC")]

      assert {:ok, %Client{binding: :http_json}} =
               Client.new(card(interfaces), bindings: [:jsonrpc, :http_json])
    end

    test "skips entries it can't use" do
      interfaces = [interface("GRPC"), interface("JSONRPC")]
      assert {:ok, %Client{binding: :jsonrpc}} = Client.new(card(interfaces))
    end

    test "ignores malformed entries" do
      interfaces = ["x", %{"url" => 1, "protocolBinding" => "JSONRPC"}, interface("HTTP+JSON")]
      assert {:ok, %Client{binding: :http_json}} = Client.new(card(interfaces))

      assert {:error, :no_supported_interface} =
               Client.new(
                 card([interface("JSONRPC", "http://x.test", %{"protocolVersion" => 1})])
               )
    end
  end

  describe "the interface's tenant" do
    test "is in every JSON-RPC request" do
      plug = capture(self(), @empty_result)
      interface = interface("JSONRPC", "http://peer.test/a", %{"tenant" => "acme"})

      assert {:ok, %Message{}} = Client.send_message(client([interface], plug), "hi")

      assert_received {:request, "POST", "/a", raw}
      assert %{"params" => %{"tenant" => "acme"}} = JSON.decode!(raw)
    end

    test "is in every HTTP+JSON path" do
      plug =
        capture(self(), ~s({"id":"t1","contextId":"c","status":{"state":"TASK_STATE_WORKING"}}))

      interface = interface("HTTP+JSON", "http://peer.test/a", %{"tenant" => "acme corp"})

      assert {:ok, _task} = Client.get_task(client([interface], plug), "t1")
      assert_received {:request, "GET", "/a/acme%20corp/tasks/t1", _raw}
    end

    test "is omitted when the interface has none" do
      plug = capture(self(), @empty_result)

      assert {:ok, _} = Client.send_message(client([interface("JSONRPC")], plug), "hi")

      assert_received {:request, "POST", "/a", raw}
      refute Map.has_key?(JSON.decode!(raw)["params"], "tenant")
    end
  end

  describe "credentials" do
    defp card_plug(interface_url) do
      card = card([interface("JSONRPC", interface_url)]) |> Card.to_json() |> JSON.encode!()
      capture(self(), card)
    end

    test "aren't sent to another origin the fetched card names" do
      assert {:error, {:cross_origin_interface, "https://evil.test/a"}} =
               Client.new("https://peer.test/card.json",
                 headers: [{"authorization", "Bearer secret"}],
                 req_options: [plug: card_plug("https://evil.test/a")]
               )
    end

    test "a downgrade to http counts as another origin" do
      assert {:error, {:cross_origin_interface, _url}} =
               Client.new("https://peer.test/card.json",
                 headers: [{"authorization", "Bearer secret"}],
                 req_options: [plug: card_plug("http://peer.test/a")]
               )
    end

    test "may go to another origin when allowed" do
      assert {:ok, %Client{url: "https://api.test/a"}} =
               Client.new("https://peer.test/card.json",
                 headers: [{"authorization", "Bearer secret"}],
                 cross_origin_headers: true,
                 req_options: [plug: card_plug("https://api.test/a")]
               )
    end

    test "the same origin needs nothing, nor does sending no headers" do
      assert {:ok, _} =
               Client.new("https://peer.test/card.json",
                 headers: [{"authorization", "Bearer secret"}],
                 req_options: [plug: card_plug("https://peer.test/a")]
               )

      assert {:ok, _} =
               Client.new("https://peer.test/card.json",
                 req_options: [plug: card_plug("https://other.test/a")]
               )
    end
  end

  describe "subscribing over HTTP+JSON" do
    @event "data: {\"task\":{\"id\":\"t1\",\"contextId\":\"c\",\"status\":{\"state\":\"TASK_STATE_COMPLETED\"}}}\n\n"

    test "uses POST" do
      plug = capture(self(), 200, "text/event-stream", @event)

      assert {:ok, stream} = Client.subscribe(client([interface("HTTP+JSON")], plug), "t1")
      assert [%Phantom.A2A.Task{id: "t1"}] = Enum.to_list(stream)
      assert_received {:request, "POST", "/a/tasks/t1:subscribe", _raw}
    end

    test "falls back to GET for a server that only routes the proto's verb" do
      test = self()

      plug = fn
        %{method: "POST"} = conn ->
          send(test, :post)
          Plug.Conn.send_resp(conn, 405, "")

        conn ->
          send(test, :get)

          conn
          |> Plug.Conn.put_resp_content_type("text/event-stream", nil)
          |> Plug.Conn.send_resp(200, @event)
      end

      assert {:ok, stream} = Client.subscribe(client([interface("HTTP+JSON")], plug), "t1")
      assert [%Phantom.A2A.Task{id: "t1"}] = Enum.to_list(stream)
      assert_received :post
      assert_received :get
    end
  end

  describe "reading a stream" do
    defp stream_of(body) do
      plug = capture(self(), 200, "text/event-stream", body)
      {:ok, stream} = Client.stream_message(client([interface("JSONRPC")], plug), "hi")
      stream
    end

    @status ~s({"jsonrpc":"2.0","id":1,"result":{"statusUpdate":{"taskId":"t","contextId":"c","status":{"state":"TASK_STATE_WORKING"}}}})

    test "accepts CRLF line endings" do
      body = "event: x\r\ndata: #{@status}\r\n\r\ndata: #{@status}\r\n\r\n"

      assert [%StatusUpdate{}, %StatusUpdate{}] = Enum.to_list(stream_of(body))
    end

    test "accepts CR line endings" do
      assert [%StatusUpdate{}] = Enum.to_list(stream_of("data: #{@status}\r\r"))
    end

    test "ends at an error" do
      error = ~s({"jsonrpc":"2.0","id":1,"error":{"code":-32603,"message":"Internal error"}})

      assert [%StatusUpdate{}, %Error{code: -32603}] =
               Enum.to_list(
                 stream_of("data: #{@status}\n\ndata: #{error}\n\ndata: #{@status}\n\n")
               )
    end

    test "a malformed error ends it too" do
      assert [%Error{code: -32006}] = Enum.to_list(stream_of(~s(data: {"error":"x"}\n\n)))
    end

    test "stopping early leaves nothing in the caller's mailbox" do
      test = self()

      plug = fn conn ->
        conn =
          conn
          |> Plug.Conn.put_resp_content_type("text/event-stream", nil)
          |> Plug.Conn.send_chunked(200)

        {:ok, conn} = Plug.Conn.chunk(conn, "data: #{@status}\n\ndata: #{@status}\n\n")
        send(test, :chunked)
        {:ok, conn} = Plug.Conn.chunk(conn, "data: #{@status}\n\n")
        conn
      end

      {:ok, stream} = Client.stream_message(client([interface("JSONRPC")], plug), "hi")
      assert_receive :chunked

      assert [%StatusUpdate{}] = Enum.take(stream, 1)

      {:messages, messages} = Process.info(self(), :messages)
      assert Enum.filter(messages, &match?({_ref, :data, _, _, _}, &1)) == []
    end
  end

  describe "a malformed response" do
    test "a non-object result is an invalid agent response" do
      plug = capture(self(), ~s({"jsonrpc":"2.0","id":1,"result":[1]}))

      assert {:error, %Error{code: -32006}} =
               Client.list_tasks(client([interface("JSONRPC")], plug))
    end

    test "a malformed error is an invalid agent response" do
      plug = capture(self(), ~s({"jsonrpc":"2.0","id":1,"error":"x"}))

      assert {:error, %Error{code: -32006}} =
               Client.send_message(client([interface("JSONRPC")], plug), "hi")
    end
  end
end
