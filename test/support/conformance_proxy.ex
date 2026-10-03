defmodule Phantom.Test.ConformanceProxy do
  @moduledoc """
  Reverse proxy that sends each HTTP request to the next backend in turn.

  Consecutive requests of one MCP session, including the SSE streams they
  open, land on different nodes, so a passing conformance run proves that any
  node can serve any request.
  """

  @behaviour Plug

  import Plug.Conn

  @hop_by_hop ~w[connection content-length host keep-alive transfer-encoding]

  @impl Plug
  def init(opts) do
    backends = opts |> Keyword.fetch!(:backends) |> List.to_tuple()
    %{backends: backends, counter: :atomics.new(1, [])}
  end

  @impl Plug
  def call(conn, %{backends: backends, counter: counter}) do
    index = rem(:atomics.add_get(counter, 1, 1), tuple_size(backends))
    {:ok, body, conn} = read_body(conn)

    resp =
      Req.request!(
        method: conn.method,
        url: elem(backends, index) <> conn.request_path,
        params: URI.decode_query(conn.query_string),
        headers: Enum.reject(conn.req_headers, fn {name, _} -> name in @hop_by_hop end),
        body: body,
        into: :self,
        retry: false,
        redirect: false,
        compressed: false,
        receive_timeout: :infinity
      )

    conn =
      resp.headers
      |> Enum.reject(fn {name, _} -> name in @hop_by_hop end)
      |> Enum.reduce(conn, fn {name, values}, conn ->
        put_resp_header(conn, name, Enum.join(values, ", "))
      end)
      |> send_chunked(resp.status)

    stream(conn, resp)
  end

  defp stream(conn, resp) do
    receive do
      message ->
        case Req.parse_message(resp, message) do
          {:ok, chunks} -> forward(conn, resp, chunks)
          :unknown -> stream(conn, resp)
        end
    end
  end

  defp forward(conn, resp, []), do: stream(conn, resp)

  defp forward(conn, _resp, [:done | _]), do: conn

  defp forward(conn, resp, [{:data, data} | rest]) do
    case chunk(conn, data) do
      {:ok, conn} ->
        forward(conn, resp, rest)

      {:error, _closed} ->
        Req.cancel_async_response(resp)
        conn
    end
  end

  defp forward(conn, resp, [_trailers | rest]), do: forward(conn, resp, rest)
end
