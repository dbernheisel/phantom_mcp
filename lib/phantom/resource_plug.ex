defmodule Phantom.ResourcePlug do
  @moduledoc false

  @behaviour Plug
  import Plug.Conn

  alias Phantom.Request
  alias Phantom.Resource
  alias Phantom.Session

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(fake_conn, _opts) do
    result =
      try do
        apply(
          fake_conn.assigns.resource_template.handler,
          fake_conn.assigns.resource_template.function,
          [fake_conn.path_params, fake_conn.assigns.session]
        )
      rescue
        _e in FunctionClauseError ->
          {:error, Phantom.Request.resource_not_found(%{uri: fake_conn.assigns.uri}),
           fake_conn.assigns.session}
      end

    assign(
      fake_conn,
      :result,
      wrap(result, fake_conn.assigns.uri, fake_conn.assigns.session)
    )
  end

  defp wrap({:error, reason}, _uri, session) do
    {:error, reason, session}
  end

  defp wrap({:error, _reason, %Session{}} = result, _uri, _session), do: result

  defp wrap(nil, uri, session) do
    {:error, Request.resource_not_found(%{uri: uri}), session}
  end

  defp wrap({:noreply, %Session{}} = result, _uri, _session), do: result

  defp wrap({:reply, nil, %Session{} = session}, uri, _session) do
    {:error, Request.resource_not_found(%{uri: uri}), session}
  end

  defp wrap({:reply, results, %Session{} = session}, _uri, _session) do
    {:reply, Resource.response(results), session}
  end

  defmodule NotFound do
    @behaviour Plug
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      result = Phantom.Request.resource_not_found(%{uri: conn.assigns.uri})
      assign(conn, :result, {:reply, result, conn.assigns.session})
    end
  end
end
