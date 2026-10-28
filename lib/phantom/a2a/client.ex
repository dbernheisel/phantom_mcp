defmodule Phantom.A2A.Client do
  @moduledoc """
  Call A2A agents: fetch an agent's card, send messages, follow tasks, and
  manage push notifications, over the JSON-RPC or HTTP+JSON binding.

  Requires the optional `{:req, "~> 0.5"}` dependency.

      {:ok, client} = Phantom.A2A.Client.new("https://agents.example", headers: [{"authorization", "Bearer " <> token}])

      {:ok, %Phantom.A2A.Message{} = reply} = Phantom.A2A.Client.send_message(client, "Hello")

      {:ok, stream} = Phantom.A2A.Client.stream_message(client, "Review study 42")
      for event <- stream, do: IO.inspect(event)

  Results are the structs Phantom serves agents with: `Phantom.A2A.Message`,
  `Phantom.A2A.Task`, `Phantom.A2A.StatusUpdate`, `Phantom.A2A.ArtifactUpdate`,
  `Phantom.A2A.PushConfig`, and `Phantom.A2A.Card`. Errors the agent returns
  are `{:error, %Phantom.A2A.Error{}}`.

  The client checks the card before optional operations: it refuses to stream
  when the card doesn't advertise streaming, and likewise push notifications
  and extended cards, without asking the agent.

  ## Options

    * `:bindings` - the bindings to use, most preferred first (default
      `[:jsonrpc, :http_json]`). The client takes the first one the card lists.
    * `:headers` - headers for every request, such as `authorization`
    * `:extensions` - extension URIs to request in the `A2A-Extensions` header
    * `:req_options` - options for `Req.new/1`, such as `:receive_timeout`, or
      `plug:` to call a Plug instead of the network
  """

  @compile {:no_warn_undefined, Req}

  alias Phantom.A2A.{Card, Error, Message, PushConfig, Task, TaskStatus}

  defstruct [:url, :binding, :card, headers: [], extensions: [], req_options: []]

  @type t :: %__MODULE__{
          url: String.t(),
          binding: :jsonrpc | :http_json,
          card: Card.t(),
          headers: [{String.t(), String.t()}],
          extensions: [String.t()],
          req_options: keyword()
        }

  @bindings %{"JSONRPC" => :jsonrpc, "HTTP+JSON" => :http_json}

  @doc """
  Fetch an agent card. Give the card's URL, or an origin to read
  `/.well-known/agent-card.json` from. Takes the `:headers` and
  `:req_options` options.
  """
  @spec get_card(String.t(), keyword()) :: {:ok, Card.t()} | {:error, term()}
  def get_card(url, opts \\ []) do
    url =
      if String.ends_with?(url, ".json"),
        do: url,
        else: String.trim_trailing(url, "/") <> "/.well-known/agent-card.json"

    with {:ok, %{status: 200, body: body}} <- http(:get, url, nil, opts),
         {:ok, json} <- JSON.decode(body) do
      Card.from_json(json)
    else
      {:ok, %{status: status, body: body}} -> {:error, error_from_body(body, status)}
      error -> error
    end
  end

  @doc """
  A client for an agent, from its card or a URL to fetch the card from. See the
  moduledoc for options.
  """
  @spec new(Card.t() | String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def new(card_or_url, opts \\ [])

  def new(%Card{} = card, opts) do
    preferred = Keyword.get(opts, :bindings, [:jsonrpc, :http_json])

    interfaces =
      for %{"url" => url, "protocolBinding" => name} = interface <- card.supported_interfaces,
          binding = @bindings[name],
          binding in preferred,
          String.starts_with?(interface["protocolVersion"] || "1.", "1."),
          do: {binding, url}

    case Enum.find_value(preferred, &List.keyfind(interfaces, &1, 0)) do
      {binding, url} ->
        {:ok,
         %__MODULE__{
           url: url,
           binding: binding,
           card: card,
           headers: Keyword.get(opts, :headers, []),
           extensions: Keyword.get(opts, :extensions, []),
           req_options: Keyword.get(opts, :req_options, [])
         }}

      nil ->
        {:error, :no_supported_interface}
    end
  end

  def new(url, opts) when is_binary(url) do
    with {:ok, card} <- get_card(url, opts), do: new(card, opts)
  end

  @doc """
  Send a message, given as text or a `Phantom.A2A.Message`. Returns the agent's
  `Phantom.A2A.Message` or `Phantom.A2A.Task`.

  ## Options

    * `:return_immediately` - answer with the task before it finishes
    * `:history_length` - how much of the task's history to return
    * `:accepted_output_modes` - the media types the client accepts
    * `:push_config` - a `Phantom.A2A.PushConfig` to register for the task
    * `:metadata` - the request's metadata
  """
  @spec send_message(t(), String.t() | Message.t(), keyword()) ::
          {:ok, Message.t() | Task.t()} | {:error, term()}
  def send_message(client, message, opts \\ []) do
    with {:ok, result} <- request(client, "SendMessage", message_params(message, opts)) do
      Phantom.A2A.event_from_json(result)
    end
  end

  @doc """
  Send a message and stream the agent's answer: a `Phantom.A2A.Message`, or
  the task and then each event, until it finishes or needs input. Returns
  `{:ok, stream}` once the agent starts answering. A `Phantom.A2A.Error` in the
  stream ends it. Consume the stream in the process that called this. Takes
  the options of `send_message/3`.
  """
  @spec stream_message(t(), String.t() | Message.t(), keyword()) ::
          {:ok, Enumerable.t()} | {:error, term()}
  def stream_message(client, message, opts \\ []) do
    with :ok <-
           require_capability(
             client,
             "streaming",
             Error.unsupported_operation("The agent doesn't stream")
           ),
         do: stream(client, "SendStreamingMessage", message_params(message, opts))
  end

  @doc "Fetch a task. Takes `:history_length`."
  @spec get_task(t(), String.t(), keyword()) :: {:ok, Task.t()} | {:error, term()}
  def get_task(client, task_id, opts \\ []) do
    params = compact(%{"id" => task_id, "historyLength" => opts[:history_length]})
    with {:ok, json} <- request(client, "GetTask", params), do: Task.from_json(json)
  end

  @doc """
  List tasks. Returns a page: `%{tasks: tasks, next_page_token: token | nil,
  page_size: size, total_size: size}`.

  ## Options

    * `:context_id`, `:status` (such as `:working`), `:page_size`,
      `:page_token`, `:history_length`, `:include_artifacts`, and
      `:status_timestamp_after` (a `DateTime`)
  """
  @spec list_tasks(t(), keyword()) :: {:ok, map()} | {:error, term()}
  def list_tasks(client, opts \\ []) do
    params =
      compact(%{
        "contextId" => opts[:context_id],
        "status" =>
          opts[:status] && TaskStatus.to_json(%TaskStatus{state: opts[:status]})["state"],
        "pageSize" => opts[:page_size],
        "pageToken" => opts[:page_token],
        "historyLength" => opts[:history_length],
        "includeArtifacts" => opts[:include_artifacts],
        "statusTimestampAfter" =>
          opts[:status_timestamp_after] && DateTime.to_iso8601(opts[:status_timestamp_after])
      })

    with {:ok, json} <- request(client, "ListTasks", params),
         {:ok, tasks} <- Phantom.A2A.Part.list_from_json(json["tasks"] || [], &Task.from_json/1) do
      {:ok,
       %{
         tasks: tasks,
         next_page_token:
           if(json["nextPageToken"] in [nil, ""], do: nil, else: json["nextPageToken"]),
         page_size: json["pageSize"],
         total_size: json["totalSize"]
       }}
    end
  end

  @doc "Cancel a task"
  @spec cancel_task(t(), String.t()) :: {:ok, Task.t()} | {:error, term()}
  def cancel_task(client, task_id) do
    with {:ok, json} <- request(client, "CancelTask", %{"id" => task_id}),
         do: Task.from_json(json)
  end

  @doc """
  Stream a task: its current state, then each event, until it finishes or
  needs input. See `stream_message/3`.
  """
  @spec subscribe(t(), String.t()) :: {:ok, Enumerable.t()} | {:error, term()}
  def subscribe(client, task_id) do
    with :ok <-
           require_capability(
             client,
             "streaming",
             Error.unsupported_operation("The agent doesn't stream")
           ),
         do: stream(client, "SubscribeToTask", %{"id" => task_id})
  end

  @doc "Register a webhook for a task's updates"
  @spec create_push_config(t(), PushConfig.t()) :: {:ok, PushConfig.t()} | {:error, term()}
  def create_push_config(client, %PushConfig{} = config) do
    with :ok <- require_push(client),
         {:ok, json} <-
           request(client, "CreateTaskPushNotificationConfig", PushConfig.to_json(config)),
         do: PushConfig.from_json(json)
  end

  @doc "Fetch a task's push notification config"
  @spec get_push_config(t(), String.t(), String.t()) :: {:ok, PushConfig.t()} | {:error, term()}
  def get_push_config(client, task_id, id) do
    with :ok <- require_push(client),
         {:ok, json} <-
           request(client, "GetTaskPushNotificationConfig", %{"taskId" => task_id, "id" => id}),
         do: PushConfig.from_json(json)
  end

  @doc "List a task's push notification configs"
  @spec list_push_configs(t(), String.t()) :: {:ok, [PushConfig.t()]} | {:error, term()}
  def list_push_configs(client, task_id) do
    with :ok <- require_push(client),
         {:ok, json} <- request(client, "ListTaskPushNotificationConfigs", %{"taskId" => task_id}),
         do: Phantom.A2A.Part.list_from_json(json["configs"] || [], &PushConfig.from_json/1)
  end

  @doc "Delete a task's push notification config"
  @spec delete_push_config(t(), String.t(), String.t()) :: :ok | {:error, term()}
  def delete_push_config(client, task_id, id) do
    with :ok <- require_push(client),
         {:ok, _result} <-
           request(client, "DeleteTaskPushNotificationConfig", %{"taskId" => task_id, "id" => id}),
         do: :ok
  end

  @doc "Fetch the extended card the agent shows this client"
  @spec get_extended_card(t()) :: {:ok, Card.t()} | {:error, term()}
  def get_extended_card(client) do
    with :ok <-
           require_capability(
             client,
             "extendedAgentCard",
             Error.unsupported_operation("The agent has no extended card")
           ),
         {:ok, json} <- request(client, "GetExtendedAgentCard", %{}),
         do: Card.from_json(json)
  end

  defp message_params(text, opts) when is_binary(text),
    do: message_params(Message.user(text), opts)

  defp message_params(%Message{} = message, opts) do
    configuration =
      compact(%{
        "returnImmediately" => opts[:return_immediately],
        "historyLength" => opts[:history_length],
        "acceptedOutputModes" => opts[:accepted_output_modes],
        "taskPushNotificationConfig" =>
          opts[:push_config] && PushConfig.to_json(opts[:push_config])
      })

    compact(%{
      "message" => Message.to_json(message),
      "configuration" => if(configuration != %{}, do: configuration),
      "metadata" => opts[:metadata]
    })
  end

  defp compact(map), do: for({key, value} <- map, not is_nil(value), into: %{}, do: {key, value})

  defp require_push(client),
    do: require_capability(client, "pushNotifications", Error.push_notification_not_supported())

  defp require_capability(%__MODULE__{card: card}, capability, error) do
    if card.capabilities[capability] == true, do: :ok, else: {:error, error}
  end

  ## Transport

  defp request(client, method, params) do
    {verb, url, body, query} = http_request(client, method, params)

    case http(verb, url, body,
           query: query,
           headers: headers(client),
           req_options: client.req_options
         ) do
      {:ok, %{status: status, body: body}} -> decode(client, status, body)
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode(%{binding: :jsonrpc}, _status, body) do
    case JSON.decode(body) do
      {:ok, %{"result" => result}} -> {:ok, result}
      {:ok, %{"error" => error}} -> {:error, Error.from_json(error)}
      _invalid -> {:error, Error.invalid_agent_response()}
    end
  end

  defp decode(%{binding: :http_json}, status, "") when status in 200..299, do: {:ok, nil}

  defp decode(%{binding: :http_json}, status, body) when status in 200..299 do
    case JSON.decode(body) do
      {:ok, json} -> {:ok, json}
      _invalid -> {:error, Error.invalid_agent_response()}
    end
  end

  defp decode(%{binding: :http_json}, status, body), do: {:error, error_from_body(body, status)}

  defp error_from_body(body, status) do
    case JSON.decode(body) do
      {:ok, %{"error" => %{} = error}} -> Error.from_json(error)
      _other -> {:http_status, status}
    end
  end

  defp http_request(%{binding: :jsonrpc, url: url}, method, params) do
    {:post, url,
     %{"jsonrpc" => "2.0", "id" => UUIDv7.generate(), "method" => method, "params" => params}, []}
  end

  defp http_request(%{binding: :http_json, url: url}, method, params) do
    {verb, path, body, query} = rest(method, params)
    {verb, url <> path, body, query}
  end

  # The HTTP+JSON routes from the A2A protobuf.
  defp rest("SendMessage", params), do: {:post, "/message:send", params, []}
  defp rest("SendStreamingMessage", params), do: {:post, "/message:stream", params, []}

  defp rest("GetTask", %{"id" => id} = p),
    do: {:get, "/tasks/#{segment(id)}", nil, query(p, ["historyLength"])}

  defp rest("ListTasks", params), do: {:get, "/tasks", nil, Map.to_list(params)}
  defp rest("CancelTask", %{"id" => id}), do: {:post, "/tasks/#{segment(id)}:cancel", %{}, []}

  defp rest("SubscribeToTask", %{"id" => id}),
    do: {:get, "/tasks/#{segment(id)}:subscribe", nil, []}

  defp rest("GetExtendedAgentCard", _params), do: {:get, "/extendedAgentCard", nil, []}

  defp rest("CreateTaskPushNotificationConfig", %{"taskId" => task_id} = config),
    do: {:post, "/tasks/#{segment(task_id)}/pushNotificationConfigs", config, []}

  defp rest("GetTaskPushNotificationConfig", %{"taskId" => task_id, "id" => id}),
    do: {:get, "/tasks/#{segment(task_id)}/pushNotificationConfigs/#{segment(id)}", nil, []}

  defp rest("ListTaskPushNotificationConfigs", %{"taskId" => task_id}),
    do: {:get, "/tasks/#{segment(task_id)}/pushNotificationConfigs", nil, []}

  defp rest("DeleteTaskPushNotificationConfig", %{"taskId" => task_id, "id" => id}),
    do: {:delete, "/tasks/#{segment(task_id)}/pushNotificationConfigs/#{segment(id)}", nil, []}

  defp segment(value), do: URI.encode(value, &URI.char_unreserved?/1)
  defp query(params, keys), do: params |> Map.take(keys) |> Map.to_list()

  defp headers(client) do
    extensions =
      if client.extensions == [],
        do: [],
        else: [{"a2a-extensions", Enum.join(client.extensions, ", ")}]

    extensions ++ client.headers
  end

  defp http(method, url, body, opts) do
    if not Code.ensure_loaded?(Req) do
      raise "Phantom.A2A.Client requires the :req dependency: {:req, \"~> 0.5\"}"
    end

    headers =
      [
        {"a2a-version", "1.0"},
        {"accept", "application/json, application/a2a+json, text/event-stream"}
      ] ++
        if(body, do: [{"content-type", "application/json"}], else: []) ++
        Keyword.get(opts, :headers, [])

    [
      method: method,
      url: url,
      headers: headers,
      params: opts[:query] || [],
      decode_body: false,
      retry: false
    ]
    |> Keyword.merge(if(body, do: [body: JSON.encode!(body)], else: []))
    |> Keyword.merge(Keyword.get(opts, :req_options, []))
    |> Keyword.merge(Keyword.take(opts, [:into]))
    |> Req.request()
  end

  ## Streaming

  # The request runs in a task that sends each chunk to the caller, so the
  # stream is lazy and works with Req's `plug:` adapter too.
  defp stream(client, method, params) do
    {verb, url, body, query} = http_request(client, method, params)
    parent = self()
    ref = make_ref()

    into = fn {:data, data}, {request, response} ->
      send(parent, {ref, :data, response.status, response.headers, data})
      {:cont, {request, response}}
    end

    task =
      Elixir.Task.async(fn ->
        http(verb, url, body,
          query: query,
          headers: headers(client),
          req_options: client.req_options,
          into: into
        )
      end)

    case await_chunk(ref, task) do
      {:data, 200, headers, data} ->
        if event_stream?(headers) do
          {:ok, events(client, ref, task, data)}
        else
          finish_error(client, ref, task, 200, data)
        end

      {:data, status, _headers, data} ->
        finish_error(client, ref, task, status, data)

      {:done, {:ok, %{status: status, body: body}}} ->
        decode_stream_error(client, status, body)

      {:done, {:error, reason}} ->
        {:error, reason}
    end
  end

  defp await_chunk(ref, %Elixir.Task{ref: task_ref}) do
    receive do
      {^ref, :data, status, headers, data} ->
        {:data, status, headers, data}

      {^task_ref, result} ->
        Process.demonitor(task_ref, [:flush])
        {:done, result}
    end
  end

  defp event_stream?(headers) do
    Enum.any?(Map.get(headers, "content-type", []), &String.starts_with?(&1, "text/event-stream"))
  end

  defp finish_error(client, ref, task, status, data) do
    body = collect_body(ref, task, data)
    decode_stream_error(client, status, body)
  end

  defp collect_body(ref, task, acc) do
    case await_chunk(ref, task) do
      {:data, _status, _headers, data} -> collect_body(ref, task, acc <> data)
      {:done, _result} -> acc
    end
  end

  defp decode_stream_error(client, status, body) do
    case decode(client, status, body) do
      {:error, error} -> {:error, error}
      {:ok, _result} -> {:error, Error.invalid_agent_response()}
    end
  end

  defp events(client, ref, task, first) do
    Stream.resource(
      fn -> {first, false} end,
      fn
        :halt ->
          {:halt, :halt}

        {buffer, done?} ->
          case String.split(buffer, "\n\n", parts: 2) do
            [event, rest] ->
              {List.wrap(parse_event(client, event)), {rest, done?}}

            [_incomplete] when done? ->
              {List.wrap(parse_event(client, buffer)), :halt}

            [_incomplete] ->
              case await_chunk(ref, task) do
                {:data, _status, _headers, data} -> {[], {buffer <> data, false}}
                {:done, _result} -> {[], {buffer, true}}
              end
          end
      end,
      fn _acc -> Elixir.Task.shutdown(task, :brutal_kill) end
    )
  end

  defp parse_event(client, event) do
    data =
      for line <- String.split(event, "\n"),
          String.starts_with?(line, "data:"),
          do: line |> String.trim_leading("data:") |> String.trim_leading()

    case data do
      [] -> []
      lines -> decode_event(client, Enum.join(lines, "\n"))
    end
  end

  defp decode_event(%{binding: :jsonrpc}, data) do
    case JSON.decode(data) do
      {:ok, %{"result" => result}} -> event_or_error(result)
      {:ok, %{"error" => error}} -> Error.from_json(error)
      _invalid -> Error.invalid_agent_response()
    end
  end

  defp decode_event(%{binding: :http_json}, data) do
    case JSON.decode(data) do
      {:ok, %{"error" => %{} = error}} -> Error.from_json(error)
      {:ok, json} -> event_or_error(json)
      _invalid -> Error.invalid_agent_response()
    end
  end

  defp event_or_error(json) do
    case Phantom.A2A.event_from_json(json) do
      {:ok, event} -> event
      {:error, _reason} -> Error.invalid_agent_response()
    end
  end
end
