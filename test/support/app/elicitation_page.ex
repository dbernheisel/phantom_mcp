defmodule Test.ElicitationPage do
  @moduledoc false
  # The page a URL elicitation from `Test.MCP.Router.elicitation_required_tool/2`
  # points at. Submitting it completes the elicitation and tells the session,
  # as an app's sign-in page would.

  import Plug.Conn

  def init(opts), do: opts

  def call(%Plug.Conn{path_info: path} = conn, _opts) do
    elicitation_id = List.last(path)

    case {conn.method, Test.SessionStore.running?() && Test.SessionStore.get(key(elicitation_id))} do
      {_method, unknown} when unknown in [nil, false] ->
        send_html(conn, 404, "<h1>Unknown elicitation</h1>")

      {"GET", elicitation} ->
        send_html(conn, 200, """
        <h1>#{Plug.HTML.html_escape(elicitation.message)}</h1>
        <form method="post"><button type="submit">Complete</button></form>
        """)

      {"POST", _elicitation} ->
        complete(elicitation_id)
        send_html(conn, 200, "<h1>Done</h1><p>Return to your MCP client.</p>")
    end
  end

  @doc """
  Records an elicitation for this page to complete; returns its URL.

  A `session_id` (MCP 2025-11-25) indexes it for the session's retry, which
  is a new call that does not carry the ID, and gets the completion
  notification. A real app would bind it to the signed-in user instead, and
  check that the same user completes it.
  """
  def start(session_id, elicitation_id, message) do
    if Test.SessionStore.running?() do
      elicitation = %{session_id: session_id, message: message, completed: false}
      Test.SessionStore.put(key(elicitation_id), elicitation)

      if session_id,
        do: Test.SessionStore.put({:session_elicitation, session_id}, elicitation_id)
    end

    base_url() <> "/elicitations/" <> elicitation_id
  end

  @doc "Marks the elicitation completed and notifies its session, if any."
  def complete(elicitation_id) do
    with %{} = elicitation <- Test.SessionStore.get(key(elicitation_id)) do
      Test.SessionStore.put(key(elicitation_id), %{elicitation | completed: true})

      if elicitation.session_id do
        notify = Phantom.Request.elicitation_complete(elicitation_id)
        Phantom.Tracker.cast_session(Test.PubSub, elicitation.session_id, {:notify, notify})
      end
    end

    :ok
  end

  @doc "The elicitations the session started that its retry should check."
  def session_elicitations(session_id) do
    with true <- Test.SessionStore.running?(),
         elicitation_id when is_binary(elicitation_id) <-
           Test.SessionStore.get({:session_elicitation, session_id}) do
      [elicitation_id]
    else
      _ -> []
    end
  end

  @doc "Whether every elicitation was completed; forgets them if so."
  def completed?([_ | _] = elicitation_ids) do
    records =
      Enum.map(elicitation_ids, &(Test.SessionStore.running?() && Test.SessionStore.get(key(&1))))

    if Enum.all?(records, &match?(%{completed: true}, &1)) do
      for {elicitation_id, record} <- Enum.zip(elicitation_ids, records) do
        if record.session_id,
          do: Test.SessionStore.delete({:session_elicitation, record.session_id})

        Test.SessionStore.delete(key(elicitation_id))
      end

      true
    else
      false
    end
  end

  def completed?([]), do: false

  defp key(elicitation_id), do: {:elicitation, elicitation_id}

  defp send_html(conn, status, body) do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(status, body)
  end

  # The endpoint only runs on start.exs's primary node; elsewhere, build the
  # URL from its configuration.
  defp base_url do
    Test.Endpoint.url()
  rescue
    _ ->
      config = Application.get_env(:phantom_mcp, Test.Endpoint, [])
      port = get_in(config, [:http, :port])
      "http://#{get_in(config, [:url, :host]) || "localhost"}#{port && ":#{port}"}"
  end
end
