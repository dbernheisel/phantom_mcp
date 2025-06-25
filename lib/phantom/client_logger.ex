defmodule Phantom.ClientLogger do
  @moduledoc """
  Notify the client of logs.
  """

  alias Phantom.Session

  @type log_level ::
          :emergency | :alert | :critical | :error | :warning | :notice | :info | :debug

  @log_grades [
    emergency: 1,
    alert: 2,
    critical: 3,
    error: 4,
    warning: 5,
    notice: 6,
    info: 7,
    debug: 8
  ]
  @log_levels Keyword.keys(@log_grades)

  @doc false
  def log_levels, do: @log_grades

  @doc false
  def do_log(%Session{pubsub: nil}, _level_num, _name, _domain, _payload), do: :ok

  def do_log(%Session{pid: pid, id: id}, level_num, level_name, domain, payload) do
    payload = if is_binary(payload), do: %{message: payload}, else: payload
    pid = Phantom.Tracker.get_session(id) || pid
    GenServer.cast(pid, {:log, level_num, level_name, domain, payload})
  end

  @doc "Notify the client for the provided session and domain at level with a payload"
  def log(%Session{} = session, level_name, payload, domain)
      when level_name in @log_levels do
    do_log(session, Keyword.fetch!(log_levels(), level_name), level_name, domain, payload)
  end

  @doc """
  Notify the client at the provided level for domain with the payload.

  Note: this requires the `session` to be within scope.
  """
  defmacro log(log_level, payload, domain) when log_level in @log_levels do
    if not Macro.Env.has_var?(__CALLER__, {:session, nil}) do
      raise """
      session was not supplied to `log`. To send a log, either
      use log/3 or log/4 and supply the session, or have the session available
      in the scope
      """
    end

    quote bind_quoted: [log_level: log_level, domain: domain, payload: payload],
          generated: true do
      Phantom.ClientLogger.do_log(
        var!(session),
        Map.fetch!(log_levels(), log_name),
        log_level,
        domain,
        payload
      )
    end
  end

  @doc """
  Notify the client with a log at the provided level with the provided domain.

  The log contents may be structured (eg, a map) or not. If not, it will be
  wrapped into one: `%{message: your_string}`.

  Note: this requires the `session` variable to be within scope
  """
  defmacro log(log_level, payload) when log_level in @log_levels do
    quote do
      Phantom.ClientLogger.do_log(
        var!(session),
        Map.fetch!(log_levels(), unquote(log_level)),
        log_level,
        "server",
        unquote(payload)
      )
    end
  end

  for {name, level} <- @log_grades do
    @doc "Notify the client with a log at level \"#{name}\""
    @spec unquote(name)(Session.t(), structured_log :: map(), domain :: String.t()) ::
            :ok
    def unquote(name)(%Session{} = session, payload, domain) do
      quote bind_quoted: [
              level: unquote(level),
              name: unquote(name),
              domain: domain,
              session: session,
              payload: payload
            ],
            generated: true do
        Phantom.ClientLogger.do_log(session, level, name, domain, payload)
      end
    end

    @doc """
    Notify the client with a log at level \"#{name}\" with default domain "server".
    Note: this requires the `session` variable to be within scope
    """
    @spec unquote(name)(structured_log :: map(), domain :: String.t()) :: :ok
    defmacro unquote(name)(payload, domain \\ "server") do
      if not Macro.Env.has_var?(__CALLER__, {:session, nil}) do
        raise """
        session was not supplied to `log_#{unquote(name)}`. To send a log, either
        use log_#{unquote(name)}/4 and supply the session, or have the session available
        in the scope
        """
      end

      quote bind_quoted: [
              level: unquote(level),
              name: unquote(name),
              domain: domain,
              payload: payload
            ],
            generated: true do
        Phantom.ClientLogger.do_log(var!(session), level, name, domain, payload)
      end
    end
  end
end
