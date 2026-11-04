defmodule Phantom.A2A.ExtensionsTest.Agent do
  use Phantom.A2A.Agent,
    name: "Extensions",
    description: "Uses extensions",
    extensions: [
      %{
        uri: "https://example.com/ext/required/v1",
        description: "Must be understood",
        required: true
      },
      %{uri: "https://example.com/ext/optional/v1", params: %{"level" => 2}}
    ]

  def handle_message(_message, ctx),
    do: {:reply, Phantom.A2A.Message.agent(Enum.join(ctx.extensions, ",")), ctx}
end

defmodule Phantom.A2A.ExtensionsTest.Router do
  use Phantom.Router, name: "Extensions", vsn: "1.0"

  agent "ext", Phantom.A2A.ExtensionsTest.Agent
end

defmodule Phantom.A2A.ExtensionsTest do
  use ExUnit.Case, async: true

  import Phantom.A2A.Test

  alias Phantom.A2A.ExtensionsTest.Router

  @required "https://example.com/ext/required/v1"
  @optional "https://example.com/ext/optional/v1"

  defp send_ext(headers) do
    body = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "SendMessage",
      "params" => %{
        "message" => %{"messageId" => "m1", "role" => "ROLE_USER", "parts" => [%{"text" => "hi"}]}
      }
    }

    conn =
      :post
      |> Plug.Test.conn("/ext", JSON.encode!(body))
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("a2a-version", "1.0")
      |> then(
        &Enum.reduce(headers, &1, fn {k, v}, conn -> Plug.Conn.put_req_header(conn, k, v) end)
      )
      |> Phantom.A2A.Plug.call(Phantom.A2A.Plug.init(router: Router))

    {conn, JSON.decode!(conn.resp_body)}
  end

  test "the card lists the agent's extensions" do
    assert %{
             "capabilities" => %{
               "extensions" => [
                 %{"uri" => @required, "description" => "Must be understood", "required" => true},
                 %{"uri" => @optional, "params" => %{"level" => 2}} = optional
               ]
             }
           } = get_card(Router, "ext")

    refute Map.has_key?(optional, "required")
  end

  test "a request must name the required extensions" do
    {_conn, body} = send_ext([])
    assert %{"error" => %{"code" => -32008, "message" => message}} = body
    assert message =~ @required
  end

  test "the handler sees the requested extensions, and the response names the supported ones" do
    {conn, body} =
      send_ext([{"a2a-extensions", "#{@required}, https://example.com/unknown , #{@optional}"}])

    assert %{"result" => %{"message" => %{"parts" => [%{"text" => text}]}}} = body
    assert text == "#{@required},https://example.com/unknown,#{@optional}"
    assert Plug.Conn.get_resp_header(conn, "a2a-extensions") == ["#{@required}, #{@optional}"]
  end
end
