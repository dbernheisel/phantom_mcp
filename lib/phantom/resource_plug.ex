defmodule Phantom.ResourcePlug do
  @moduledoc false

  @behaviour Plug
  import Plug.Conn

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(fake_conn, _opts) do
    result =
      apply(
        fake_conn.assigns.resource.handler,
        fake_conn.assigns.resource.function,
        [
          fake_conn.path_params,
          fake_conn.assigns.request,
          fake_conn.assigns.session
        ]
      )

    assign(fake_conn, :result, result)
  end
end
