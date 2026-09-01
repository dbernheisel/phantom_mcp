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
    session = %{
      fake_conn.assigns.session
      | request: %{fake_conn.assigns.session.request | spec: fake_conn.assigns.resource_template}
    }

    handler = fake_conn.assigns.resource_template.handler
    function = fake_conn.assigns.resource_template.function

    path_params = Map.merge(fake_conn.path_params, input_response_args(session.request))

    args =
      if function_exported?(handler, function, 3) do
        [path_params, session, fake_conn]
      else
        [path_params, session]
      end

    result =
      try do
        apply(handler, function, args)
      rescue
        _e in FunctionClauseError ->
          {:error,
           Phantom.Request.resource_not_found(
             %{uri: fake_conn.assigns.uri},
             fake_conn.assigns.session
           ), fake_conn.assigns.session}
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
    {:error, Request.resource_not_found(%{uri: uri}, session), session}
  end

  defp wrap(
         {:noreply, %Session{pending_elicit: {elicit, state}} = session},
         _uri,
         _original_session
       ) do
    if Session.stateless?(session) and Session.elicitation_supported?(session, elicit) do
      result =
        elicit
        |> Phantom.Tool.input_required(state)
        |> Phantom.Router.encode_request_state(session)

      {:reply, result, %{session | pending_elicit: nil}}
    else
      {:error, Request.missing_capability(["elicitation"]), session}
    end
  end

  defp wrap({:noreply, %Session{}} = result, _uri, _session), do: result

  defp wrap({:reply, %{resultType: type} = result, %Session{} = session}, _uri, _session)
       when type in ["input_required", "inputRequired"],
       do: {:reply, Phantom.Router.encode_request_state(result, session), session}

  defp wrap({:reply, nil, %Session{} = session}, uri, _session) do
    {:error, Request.resource_not_found(%{uri: uri}, session), session}
  end

  defp wrap({:reply, %{code: code, message: _} = error, %Session{} = session}, _uri, _session)
       when is_integer(code) and code < 0 do
    {:error, error, session}
  end

  defp wrap({:reply, results, %Session{} = session}, _uri, _session) do
    {:reply, Resource.response(results), session}
  end

  defp input_response_args(%{params: %{"inputResponses" => responses}})
       when is_map(responses) do
    case responses["elicitation"] do
      %{"content" => content} when is_map(content) -> content
      response when is_map(response) -> response
      _ -> %{}
    end
  end

  defp input_response_args(_request), do: %{}

  defmodule NotFound do
    @moduledoc false

    @behaviour Plug
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      session = conn.assigns.session
      result = Phantom.Request.resource_not_found(%{uri: conn.assigns.uri}, session)
      assign(conn, :result, {:error, result, session})
    end
  end
end
