defmodule Phantom.ResourcePlug do
  @moduledoc false

  @behaviour Plug
  import Plug.Conn
  import Phantom.Utils

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(fake_conn, _opts) do
    result =
      wrap_result(
        apply(
          fake_conn.private.phantom_resource.handler,
          fake_conn.private.phantom_resource.function,
          [
            fake_conn.path_params,
            fake_conn.private.phantom_request,
            fake_conn.private.phantom_session
          ]
        ),
        fake_conn
      )

    assign(fake_conn, :result, result)
  end

  defp wrap_result({:noreply, _session} = resp, _fake_conn), do: resp

  defp wrap_result({:reply, results, session}, fake_conn) do
    {:reply,
     %{
       contents:
         results
         |> List.wrap()
         |> Enum.map(fn result ->
           remove_nils(
             maybe_encode(%{
               blob: result[:blob],
               text: result[:text],
               mimeType: result[:mime_type] || fake_conn.private.phantom_resource.mime_type,
               uri: fake_conn.private.phantom_uri
             })
           )
         end)
     }, session}
  end

  defp maybe_encode(%{text: data, mimeType: "application/json"} = result) do
    put_in(result[:text], JSON.encode!(data))
  end

  defp maybe_encode(result), do: result
end
