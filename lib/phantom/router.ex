defmodule Phantom.Router do
  @moduledoc ~S"""
  A DSL for defining MCP servers.
  This module provides functions that define tools, resources, and prompts.

  See `Phantom` for usage examples.

  ## Options

  - `:name` — server name advertised to the client
  - `:vsn` — server version string (defaults to the OTP app version)
  - `:instructions` — server instructions, typically the moduledoc
  - `:icons`, `:website_url` — server metadata
  - `:secret_key_base` — required to support MCP `2026-07-28`. Used by
    `Phantom.RequestState` to encrypt the multi-round-trip `requestState`
    blob; nodes serving the same router must share this value. Pass a
    `{module, function, args}` tuple to read it at runtime, e.g.
    `{Application, :fetch_env!, [:my_app, :mcp_secret_key_base]}` set in
    `config/runtime.exs`, or `{MyAppWeb.Endpoint, :config, [:secret_key_base]}`.
  - `:request_state_salt` — required with `:secret_key_base`; a stable
    string used to derive the `requestState` key.

  ## Telemetry

  Telemetry is provided with these events:

  - `[:phantom, :dispatch, :start]` with meta: `~w[method params request session trace_context]a`
  - `[:phantom, :dispatch, :stop]` with meta: `~w[method params request result session trace_context]a`
  - `[:phantom, :dispatch, :exception]` with meta: `~w[method kind reason stacktrace params request session]a`

  The `:trace_context` value is a map of the W3C `traceparent`,
  `tracestate`, and `baggage` the client provided in the request's `_meta`.
  """

  import Plug.Router.Utils, only: [build_path_match: 1]

  alias Phantom.Cache
  alias Phantom.Elicit
  alias Phantom.Prompt
  alias Phantom.Request
  alias Phantom.Resource
  alias Phantom.ResourceTemplate
  alias Phantom.Session
  alias Phantom.Skill
  alias Phantom.Tasks
  alias Phantom.Tool
  alias Phantom.Tool.JSONSchema

  require Logger

  @type resolved_resource :: {String.t(), map(), ResourceTemplate.t()}

  @doc """
  When the connection is opening, this callback will be invoked.
  You will receive the session and the adapter's context, for example, when using `Phantom.Plug`, you'll get the
  `Plug.Conn`.

  This is critical for authentication and authorization.

  - `{:ok, session}` - The session is authenticated and authorized.
  - `{:unauthorized | 401, www_authenticate_header}` - The session is not authenticated. The `www_authenticate_header` should
  reveal to the client how to authenticate. This can either be a string to represent a built header, or a map
  that is passed into `Phantom.Plug.www_authenticate/1` to build the header.
  - `{:forbidden | 403, message}` - The session is not authorized. For example, the user is authenticated,
  but lacks the account permissions to access the MCP server.
  - `{:not_found | 404, message}` - The session was terminated. Clients respond by starting a new
  session. See `c:terminate/1`.
  - `{:error, message}` - The connection should be rejected for any other reason.
  """
  @callback connect(Session.t(), term()) ::
              {:ok, Session.t()}
              | {:unauthorized | 401, www_authenticate_header :: Phantom.Plug.www_authenticate()}
              | {:forbidden | 403, message :: String.t()}
              | {:not_found | 404, message :: String.t()}
              | {:error, any()}
  @doc """
  When the connection is closing, this callback will be invoked.

  The return value is largely ignored. This is a lifecycle event that will likely happen very often.
  This could be helpful if you wanted to emit a side-effect when the connection closes or
  modify the session. Consider hooking into the `[:phantom, :plug, :request, :disconnect]`
  telemetry event instead. The telemetry event will receive the modified session if implemented.
  """
  @callback disconnect(Session.t()) :: {:ok, Session.t()} | any()

  @doc """
  When the session is terminating, this callback will be invoked. Termination is when the client
  indicates they are finished with the MCP session.

  The callback will be invoked and should return `{:ok, _}` or `{:error, _}` to indicate
  success or not in terminating the session. Consider hooking into the
  `[:phantom, :plug, :request, :terminate]` telemetry event for side-effects.

  Phantom closes the session's open streams, but it does not remember terminated sessions.
  The MCP specification requires later requests with a terminated session ID to get HTTP
  404, so record the session here and reject it in `c:connect/2`:

      def terminate(session) do
        MyApp.Sessions.mark_terminated(session.id)
        {:ok, session}
      end

      def connect(session, _conn) do
        if MyApp.Sessions.terminated?(session.id),
          do: {:not_found, "Session terminated"},
          else: {:ok, session}
      end
  """
  @callback terminate(Session.t()) :: {:ok, any()} | {:error, any()}

  @doc false
  @callback dispatch_method(String.t(), module(), map(), Session.t()) ::
              {:reply, any(), Session.t()}
              | {:noreply, Session.t()}
              | {:error, %{required(:code) => neg_integer(), required(:message) => binary()},
                 Session.t()}

  @doc """
  Return the instructions for the MCP server for a given session. This is retrieved when the client
  is initializing with the server.

  By default, it will return the compiled `:instructions` provided to `use Phantom.Router`, however
  if you need the instructions to be dynamic based on the session, you may implement this
  callback and return `{:ok, "my instructions"}`. Any other shape will result in no instructions.
  """
  @callback instructions(Session.t()) :: {:ok, String.t()}

  @doc """
  Return the server information for the MCP server for a given session. This is retrieved when the client
  is initializing with the server.

  By default, it will return the static `:name` and `:vsn` provided to `use Phantom.Router`, however
  if you need the instructions to be dynamic based on the session, you may implement this
  callback and return `{:ok, %{name: "my name", version: "my version"}`. Any other shape will result
  in no server information.

  You may also include optional `:icons` (a list of serialized icon maps) and `:websiteUrl` (a URL string)
  in the returned map. These are part of the MCP 2025-11-25 specification for `Implementation`.
  """
  @callback server_info(Session.t()) ::
              {:ok,
               %{
                 required(:name) => String.t(),
                 required(:version) => String.t(),
                 optional(:icons) => [map()],
                 optional(:websiteUrl) => String.t()
               }}
              | {:error, any()}
  @doc """
  List resources available to the client.

  This will expect the response to use `Phantom.Resource.list/2` as the result.
  You may also want to leverage `resource_for/3` and `Phantom.Resource.resource_link/3`
  to construct the response. See `m:Phantom#module-defining-resources` for an exmaple.

  Remember to check for allowed resources according to `session.allowed_resource_templates`
  """
  @callback list_resources(String.t() | nil, Session.t()) ::
              {:reply, Resource.list_response(), Session.t()}
              | {:noreply, Session.t()}
              | {:error, any(), Session.t()}

  @doc """
  List the skills that `skills/list` returns, as `SKILL.md` URIs.

  Return `Phantom.Skill.list/2` with the URIs of one page and the cursor of the next
  page. The cursor is opaque to Phantom. Phantom builds each entry as `skills/get` does,
  and leaves out a URI that serves no skill to the session.

  The default implementation lists every skill route without path params, by path.

      def list_skills(cursor, session) do
        {studies, next_cursor} = MyApp.Studies.page(session.assigns.user, cursor)
        uris = Enum.map(studies, &"skill://studies/\#{&1.id}/study-review/SKILL.md")

        {:reply, Phantom.Skill.list(["skill://git-workflow/SKILL.md" | uris], next_cursor),
         session}
      end
  """
  @callback list_skills(String.t() | nil, Session.t()) ::
              {:reply, %{required(:skills) => [String.t()], optional(:nextCursor) => String.t()},
               Session.t()}
              | {:error, any(), Session.t()}

  @doc """
  Authorize subscriptions and update notifications for resolved resources.

  Each resource is represented as `{uri, path_params, resource_template}`. Return either the
  filtered resource tuples or their URI strings. Returning `nil` or an empty list rejects all
  resources. Any unresolved URI is rejected before this callback is invoked.

  Phantom invokes this callback with a one-element list when a client requests
  `resources/subscribe`, and with the requested `resourceSubscriptions` on `subscriptions/listen`. It also invokes it once with all resources in an update batch before
  notifying a subscribed session. Applications performing bulk writes should collect their
  changed resource URIs and call `Phantom.Tracker.notify_resources_updated/1` once so this
  callback can authorize them with one bulk query.

  The default implementation authorizes every resolved resource.
  """
  @callback authorize_resource_subscriptions([resolved_resource()], Session.t()) ::
              [resolved_resource() | String.t()] | nil

  @doc """
  Fetch a task the client asked about with `tasks/get`, `tasks/update`, or
  `tasks/cancel`. Implementing it enables the Tasks extension
  (`io.modelcontextprotocol/tasks`); see `Phantom.Tasks`.

  This is where you check that the session may access the task. Return
  `{:error, :not_found}` when it may not, so the client cannot tell the task
  exists. Return `{:error, :expired}` for a task past its TTL, or a JSON-RPC
  error map for anything else.
  """
  @callback get_task(task_id :: String.t(), Session.t()) ::
              {:ok, Phantom.Tasks.t()} | {:error, :not_found | :expired | map()}

  @doc """
  Receive the client's responses to a task's `input_requests` from
  `tasks/update`, such as to resume the work.

  The task is the one `c:get_task/2` returned. Only responses for keys still
  outstanding on it are passed; Phantom acknowledges the request without
  calling this when none are, or when this callback is not implemented.
  """
  @callback update_task(Phantom.Tasks.t(), input_responses :: map(), Session.t()) ::
              :ok | {:error, map()}

  @doc """
  Cancel a task, such as by cancelling its job, when the client sends
  `tasks/cancel`.

  The task is the one `c:get_task/2` returned. Cancellation is cooperative:
  the task may still finish with another status. Without this callback,
  Phantom acknowledges the request and the task carries on.
  """
  @callback cancel_task(Phantom.Tasks.t(), Session.t()) :: :ok | {:error, map()}

  @doc """
  Authorize task status notifications for task IDs a client listens to with
  `subscriptions/listen`.

  Return the allowed task IDs. Returning `nil` or an empty list, raising, or
  returning an invalid value rejects them all, and IDs the client did not ask
  for are ignored.

  Phantom invokes this callback when a client listens. Override it to check
  many tasks with one query. Before each `notifications/tasks`, Phantom fetches
  the task with `c:get_task/2`, so revoked access takes effect on the next
  update and the client gets the stored task.

  The default implementation allows the tasks `c:get_task/2` returns.
  """
  @callback authorize_task_subscriptions([task_id :: String.t()], Session.t()) ::
              [String.t()] | nil

  @optional_callbacks get_task: 2, update_task: 3, cancel_task: 2

  @dialyzer {:nowarn_function, default_vsn: 1}
  defp default_vsn(nil) do
    Mix.Project.config()[:version]
  rescue
    _ -> "0.1.0"
  end

  defp default_vsn(otp_app) when is_atom(otp_app) do
    otp_app |> Application.spec(:vsn) |> to_string()
  end

  defmacro __using__(opts) do
    name = Keyword.get(opts, :name, "Phantom MCP Server")

    vsn =
      opts
      |> Keyword.get_lazy(:vsn, fn -> default_vsn(Keyword.get(opts, :otp_app)) end)
      |> to_string()

    instructions = Keyword.get(opts, :instructions, "")
    icons = Keyword.get(opts, :icons, nil)
    website_url = Keyword.get(opts, :website_url, nil)
    secret_key_base = Keyword.get(opts, :secret_key_base, nil)
    request_state_salt = Keyword.get(opts, :request_state_salt, nil)

    quote location: :keep, generated: true do
      @behaviour Phantom.Router

      import Phantom.Router,
        only: [
          tool: 2,
          tool: 3,
          tool: 4,
          resource: 2,
          resource: 3,
          resource: 4,
          prompt: 2,
          prompt: 3,
          skill: 2,
          skill: 3
        ]

      require Phantom.ClientLogger
      require Phantom.Prompt
      require Phantom.Resource
      require Phantom.Session
      require Phantom.Tool

      @before_compile Phantom.Router
      @after_verify Phantom.Router

      @name unquote(name)
      @vsn unquote(vsn)
      @instructions unquote(instructions)
      @icons unquote(icons)
      @website_url unquote(website_url)
      @secret_key_base unquote(secret_key_base)
      @request_state_salt unquote(request_state_salt)

      Module.register_attribute(__MODULE__, :phantom_tools, accumulate: true)
      Module.register_attribute(__MODULE__, :phantom_prompts, accumulate: true)
      Module.register_attribute(__MODULE__, :phantom_resource_templates, accumulate: true)

      def connect(session, _auth_info), do: {:ok, session}
      def disconnect(session), do: {:ok, session}
      def authorize_resource_subscriptions(resources, _session), do: resources

      def authorize_task_subscriptions(task_ids, session),
        do: Phantom.Router.authorize_gettable_tasks(__MODULE__, task_ids, session)

      def terminate(session), do: {:error, nil}

      def instructions(_session), do: {:ok, @instructions}

      def server_info(_session) do
        icons =
          case @icons do
            nil -> nil
            [] -> nil
            icons -> icons |> Enum.map(&Phantom.Icon.build/1) |> Phantom.Icon.to_json_list()
          end

        {:ok,
         Phantom.Utils.remove_nils(%{
           name: @name,
           version: @vsn,
           icons: icons,
           websiteUrl: Phantom.Utils.resolve_url(@website_url)
         })}
      end

      def list_resources(_cursor, session) do
        {:error, Request.not_found(), session}
      end

      def list_skills(cursor, session) do
        Phantom.Router.Skills.default_list(__MODULE__, session, cursor)
      end

      @doc """
      Return the Resource URI for the resource by name and params.

      For example:

         iex> MyApp.MCPRouter.resource_uri(session, :my_resource, id: 4)
         {:ok, "myapp:///foo/bar/4"}

         # Without the session, it cannot account for authorized resources
         iex> MyApp.MCPRouter.resource_uri(:my_resource, id: 4)
         {:ok, "myapp:///foo/bar/4"}
      """
      def resource_uri(name) when is_atom(name), do: resource_uri(nil, name, [])

      def resource_uri(%Session{} = session, name) when is_atom(name),
        do: resource_uri(session, name, [])

      def resource_uri(nil, name) when is_atom(name), do: resource_uri(nil, name, [])

      def resource_uri(name, path_params) when is_atom(name),
        do: resource_uri(nil, name, path_params)

      def resource_uri(session, name, path_params) do
        Phantom.Router.resource_uri(
          Cache.list(session, __MODULE__, :resource_templates),
          name,
          path_params
        )
      end

      @doc """
      Return the Resource URI and ResourceTemplate spec for the resource by name and params.

      For example:

         iex> MyApp.MCPRouter.resource_for(session, :my_resource, id: 4)
         {:ok, "myapp:///foo/bar/4", %Phantom.ResourceTemplate{}}

         # Without the session, it cannot account for authorized resources
         iex> MyApp.MCPRouter.resource_for(:my_resource, id: 4)
         {:ok, "myapp:///foo/bar/4", %Phantom.ResourceTemplate{}}
      """
      def resource_for(name) when is_atom(name), do: resource_for(nil, name, [])

      def resource_for(%Session{} = session, name) when is_atom(name),
        do: resource_for(session, name, [])

      def resource_for(nil, name) when is_atom(name), do: resource_for(nil, name, [])

      def resource_for(name, path_params) when is_atom(name),
        do: resource_for(nil, name, path_params)

      def resource_for(session, name, path_params) when is_atom(name) do
        with {:ok, uri} <- resource_uri(session, name, path_params),
             {:ok, uri_struct} <- URI.new(uri) do
          name = to_string(name)

          case Enum.find(
                 Cache.list(session, __MODULE__, :resource_templates),
                 &(&1.scheme == uri_struct.scheme && &1.name == name)
               ) do
            nil ->
              {:error, Request.invalid_params(), session}

            resource_template ->
              {:ok, uri, resource_template}
          end
        end
      end

      @doc """
      Dispatch an internal read request

      For example:

         iex> MyApp.MCPRouter.read_resource(session, :my_resource, id: 4)
         {:ok, "myapp:///resources/4", %{
           blob: "abc123"
           uri: "myapp:///resources/4",
           mimeType: "audio/wav",
           name: "Some audio",
           title: "Super audio"
         }}

         # Without the session, it cannot account for authorized resources
         iex> MyApp.MCPRouter.read_resource(:my_resource, id: 4)
         {:ok, "myapp:///resources/4", %{
           blob: "abc123"
           uri: "myapp:///resources/4",
           mimeType: "audio/wav",
           name: "Some audio",
           title: "Super audio"
         }}
      """
      def read_resource(name) when is_atom(name), do: read_resource(nil, name, [])

      def read_resource(%Session{} = session, name) when is_atom(name),
        do: read_resource(session, name, [])

      def read_resource(nil, name) when is_atom(name), do: read_resource(nil, name, [])

      def read_resource(name, path_params) when is_atom(name),
        do: read_resource(nil, name, path_params)

      def read_resource(%Session{} = session, name, path_params) do
        with {:ok, uri} <- resource_uri(session, name, path_params),
             {:ok, uri_struct} <- URI.new(uri) do
          case Phantom.Router.get_resource_router(__MODULE__, session, uri_struct.scheme) do
            nil ->
              {:error, Request.invalid_params(), session}

            router ->
              Phantom.Router.read_resource(session, router, uri_struct)
          end
        end
      end

      @doc false
      def dispatch_method([method, params, request, session] = args) do
        :telemetry.span(
          [:phantom, :dispatch],
          %{
            method: method,
            params: params,
            request: request,
            session: session,
            trace_context: Phantom.Request.trace_context(request)
          },
          fn ->
            result = apply(__MODULE__, :dispatch_method, args)
            {result, %{}, %{result: result}}
          end
        )
      end

      @doc false
      def dispatch_method("initialize", params, _request, session) do
        instructions =
          case instructions(session) do
            {:ok, result} -> result
            _ -> ""
          end

        server_info =
          case server_info(session) do
            {:ok, result} -> result
            _ -> %{}
          end

        client_capabilities = %{
          roots: params["capabilities"]["roots"],
          sampling: params["capabilities"]["sampling"],
          elicitation: params["capabilities"]["elicitation"],
          ui:
            get_in(params, ["capabilities", "extensions", "io.modelcontextprotocol/ui"]) ||
              false
        }

        session = %{
          session
          | client_info: params["clientInfo"],
            client_capabilities: client_capabilities
        }

        Phantom.SessionMeta.put(session.pubsub, session.id, %{
          client_info: params["clientInfo"],
          client_capabilities: client_capabilities
        })

        with {:ok, protocol_version} <-
               Phantom.Router.validate_protocol(params["protocolVersion"], session) do
          {:reply,
           %{
             protocolVersion: protocol_version,
             capabilities:
               %{elicitation: %{}}
               |> Phantom.Router.tool_capability(__MODULE__, session)
               |> Phantom.Router.prompt_capability(__MODULE__, session)
               |> Phantom.Router.resource_capability(__MODULE__, session)
               |> Phantom.Router.completion_capability(__MODULE__, session)
               |> Phantom.Router.logging_capability(__MODULE__, session)
               |> Phantom.Router.ui_capability(__MODULE__, session)
               |> Phantom.Router.skill_capability(__MODULE__, session),
             serverInfo: server_info,
             instructions: instructions
           }, session}
        end
      end

      def dispatch_method("server/discover", _params, _request, session) do
        instructions =
          case instructions(session) do
            {:ok, result} -> result
            _ -> ""
          end

        server_info =
          case server_info(session) do
            {:ok, result} -> result
            _ -> %{}
          end

        capabilities =
          %{elicitation: %{}}
          |> Phantom.Router.tool_capability(__MODULE__, session)
          |> Phantom.Router.prompt_capability(__MODULE__, session)
          |> Phantom.Router.resource_capability(__MODULE__, session)
          |> Phantom.Router.completion_capability(__MODULE__, session)
          |> Phantom.Router.logging_capability(__MODULE__, session)
          |> Phantom.Router.ui_capability(__MODULE__, session)
          |> Phantom.Router.tasks_capability(__MODULE__)
          |> Phantom.Router.skill_capability(__MODULE__, session)

        {:reply,
         %{
           supportedVersions: Request.stateless_protocols(),
           capabilities: capabilities,
           instructions: instructions,
           _meta: %{"io.modelcontextprotocol/serverInfo" => server_info}
         }, session}
      end

      def dispatch_method("ping", _params, _request, session) do
        {:reply, %{}, session}
      end

      def dispatch_method(
            "notifications/cancelled",
            %{"requestId" => request_id},
            _request,
            session
          ) do
        Session.cancel_request(session, request_id)
        {:reply, nil, session}
      end

      def dispatch_method(
            "subscriptions/listen",
            %{"notifications" => notifications},
            request,
            session
          ) do
        with :ok <- Phantom.Router.validate_task_subscriptions(notifications, session),
             {:ok, session} <- Session.listen(session, request.id, notifications) do
          {:noreply, session}
        else
          {:error, error} -> {:error, error, session}
          :error -> {:error, Request.invalid_params(), session}
        end
      end

      def dispatch_method("tools/list", params, _request, session) do
        Phantom.Router.list_tools(__MODULE__, session, params["cursor"])
      end

      def dispatch_method("logging/setLevel", %{"level" => log_level}, request, session) do
        case Session.set_log_level(session, request, log_level) do
          :ok -> {:reply, %{}, session}
          :error -> {:error, Request.closed(), session}
        end
      end

      def dispatch_method("tools/call", %{"name" => name} = params, request, session) do
        Phantom.Router.get_tool(__MODULE__, session, params, request)
      end

      def dispatch_method("tasks/" <> _ = method, params, _request, session) do
        Phantom.Router.task_request(__MODULE__, method, params, session)
      end

      def dispatch_method(
            "completion/complete",
            %{
              "ref" => %{"type" => "ref/prompt", "name" => name},
              "argument" => %{"name" => arg, "value" => value}
            },
            request,
            session
          ) do
        Phantom.Router.prompt_completion(__MODULE__, session, name, arg, value, request)
      end

      def dispatch_method(
            "completion/complete",
            %{
              "ref" => %{"type" => "ref/resource", "uri" => uri_template},
              "argument" => %{"name" => arg, "value" => value}
            },
            request,
            session
          ) do
        Phantom.Router.resource_completion(__MODULE__, session, uri_template, arg, value, request)
      end

      def dispatch_method("resources/templates/list", params, _request, session) do
        Phantom.Router.list_resource_templates(__MODULE__, session, params["cursor"])
      end

      def dispatch_method("resources/subscribe", %{"uri" => uri} = _params, _request, session) do
        if is_nil(session.pubsub) do
          {:error, Request.not_found(), session}
        else
          resolved = Phantom.Router.resolve_resources(__MODULE__, session, [uri])

          authorized =
            Phantom.Router.authorize_resource_subscriptions(__MODULE__, resolved, session)

          case {resolved, authorized} do
            {[{^uri, _, _}], [{^uri, _, _} = resource]} ->
              case Session.subscribe_to_resource(session, resource) do
                :ok -> {:reply, %{}, session}
                _ -> {:error, Request.not_found("SSE stream not open"), session}
              end

            _ ->
              {:error, Request.resource_not_found(%{uri: uri}, session), session}
          end
        end
      end

      def dispatch_method("resources/unsubscribe", %{"uri" => uri} = _params, request, session) do
        if is_nil(session.pubsub) do
          {:error, Request.not_found(), session}
        else
          case Session.unsubscribe_to_resource(session, uri) do
            :ok ->
              {:reply, %{}, session}

            _ ->
              {:error, Request.not_found("SSE stream not open"), session}
          end
        end
      end

      def dispatch_method("resources/read", %{"uri" => uri} = _params, request, session) do
        Phantom.Router.read_resource_request(__MODULE__, session, uri, request)
      end

      def dispatch_method("prompts/list", params, _request, session) do
        Phantom.Router.list_prompts(__MODULE__, session, params["cursor"])
      end

      def dispatch_method("prompts/get", params, request, session) do
        Phantom.Router.get_prompt(__MODULE__, session, params, request)
      end

      def dispatch_method("resources/list", params, request, session) do
        list_resources(params["cursor"], %{session | request: request})
      end

      def dispatch_method("skills/list", params, request, session) do
        Phantom.Router.Skills.list(__MODULE__, %{session | request: request}, params["cursor"])
      end

      def dispatch_method("skills/get", %{"uri" => uri}, request, session)
          when is_binary(uri) do
        Phantom.Router.Skills.get(__MODULE__, %{session | request: request}, uri)
      end

      def dispatch_method("resources/directory/read", %{"uri" => uri}, request, session)
          when is_binary(uri) do
        Phantom.Router.Skills.read_directory(__MODULE__, %{session | request: request}, uri)
      end

      def dispatch_method(method, _params, _request, session)
          when method in ["skills/get", "resources/directory/read"] do
        {:error, Request.invalid_params(%{uri: "is required"}), session}
      end

      def dispatch_method("notification" <> type, _params, _request, session) do
        {:reply, nil, session}
      end

      def dispatch_method(_method, _params, %{id: request_id, response: %{} = response}, session)
          when is_binary(request_id) do
        Phantom.Router.route_client_response(session.pubsub, request_id, response)
        {:reply, nil, session}
      end

      def dispatch_method(_method, _params, %{id: request_id, error: %{} = error}, session)
          when is_binary(request_id) do
        Phantom.Router.route_client_response(session.pubsub, request_id, {:error, error})
        {:reply, nil, session}
      end

      def dispatch_method(method, _params, request, session) do
        {:error, Request.not_found(), session}
      end

      @doc false
      defoverridable list_resources: 2,
                     list_skills: 2,
                     authorize_resource_subscriptions: 2,
                     authorize_task_subscriptions: 2,
                     server_info: 1,
                     disconnect: 1,
                     connect: 2,
                     terminate: 1,
                     instructions: 1
    end
  end

  @doc """
  Define a tool that can be called by the MCP client.

  ## Input schema DSL

  Use a `do` block to define input fields with an Ecto-like syntax. This
  generates JSON Schema for clients and validates incoming arguments at
  dispatch time. See `Phantom.Tool.JSONSchema` for the full list of field
  types, options, and validators.

      tool :search, description: "Search for stuff" do
        field :query, :string, required: true
        field :limit, :integer, default: 10
        field :tags, {:array, :string}
      end

  Nested objects are supported with a `do` block on `:map` fields:

      tool :search, description: "Search" do
        field :query, :string, required: true
        field :filters, :map do
          field :category, :string, in: ~w[books movies music]
          field :min_price, :number, minimum: 0
        end
      end

  ## Map-based input schema

  For full control over the JSON Schema (without server-side validation),
  pass `:input_schema` directly:

      tool :echo,
        description: "Echo a message",
        input_schema: %{
          required: [:message],
          properties: %{
            message: %{type: "string", description: "message to echo"}
          }
        }

  ## External handler module

      tool :search, MyApp.MCP, description: "Search" do
        field :query, :string, required: true
      end
  """

  # tool/4: handler + opts + do block
  defmacro tool(name, handler, opts, [{:do, block}]) when is_list(opts) do
    {defs, fields} = JSONSchema.transform_block(block)
    {opts, app_ast} = maybe_register_app(name, opts, __CALLER__)
    meta = %{line: __CALLER__.line, file: __CALLER__.file}

    quote line: meta.line, file: meta.file, generated: true do
      description = Module.delete_attribute(__MODULE__, :description)
      opts = Keyword.put_new(unquote(opts), :description, description)

      unquote_splicing(defs)

      @phantom_tools Phantom.Tool.build(
                       Keyword.merge(
                         [
                           name: to_string(unquote(name)),
                           handler: unquote(handler),
                           function: unquote(name),
                           input_schema:
                             Phantom.Tool.JSONSchema.build_from_fields(unquote(fields)),
                           meta: unquote(Macro.escape(meta))
                         ],
                         opts
                       )
                     )

      unquote(app_ast)
    end
  end

  # tool/3: opts + do block (self handler), OR handler + opts (no do block)
  @doc false
  defmacro tool(name, opts, [{:do, block}]) when is_list(opts) do
    {defs, fields} = JSONSchema.transform_block(block)
    handler = __CALLER__.module
    {opts, app_ast} = maybe_register_app(name, opts, __CALLER__)
    meta = %{line: __CALLER__.line, file: __CALLER__.file}

    quote line: meta.line, file: meta.file, generated: true do
      description = Module.delete_attribute(__MODULE__, :description)
      opts = Keyword.put_new(unquote(opts), :description, description)

      unquote_splicing(defs)

      @phantom_tools Phantom.Tool.build(
                       Keyword.merge(
                         [
                           name: to_string(unquote(name)),
                           handler: unquote(handler),
                           function: unquote(name),
                           input_schema:
                             Phantom.Tool.JSONSchema.build_from_fields(unquote(fields)),
                           meta: unquote(Macro.escape(meta))
                         ],
                         opts
                       )
                     )

      unquote(app_ast)
    end
  end

  defmacro tool(name, handler, opts) when is_list(opts) do
    {opts, app_ast} = maybe_register_app(name, opts, __CALLER__)
    meta = %{line: __CALLER__.line, file: __CALLER__.file}

    quote line: meta.line, file: meta.file, generated: true do
      description = Module.delete_attribute(__MODULE__, :description)
      opts = Keyword.put_new(unquote(opts), :description, description)

      @phantom_tools Phantom.Tool.build(
                       Keyword.merge(
                         [
                           name: to_string(unquote(name)),
                           handler: unquote(handler),
                           function: unquote(name),
                           meta: unquote(Macro.escape(meta))
                         ],
                         opts
                       )
                     )

      unquote(app_ast)
    end
  end

  # tool/2: name + opts or handler (with default)
  @doc false
  defmacro tool(name, opts_or_handler \\ [])

  defmacro tool(name, opts_or_handler) do
    {handler, function, opts} =
      cond do
        is_list(opts_or_handler) ->
          {__CALLER__.module, name, opts_or_handler}

        is_atom(opts_or_handler) and String.starts_with?(":", to_string(opts_or_handler)) ->
          {__CALLER__.module, opts_or_handler, []}

        is_atom(opts_or_handler) ->
          {opts_or_handler, name, []}

        true ->
          raise "must provide a module or function handler"
      end

    {opts, app_ast} = maybe_register_app(name, opts, __CALLER__)
    meta = %{line: __CALLER__.line, file: __CALLER__.file}

    quote line: meta.line, file: meta.file, generated: true do
      description = Module.delete_attribute(__MODULE__, :description)
      opts = Keyword.put_new(unquote(opts), :description, description)

      @phantom_tools Phantom.Tool.build(
                       Keyword.merge(
                         [
                           name: to_string(unquote(name)),
                           handler: unquote(handler),
                           function: unquote(function),
                           meta: unquote(Macro.escape(meta))
                         ],
                         opts
                       )
                     )

      unquote(app_ast)
    end
  end

  @doc """
  Define a resource that can be read by the MCP client.

  ## Examples

      resource "app:///studies/:id", MyApp.MCP, :read_study,
        description: "A study",
        mime_type: "application/json"

      # ...

      require Phantom.Resource, as: Resource
      def read_study(%{"id" => id}, _request, session) do
        {:reply, Response.response(
          Response.text("IO.puts \\"Hi\\"")
        ), session}
      end
  """

  defmacro resource(pattern, handler, function_or_opts, opts \\ []) do
    # TODO: better error handling
    {handler, function, opts} =
      if is_atom(function_or_opts) do
        {handler, function_or_opts, opts}
      else
        {__CALLER__.module, handler, function_or_opts}
      end

    scheme =
      case URI.new(pattern) do
        {:ok, %{scheme: "ui"}} ->
          raise "The ui:// scheme is reserved for MCP Apps"

        {:ok, %{scheme: "skill"}} ->
          raise "The skill:// scheme is reserved for skills, see `Phantom.Router.skill/3`"

        {:ok, %{scheme: scheme, host: host, path: path}}
        when is_binary(scheme) and (is_binary(path) or (is_binary(host) and host != "")) ->
          scheme

        _ ->
          raise "Provided an invalid URI. Resource URIs must contain a scheme and a host or path. Provided: #{pattern}"
      end

    resource_router =
      Module.concat([__CALLER__.module, ResourceRouter, Macro.camelize(scheme)])

    meta = %{line: __CALLER__.line, file: __CALLER__.file}

    quote line: meta.line, file: meta.file, generated: true do
      description = Module.delete_attribute(__MODULE__, :description)
      opts = Keyword.put_new(unquote(opts), :description, description)

      @phantom_resource_templates Phantom.ResourceTemplate.build(
                                    Keyword.merge(
                                      [
                                        uri: unquote(pattern),
                                        router: unquote(resource_router),
                                        handler: unquote(handler),
                                        function: unquote(function),
                                        meta: unquote(Macro.escape(meta))
                                      ],
                                      opts
                                    )
                                  )
    end
  end

  @doc "See `Phantom.Router.resource/4`"
  defmacro resource(pattern, handler) when is_atom(handler) do
    quote do
      resource(unquote(pattern), unquote(handler), [], [])
    end
  end

  @doc """
  Route a skill to an action that returns a `Phantom.Skill`.

  The path locates the skill under `skill://` and ends in the skill's name.
  Segments after the first may be path params. The function defaults to the
  skill's name with hyphens replaced by underscores.

      skill "git-workflow", MyApp.MCP.Skills
      skill "acme/billing/refunds", MyApp.MCP.Skills, :refunds
      skill "studies/:study_id/study-review", MyApp.MCP.Skills, :study_review

  See `Phantom.Skill` for writing actions.
  """
  defmacro skill(path, handler, function \\ nil) do
    meta = %{line: __CALLER__.line, file: __CALLER__.file}

    quote line: meta.line, file: meta.file, generated: true do
      @phantom_resource_templates Phantom.Router.skill_template(
                                    path: unquote(path),
                                    handler: unquote(handler),
                                    function: unquote(function),
                                    router: __MODULE__,
                                    meta: unquote(Macro.escape(meta))
                                  )
    end
  end

  @doc false
  def skill_template(attrs) do
    attrs = Map.new(attrs)
    [first | rest] = segments = String.split(attrs.path, "/")

    if String.starts_with?(first, ":") do
      raise ArgumentError,
            "skill #{inspect(attrs.path)}: the first segment of a skill path can't be a path param"
    end

    if not (Regex.match?(~r/\A[a-z0-9._~-]+\z/, first) and
              Enum.all?(rest, &Regex.match?(~r/\A(:[a-z_][A-Za-z0-9_]*|[A-Za-z0-9._~-]+)\z/, &1))) do
      raise ArgumentError,
            "invalid skill path #{inspect(attrs.path)}: segments are letters, digits, " <>
              "- . _ ~ or path params, and the first segment is lowercase"
    end

    name = List.last(segments)
    Skill.validate_name!(name, "skill #{inspect(attrs.path)}")

    ResourceTemplate.build(
      uri: "skill://#{attrs.path}/*file",
      name: attrs.path,
      router: Module.concat([attrs.router, ResourceRouter, "Skill"]),
      handler: attrs.handler,
      function: attrs[:function] || Skill.function_name(name),
      meta: attrs[:meta] || %{file: "nofile", line: 0}
    )
  end

  @doc false
  defp maybe_register_app(name, opts, caller) do
    {app_module, opts} = Keyword.pop(opts, :app)

    if app_module do
      app_module = Macro.expand(app_module, caller)
      uri = "ui:///#{name}"

      # Auto-set ui.resource_uri if not already provided
      opts =
        Keyword.update(opts, :ui, [resource_uri: uri], fn ui_opts ->
          Keyword.put_new(ui_opts, :resource_uri, uri)
        end)

      resource_router = Module.concat([caller.module, ResourceRouter, "Ui"])
      meta = %{line: caller.line, file: caller.file}

      app_ast =
        quote line: meta.line, file: meta.file, generated: true do
          # description was already read by the tool macro into `description` var
          @phantom_resource_templates Phantom.ResourceTemplate.build(
                                        uri: unquote(uri),
                                        router: unquote(resource_router),
                                        handler: unquote(app_module),
                                        function: :__phantom_app__,
                                        name: to_string(unquote(name)),
                                        description: description,
                                        scheme: "ui",
                                        mime_type: "text/html;profile=mcp-app",
                                        meta: unquote(Macro.escape(meta))
                                      )
        end

      {opts, app_ast}
    else
      {opts, nil}
    end
  end

  @doc """
  Define a prompt that can be retrieved by the MCP client.

  ## Examples

      prompt :summarize,
        description: "A text prompt",
        completion_function: :summarize_complete,
        arguments: [
          %{
            name: "text",
            description: "The text to summarize",
          },
          %{
            name: "resource",
            description: "The resource to summarize",
          }
        ]
      )

      # ...

      require Phantom.Prompt, as: Prompt
      def summarize(args, _request, session) do
        {:reply, Prompt.response([
          assistant: Prompt.text("You're great"),
          user: Prompt.text("No you're great!")
        ], session}
      end

      def summarize_complete("text", _typed_value, session) do
        {:reply, ["many values"], session}
      end

      def summarize_complete("resource", _typed_value, session) do
        # list of IDs
        {:reply, ["123"], session}
      end
  """
  defmacro prompt(name, handler, opts) when is_list(opts) do
    meta = %{line: __CALLER__.line, file: __CALLER__.file}

    quote line: meta.line, file: meta.file, generated: true do
      description = Module.delete_attribute(__MODULE__, :description)
      opts = Keyword.put_new(unquote(opts), :description, description)

      @phantom_prompts Phantom.Prompt.build(
                         Keyword.merge(
                           [
                             name: to_string(unquote(name)),
                             handler: unquote(handler),
                             function: unquote(name),
                             meta: unquote(Macro.escape(meta))
                           ],
                           opts
                         )
                       )
    end
  end

  @doc "See `Phantom.Router.prompt/3`"
  defmacro prompt(name, opts_or_handler \\ []) do
    {handler, function, opts} =
      cond do
        is_list(opts_or_handler) ->
          {__CALLER__.module, name, opts_or_handler}

        is_atom(opts_or_handler) and String.starts_with?(":", to_string(opts_or_handler)) ->
          {__CALLER__.module, name, []}

        is_atom(opts_or_handler) ->
          {opts_or_handler, name, []}

        true ->
          raise "must provide a module or function handler"
      end

    meta = %{line: __CALLER__.line, file: __CALLER__.file}

    quote line: meta.line, file: meta.file, generated: true do
      description = Module.delete_attribute(__MODULE__, :description)
      opts = Keyword.put_new(unquote(opts), :description, description)

      @phantom_prompts Phantom.Prompt.build(
                         Keyword.merge(
                           [
                             name: to_string(unquote(name)),
                             handler: unquote(handler),
                             function: unquote(function),
                             meta: unquote(Macro.escape(meta))
                           ],
                           opts
                         )
                       )
    end
  end

  @doc false
  def validate_protocol(protocol_version, session) do
    supported = Request.supported_protocols()

    if protocol_version in supported,
      do: {:ok, protocol_version},
      else:
        {:error, Request.invalid_params(%{supported: supported, requested: protocol_version}),
         session}
  end

  @doc false
  def __after_verify__(mod) do
    info = mod.__phantom__(:info)
    Cache.raise_if_duplicates(info.prompts)
    Cache.raise_if_duplicates(info.tools)
    Cache.raise_if_duplicates(info.resource_templates)
    Cache.validate!(info.prompts)
    Cache.validate!(info.tools)
    Cache.validate!(info.resource_templates)
    validate_secret_key_base!(mod, info)
  end

  defp validate_secret_key_base!(mod, info) do
    has_handlers? = info.tools != [] or info.prompts != []
    secret = info.secret_key_base
    salt = info.request_state_salt

    cond do
      is_binary(secret) and byte_size(secret) < 64 ->
        raise ArgumentError, """
        #{inspect(mod)}: :secret_key_base must be at least 64 bytes (got \
        #{byte_size(secret)}).

        Used by Phantom.RequestState to encrypt the multi-round-trip
        requestState blob under MCP 2026-07-28. A short key degrades the
        security guarantee — the blob carries continuation state; an attacker
        who guesses the key could forge resume requests.

        Generate a strong key with `:crypto.strong_rand_bytes(64) |> Base.encode64()`.
        """

      not (is_nil(secret) or is_binary(secret) or mfa?(secret)) ->
        raise ArgumentError, """
        #{inspect(mod)}: :secret_key_base must be a binary or a \
        {module, function, args} tuple that returns one (got #{inspect(secret)}).
        """

      not is_nil(secret) and is_nil(salt) ->
        raise ArgumentError, """
        #{inspect(mod)}: :secret_key_base is configured but :request_state_salt is not.

        Both must be set together. The salt is the HKDF salt used to derive a
        key specifically for requestState blobs; it doesn't have to be secret
        but it must be stable. Rotating it invalidates all in-flight blobs.

            use Phantom.Router,
              ...,
              secret_key_base: ...,
              request_state_salt: "myapp request_state v1"
        """

      is_nil(secret) and is_binary(salt) ->
        raise ArgumentError, """
        #{inspect(mod)}: :request_state_salt is configured but :secret_key_base is not.

        Both must be set together.
        """

      is_nil(secret) and has_handlers? and not suppress_missing_secret_warning?() ->
        IO.warn("""
        #{inspect(mod)} has tools or prompts but no :secret_key_base /
        :request_state_salt configured.

        Tools/prompts that elicit input from the client will work under legacy
        MCP protocols (≤ 2025-11-25) but fail under MCP 2026-07-28 (stateless
        core), because Phantom needs both values to encrypt the requestState
        continuation blob.

        To support modern clients:

            use Phantom.Router,
              ...,
              secret_key_base: {Application, :fetch_env!, [:my_app, :mcp_secret_key_base]},
              request_state_salt: "myapp request_state v1"

        The key must be at least 64 bytes. Generate one with:

            :crypto.strong_rand_bytes(64) |> Base.encode64()

        The salt is a stable string of your choosing — see `Phantom.RequestState`.
        """)

      true ->
        :ok
    end
  end

  defp mfa?({mod, fun, args}), do: is_atom(mod) and is_atom(fun) and is_list(args)
  defp mfa?(_), do: false

  # Suppress the missing-secret warning only when compiling Phantom's own
  # test suite. Checking the current Mix project's app name (instead of
  # `Mix.env()`) avoids silencing the warning for downstream users running
  # their own test environments.
  defp suppress_missing_secret_warning? do
    Mix.Project.config()[:app] == :phantom_mcp
  rescue
    _ -> false
  end

  defmacro __before_compile__(env) do
    [
      quote file: env.file, line: env.line, location: :keep, generated: true do
        @doc false
        def __phantom__(:info) do
          %{
            name: @name,
            version: @vsn,
            tools: @phantom_tools,
            resource_templates: @phantom_resource_templates,
            prompts: @phantom_prompts,
            secret_key_base: @secret_key_base,
            request_state_salt: @request_state_salt
          }
        end
      end,
      Macro.escape(
        Phantom.Router.__create_resource_routers__(
          Module.get_attribute(env.module, :phantom_resource_templates),
          env
        )
      )
    ]
  end

  def __create_resource_routers__(resource_templates, env) do
    Enum.map(
      Enum.group_by(resource_templates, & &1.router),
      fn {resource_router, resource_templates} ->
        body =
          quote file: env.file, line: env.line do
            @moduledoc false
            use Plug.Router

            plug :match
            plug :dispatch

            for resource_template <-
                  unquote(Macro.escape(sort_skill_routes(resource_templates))) do
              match(Phantom.ResourceTemplate.route(resource_template),
                to: Phantom.ResourcePlug,
                assigns: %{resource_template: resource_template}
              )
            end

            match(_, to: Phantom.ResourcePlug.NotFound)
          end

        soft_purge!(resource_router)
        Module.create(resource_router, body, Macro.Env.location(env))
      end
    )
  end

  # Wait for old code to finish, because a hard purge kills the processes that run it.
  defp soft_purge!(module, attempts \\ 50) do
    cond do
      :code.soft_purge(module) ->
        :ok

      attempts > 0 ->
        Process.sleep(20)
        soft_purge!(module, attempts - 1)

      true ->
        raise "can't replace #{inspect(module)}: requests are still running its old code"
    end
  end

  # A nested skill must match before its parent, because the parent route globs all files.
  defp sort_skill_routes([%ResourceTemplate{scheme: "skill"} | _] = skills) do
    Phantom.Router.Skills.validate_nesting!(skills)
    Enum.sort_by(skills, &Phantom.Router.Skills.route_order/1)
  end

  defp sort_skill_routes(resource_templates), do: resource_templates

  @doc """
  Constructs a response map for the given resource with the provided parameters. This
  function is provided to your MCP Router that accepts the session instead.

  For example

  ```elixir
  iex> MyApp.MCP.Router.resource_uri(session, :my_resource, id: 123)
  {:ok, "myapp:///my-resource/123"}

  iex> MyApp.MCP.Router.resource_uri(session, :my_resource, foo: "error")
  {:error, :invalid_params}

  iex> MyApp.MCP.Router.resource_uri(session, :unknown, id: 123)
  {:error, :router_not_found}
  ```
  """

  def resource_uri(router_or_templates, name, path_params \\ %{})

  def resource_uri(router, name, path_params) when is_atom(router) do
    resource_uri(router.__phantom__(:info).resource_templates, name, path_params)
  end

  def resource_uri(resource_templates, name, path_params) do
    name = to_string(name)

    if resource_template = Enum.find(resource_templates, &(&1.name == name)) do
      path_params = Map.new(path_params)
      {params, segments} = build_path_match(resource_template.path)

      if MapSet.equal?(MapSet.new(Map.keys(path_params)), MapSet.new(params)) do
        route =
          Enum.reduce(segments, "#{resource_template.scheme}://#{resource_template.authority}", fn
            segment, acc when is_binary(segment) -> "#{acc}/#{segment}"
            {field, _, _}, acc -> "#{acc}/#{Map.fetch!(path_params, field)}"
          end)

        {:ok, route}
      else
        {:error, :invalid_params}
      end
    else
      {:error, :router_not_found}
    end
  end

  @doc false
  @spec resolve_resources(module(), Session.t(), [String.t()]) :: [resolved_resource()]
  def resolve_resources(router, session, uris) when is_list(uris) do
    uris
    |> Enum.uniq()
    |> Enum.reduce([], fn uri, resolved ->
      case resolve_resource(router, session, uri) do
        {:ok, {^uri, _params, _template} = resource} ->
          [resource | resolved]

        :error ->
          resolved
      end
    end)
    |> Enum.reverse()
    |> available_resolved_resources(router, session)
  end

  @doc false
  @spec available_resolved_resources([resolved_resource()], module(), Session.t()) ::
          [resolved_resource()]
  def available_resolved_resources(resources, router, session) do
    available_templates = Cache.list(session, router, :resource_templates)
    Enum.filter(resources, fn {_uri, _params, template} -> template in available_templates end)
  end

  @doc false
  @spec authorize_resource_subscriptions(module(), [resolved_resource()], Session.t()) ::
          [resolved_resource()]
  def authorize_resource_subscriptions(_router, [], _session), do: []

  def authorize_resource_subscriptions(router, resources, session) do
    allowed = router.authorize_resource_subscriptions(resources, session)
    normalize_authorized_resources(resources, allowed)
  rescue
    exception ->
      Logger.error(
        "Resource subscription authorization failed closed in #{inspect(router)}: " <>
          Exception.message(exception)
      )

      []
  catch
    kind, reason ->
      Logger.error(
        "Resource subscription authorization failed closed in #{inspect(router)}: " <>
          Exception.format_banner(kind, reason)
      )

      []
  end

  @doc false
  def authorize_task_subscriptions(_router, [], _session), do: []

  def authorize_task_subscriptions(router, task_ids, session) do
    case router.authorize_task_subscriptions(task_ids, session) do
      allowed when is_list(allowed) ->
        allowed = MapSet.new(allowed)
        Enum.filter(task_ids, &MapSet.member?(allowed, &1))

      _invalid ->
        []
    end
  rescue
    exception ->
      Logger.error(
        "Task subscription authorization failed closed in #{inspect(router)}: " <>
          Exception.message(exception)
      )

      []
  catch
    kind, reason ->
      Logger.error(
        "Task subscription authorization failed closed in #{inspect(router)}: " <>
          Exception.format_banner(kind, reason)
      )

      []
  end

  # Fails closed, as a stream must not crash on the user's callback.
  @doc false
  def get_task_for_notification(router, task_id, session) do
    case router.get_task(task_id, session) do
      {:ok, %Tasks{} = task} -> {:ok, task}
      _ -> :error
    end
  rescue
    exception ->
      Logger.error(
        "Task notification failed closed in #{inspect(router)}: " <> Exception.message(exception)
      )

      :error
  catch
    kind, reason ->
      Logger.error(
        "Task notification failed closed in #{inspect(router)}: " <>
          Exception.format_banner(kind, reason)
      )

      :error
  end

  @doc false
  def authorize_gettable_tasks(router, task_ids, session) do
    if tasks_enabled?(router),
      do: Enum.filter(task_ids, &match?({:ok, _}, router.get_task(&1, session))),
      else: []
  end

  @doc false
  def validate_task_subscriptions(%{"taskIds" => [_ | _]}, session) do
    if Session.tasks_supported?(session),
      do: :ok,
      else: {:error, Request.missing_task_capability()}
  end

  def validate_task_subscriptions(_notifications, _session), do: :ok

  @doc false
  def resolve_resource(router, session, uri) when is_binary(uri) do
    with {:ok, %{scheme: scheme} = uri_struct} when is_binary(scheme) <- URI.new(uri),
         resource_router when not is_nil(resource_router) <-
           get_resource_router(router, session, scheme) do
      fake_conn = %Plug.Conn{
        assigns: %{resolve_resource: true, session: session, uri: uri, result: nil},
        method: "GET",
        request_path: uri_struct.path || "/",
        path_info: Phantom.ResourceTemplate.path_info(uri_struct)
      }

      case resource_router.call(fake_conn, resource_router.init([])).assigns.result do
        {:resolved_resource, params, template} -> {:ok, {uri, params, template}}
        _ -> :error
      end
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end

  def resolve_resource(_router, _session, _uri), do: :error

  defp normalize_authorized_resources(_resources, nil), do: []

  defp normalize_authorized_resources(resources, allowed) when is_list(allowed) do
    input_by_uri = Map.new(resources, &{elem(&1, 0), &1})

    with {:ok, allowed_uris} <- authorized_uris(allowed, input_by_uri) do
      Enum.filter(resources, &(elem(&1, 0) in allowed_uris))
    else
      :error -> []
    end
  end

  defp normalize_authorized_resources(_resources, _invalid), do: []

  defp authorized_uris(allowed, input_by_uri) do
    Enum.reduce_while(allowed, {:ok, MapSet.new()}, fn
      uri, {:ok, uris} when is_binary(uri) ->
        if Map.has_key?(input_by_uri, uri),
          do: {:cont, {:ok, MapSet.put(uris, uri)}},
          else: {:halt, :error}

      {uri, _params, %ResourceTemplate{}} = resource, {:ok, uris} when is_binary(uri) ->
        if Map.get(input_by_uri, uri) == resource do
          {:cont, {:ok, MapSet.put(uris, uri)}}
        else
          {:halt, :error}
        end

      _, _acc ->
        {:halt, :error}
    end)
  end

  @doc false
  def tool_capability(capabilities, router, session) do
    if Enum.any?(Cache.list(session, router, :tools)) do
      Map.put(capabilities, :tools, %{listChanged: false})
    else
      capabilities
    end
  end

  @doc false
  def prompt_capability(capabilities, router, session) do
    if Enum.any?(Cache.list(session, router, :prompts)) do
      Map.put(capabilities, :prompts, %{listChanged: false})
    else
      capabilities
    end
  end

  @doc false
  def resource_capability(capabilities, router, session) do
    if Enum.any?(Cache.list(session, router, :resource_templates)) do
      Map.put(capabilities, :resources, %{
        subscribe: not is_nil(session.pubsub),
        listChanged: false
      })
    else
      capabilities
    end
  end

  @doc false
  def logging_capability(capabilities, _router, %{pubsub: nil, pid: nil}), do: capabilities

  def logging_capability(capabilities, _router, _session) do
    Map.put(capabilities, :logging, %{})
  end

  @doc false
  def ui_capability(capabilities, router, session) do
    resource_templates = Cache.list(session, router, :resource_templates)

    if Enum.any?(resource_templates, &(&1.scheme == "ui")) do
      extensions = Map.get(capabilities, :extensions, %{})

      Map.put(
        capabilities,
        :extensions,
        Map.put(extensions, "io.modelcontextprotocol/ui", %{
          mimeTypes: ["text/html;profile=mcp-app"]
        })
      )
    else
      capabilities
    end
  end

  @doc false
  def tasks_capability(capabilities, router) do
    if tasks_enabled?(router) do
      extensions = Map.get(capabilities, :extensions, %{})
      Map.put(capabilities, :extensions, Map.put(extensions, Tasks.extension(), %{}))
    else
      capabilities
    end
  end

  @doc false
  def skill_capability(capabilities, router, session) do
    if Enum.any?(Cache.list(session, router, :resource_templates), &(&1.scheme == "skill")) do
      extensions = Map.get(capabilities, :extensions, %{})

      Map.put(
        capabilities,
        :extensions,
        Map.put(extensions, "io.modelcontextprotocol/skills", %{directoryRead: true})
      )
    else
      capabilities
    end
  end

  @doc false
  def completion_capability(capabilities, router, session) do
    resource_templates = Cache.list(session, router, :resource_templates)
    prompts = Cache.list(session, router, :prompts)

    Enum.reduce_while(prompts ++ resource_templates, capabilities, fn entity, _ ->
      if entity.completion_function do
        {:halt, Map.put(capabilities, :completions, %{})}
      else
        {:cont, capabilities}
      end
    end)
  end

  @doc false
  # Deliver the client's response to a server-initiated request (a result
  # map, or `{:error, error}`) to the process waiting on it. PubSub reaches it
  # at once on any node; a Tracker lookup can miss an unreplicated request.
  def route_client_response(nil, request_id, response) do
    require Logger

    case await_request_meta(request_id) do
      %{type: :elicitation, reply_ref: ref, reply_pid: pid} when is_pid(pid) ->
        Logger.debug("Routing elicitation response #{request_id} to #{inspect(pid)}")

        send(pid, {:phantom_elicitation_response, ref, response})
        Phantom.Tracker.untrack_request(request_id)

      _ ->
        Logger.debug("No tracked handler for response #{request_id}")
    end
  end

  def route_client_response(pubsub, request_id, response),
    do: Phantom.Tracker.cast_client_response(pubsub, request_id, response)

  @doc false
  # Wait for a tracked request to become visible via Tracker replication.
  # In a distributed setup, the request may be tracked on one node but
  # the response arrives on another before Phoenix.Tracker propagates.
  def await_request_meta(request_id, retries \\ 20, interval \\ 100)
  def await_request_meta(_request_id, 0, _interval), do: nil

  def await_request_meta(request_id, retries, interval) do
    case Phantom.Tracker.get_request_meta(request_id) do
      nil ->
        Process.sleep(interval)
        await_request_meta(request_id, retries - 1, interval)

      meta ->
        meta
    end
  end

  @doc """
  Reads the resource given its URI, primarily for embedded resources.

  This is available on your router as: `MyApp.MCP.Router.read_resource/3` that
  accepts the session, resource_name, and path params.

  For example:

      iex> MyApp.MCP.Router.read_resource(session, :my_resource, id: 321)
      {:ok, "myapp:///resources/123", %{
        blob: "abc123"
        uri: "myapp:///resources/123",
        mimeType: "audio/wav",
        name: "Some audio",
        title: "Super audio"
      }}
  """
  @spec read_resource(Session.t(), module(), URI.t()) ::
          {:ok, uri_string :: String.t(),
           Phantom.Resource.blob_content() | Phantom.Resource.text_content()}
          | {:error, error_response :: map()}
  def read_resource(session, router, uri_struct) do
    Process.flag(:trap_exit, true)

    fake_request = %Request{id: UUIDv7.generate()}
    request_id = fake_request.id
    session_pid = session.pid
    uri = URI.to_string(uri_struct)

    task =
      Task.async(fn ->
        await_resource_response(request_id, session_pid, session)
      end)

    intercept_session = %{session | pid: task.pid}

    fake_conn = %Plug.Conn{
      assigns: %{
        session: %{intercept_session | request: fake_request},
        uri: uri,
        result: nil
      },
      method: "POST",
      request_path: uri_struct.path || "/",
      path_info: Phantom.ResourceTemplate.path_info(uri_struct)
    }

    case router.call(fake_conn, router.init([])).assigns.result do
      {:noreply, _session} ->
        case Task.yield(task) do
          {:ok, %{contents: [first | _]}} -> {:ok, uri, first}
          {:ok, result} -> {:ok, uri, result}
          {:exit, reason} -> {:error, reason, session}
          nil -> {:error, :timeout, session}
        end

      {:reply, result, _session} ->
        Task.shutdown(task)
        {:ok, uri, List.first(result.contents)}

      _other ->
        Task.shutdown(task)
        {:error, Request.invalid_params()}
    end
  end

  defp await_resource_response(request_id, session_pid, session) do
    receive do
      {:"$gen_cast", {:respond, ^request_id, %{result: result}}} ->
        result

      other ->
        send(session_pid, other)
        await_resource_response(request_id, session_pid, session)
    after
      10_000 ->
        {:error, Request.internal_error(), session}
    end
  end

  @doc false
  def wrap(_type, {:error, error}, session), do: {:error, error, session}
  def wrap(_type, {:error, _, %Session{}} = result, _session), do: result
  def wrap(_type, nil, session), do: {:error, Request.not_found(), session}
  def wrap(_type, {:noreply, %Session{}} = result, _session), do: result

  def wrap(:prompt, {:reply, result, %Session{} = session}, _session) do
    {:reply, Prompt.response(result, session.request.spec), session}
  end

  def wrap(:tool, {:elicitation_required, elicitations}, session) when is_list(elicitations) do
    {:error, Request.url_elicitation_required(elicitations), session}
  end

  def wrap(:tool, {:reply, result, %Session{} = session}, _session) do
    {:reply, encode_request_state(Tool.response(result), session), session}
  end

  @doc false
  def encode_request_state(result, session) when is_map(result) do
    result_type = result[:resultType] || result["resultType"]
    state_key = if Map.has_key?(result, :requestState), do: :requestState, else: "requestState"
    raw = result[state_key]

    if result_type in ["input_required", "inputRequired"] and
         Map.has_key?(result, state_key) and not is_binary(raw) do
      info = session.router.__phantom__(:info)

      case request_state_keys(info) do
        {:ok, secret, salt} ->
          binding = Phantom.RequestState.binding(session.request, session)
          Map.put(result, state_key, Phantom.RequestState.encode(raw, binding, secret, salt))

        _ ->
          raise ArgumentError,
                "Tool returned input_required but #{inspect(session.router)} has no :secret_key_base / :request_state_salt configured"
      end
    else
      result
    end
  end

  def encode_request_state(result, _session), do: result

  @doc false
  def paginate(entities, cursor, fun) do
    if not is_nil(cursor) and not Enum.any?(entities, &(&1.name == cursor)) do
      {:error, Request.invalid_params(%{cursor: "Invalid cursor"})}
    else
      result =
        entities
        |> Enum.chunk_while(
          {0, []},
          fn
            _entity, %{} = cursor ->
              {:halt, cursor}

            %{name: name}, acc when name < cursor ->
              {:cont, acc}

            %{name: name}, {100, page} ->
              {:cont, Enum.reverse(page), %{nextCursor: name}}

            %{name: name} = entity, {count, page} when name >= cursor ->
              {:cont, {count + 1, [fun.(entity) | page]}}
          end,
          fn
            %{} = cursor -> {:cont, cursor, []}
            {_count, page} -> {:cont, Enum.reverse(page), []}
          end
        )

      case result do
        [page, next_cursor] -> {:ok, page, next_cursor}
        [page] -> {:ok, page, nil}
        [] -> {:ok, [], nil}
      end
    end
  end

  @doc false
  def list_tools(router, session, cursor) do
    result =
      session
      |> Cache.list(router, :tools)
      |> Enum.filter(&Phantom.UI.model_visible?/1)
      |> paginate(cursor, &Tool.to_json/1)

    case result do
      {:ok, page, next_cursor} ->
        {:reply, Map.merge(%{tools: page}, next_cursor || %{}), session}

      {:error, error} ->
        {:error, error, session}
    end
  end

  @doc false
  def list_resource_templates(router, session, cursor) do
    result =
      session
      |> Cache.list(router, :resource_templates)
      |> Enum.reject(&(&1.scheme == "skill"))
      |> paginate(cursor, &ResourceTemplate.to_json/1)

    case result do
      {:ok, page, next_cursor} ->
        {:reply, Map.merge(%{resourceTemplates: page}, next_cursor || %{}), session}

      {:error, error} ->
        {:error, error, session}
    end
  end

  @doc false
  def list_prompts(router, session, cursor) do
    result =
      session
      |> Cache.list(router, :prompts)
      |> paginate(cursor, &Prompt.to_json/1)

    case result do
      {:ok, page, next_cursor} ->
        {:reply, Map.merge(%{prompts: page}, next_cursor || %{}), session}

      {:error, error} ->
        {:error, error, session}
    end
  end

  @doc false
  def get_tool(router, session, name) do
    Enum.find(Cache.list(session, router, :tools), &(&1.name == name))
  end

  @doc false
  def get_tool(router, session, %{"name" => name} = params, request) do
    case get_tool(router, session, name) do
      nil ->
        {:error, Request.invalid_params(), session}

      tool ->
        args = Map.get(params, "arguments", %{})
        input_response_args = input_response_args(request)

        case decode_request_state(router, session, request) do
          {:ok, %Session{state: {:__phantom_await__, _pid, _ref}} = session} ->
            resume_elicitation(session, request)

          {:ok, %Session{state: {:__phantom_elicitation_required__, ids}} = session} ->
            if elicitations_completed?(request),
              do:
                get_tool(
                  router,
                  %{session | state: %{elicitation_ids: ids}},
                  params,
                  without_state(request)
                ),
              else:
                {:reply, Tool.error("The client did not complete the requested elicitation"),
                 session}

          {:ok, session} ->
            with {:ok, validated} <- JSONSchema.maybe_validate(tool.input_schema, args) do
              run_handler(
                :tool,
                tool,
                Map.merge(validated, input_response_args),
                session,
                request
              )
            else
              {:error, reasons} ->
                if Request.modern?(request) do
                  {:reply, Tool.error("Invalid tool arguments: #{Enum.join(reasons, "; ")}"),
                   session}
                else
                  {:error, Request.invalid_params(%{validation_errors: reasons}), session}
                end
            end

          {:error, :invalid_request_state} ->
            {:error, Request.invalid_params(%{requestState: "Invalid request state"}), session}

          {:error, :expired_request_state} ->
            {:error,
             %{
               code: -32001,
               message: "Request state expired",
               data: %{requestState: "expired"}
             }, session}
        end
    end
  end

  defp run_handler(kind, spec, params, session, request) do
    request_id = request.id
    parent_pid = session.pid
    task_session = %{session | request: %{request | spec: spec}}
    callers = [self() | Process.get(:"$callers", [])]

    worker =
      spawn(fn ->
        Process.put(:"$callers", callers)
        # The isolated handler uses these process keys to return its eventual
        # result to the transport process that owns the current request.
        Process.put(:phantom_adopter, parent_pid)
        Process.put(:phantom_tool_request_id, request_id)

        try do
          handler_result = apply(spec.handler, spec.function, [params, task_session])
          process_handler_result(kind, handler_result, spec, params, task_session)
        rescue
          exception ->
            :telemetry.execute([:phantom, :dispatch, :exception], %{}, %{
              kind: :error,
              reason: exception,
              stacktrace: __STACKTRACE__,
              method: telemetry_method(kind),
              params: params,
              request: request,
              session: task_session
            })

            respond_error_to_caller(Request.internal_error(Exception.message(exception)))
        end
      end)

    send(parent_pid, {:phantom_worker_started, request_id, worker})

    {:noreply, session}
  end

  defp telemetry_method(:tool), do: "tools/call"
  defp telemetry_method(:prompt), do: "prompts/get"

  # Stateless handlers serialize the supplied state into `requestState` and exit.
  # A retry decrypts that state and re-enters the handler. Legacy transports keep
  # their historical inline elicitation behavior over the open session stream.
  defp process_handler_result(
         kind,
         {:noreply, %Session{pending_elicit: {elicit, state}} = session},
         spec,
         params,
         _session
       ) do
    session = %{session | pending_elicit: nil}

    if Session.stateless?(session) do
      if Session.elicitation_supported?(session, elicit) do
        elicit
        |> Tool.input_required(state)
        |> encode_request_state(session)
        |> respond_to_caller()
      else
        required =
          if elicit.mode == :url,
            do: ["elicitation", "elicitation.url"],
            else: ["elicitation"]

        respond_error_to_caller(Request.missing_capability(required))
      end
    else
      process_legacy_reentry(kind, elicit, state, session, spec, params)
    end
  end

  defp process_handler_result(kind, result, spec, params, session) do
    finalize_result(kind, result, spec, params, session)
  end

  defp process_legacy_reentry(kind, elicit, state, session, spec, params) do
    case Session.elicit(session, elicit, await: true) do
      {:ok, response} ->
        new_session = %{session | state: state}
        new_params = Map.merge(params, elicit_response_args(response))
        handler_result = apply(spec.handler, spec.function, [new_params, new_session])
        process_handler_result(kind, handler_result, spec, new_params, new_session)

      :not_supported ->
        respond_error_to_caller(
          Request.invalid_params(%{elicit: "Client does not support elicitation"})
        )

      :timeout ->
        respond_error_to_caller(Request.internal_error("Elicitation timed out"))

      :error ->
        respond_error_to_caller(Request.internal_error("Elicitation failed"))

      other ->
        respond_error_to_caller(
          Request.internal_error("Unexpected Session.elicit/3 return: #{inspect(other)}")
        )
    end
  end

  defp finalize_result(:tool, {:reply, %Tasks{} = task, %Session{}}, _spec, _params, session) do
    if Session.tasks_supported?(session) do
      task |> Tasks.to_create_result() |> respond_to_caller()
    else
      respond_error_to_caller(Request.missing_task_capability())
    end
  end

  defp finalize_result(kind, {:reply, result, %Session{}}, spec, _params, session) do
    formatted = format_response(kind, result, session)

    with :ok <- validate_output(kind, spec, formatted),
         :ok <- validate_input_required(formatted, session) do
      respond_to_caller(encode_request_state(formatted, session))
    else
      {:error, errors} when is_list(errors) ->
        respond_to_caller(Tool.error("Invalid tool output: #{Enum.join(errors, "; ")}"))

      {:error, error} when is_map(error) ->
        respond_error_to_caller(error)
    end
  end

  defp finalize_result(_kind, {:error, error, %Session{}}, _spec, _params, _session) do
    respond_error_to_caller(error)
  end

  defp finalize_result(_kind, {:noreply, %Session{}}, _spec, _params, _session) do
    :ok
  end

  defp finalize_result(_kind, {:elicitation_required, elicitations}, _spec, _params, session)
       when is_list(elicitations) do
    if Session.stateless?(session) do
      input_requests =
        elicitations
        |> Enum.with_index()
        |> Map.new(fn {elicit, index} ->
          request = Elicit.to_input_request(elicit)
          {"elicitation-#{index}", request}
        end)

      # The state marks the follow-up call, so a declined or cancelled
      # elicitation ends the call instead of asking again. Accepting is only
      # consent to open the URL, so the retried handler gets the IDs it
      # issued to check whether the user finished.
      ids = Enum.map(elicitations, & &1.elicitation_id)

      result = %{
        resultType: "input_required",
        inputRequests: input_requests,
        requestState: {:__phantom_elicitation_required__, ids}
      }

      case validate_input_required(result, session) do
        :ok -> respond_to_caller(encode_request_state(result, session))
        {:error, error} -> respond_error_to_caller(error)
      end
    else
      respond_error_to_caller(Request.url_elicitation_required(elicitations))
    end
  end

  defp finalize_result(kind, other, _spec, _params, session) do
    respond_to_caller(format_response(kind, other, session))
  end

  defp format_response(:tool, result, _session), do: Tool.response(result)

  defp format_response(:prompt, result, session),
    do: Prompt.response(result, session.request.spec)

  defp validate_output(:tool, %{output_schema: nil}, _formatted), do: :ok

  defp validate_output(:tool, _spec, %{isError: true}), do: :ok

  defp validate_output(:tool, %{output_schema: schema}, formatted) do
    content = formatted[:structuredContent] || formatted["structuredContent"]

    case Phantom.Tool.JSONSchema.maybe_validate(schema, content) do
      {:ok, _} -> :ok
      {:error, errors} -> {:error, errors}
    end
  end

  defp validate_output(_kind, _spec, _formatted), do: :ok

  defp validate_input_required(result, session) when is_map(result) do
    type = result[:resultType] || result["resultType"]
    requests = result[:inputRequests] || result["inputRequests"]

    state? =
      Map.has_key?(result, :requestState) or
        Map.has_key?(result, "requestState")

    if type in ["input_required", "inputRequired"] do
      cond do
        not state? and not (is_map(requests) and map_size(requests) > 0) ->
          {:error,
           Request.invalid_params(%{inputRequired: "requestState or inputRequests is required"})}

        state? and is_nil(requests) ->
          :ok

        not is_map(requests) ->
          {:error, Request.invalid_params(%{inputRequests: "must be an object"})}

        invalid = Enum.find(requests, fn {_key, request} -> not valid_input_request?(request) end) ->
          {key, _request} = invalid
          {:error, Request.invalid_params(%{inputRequests: "invalid embedded request #{key}"})}

        missing = missing_input_capabilities(requests, session) ->
          {:error, Request.missing_capability(missing)}

        true ->
          :ok
      end
    else
      :ok
    end
  end

  defp valid_input_request?(%{method: method, params: params}),
    do:
      method in ["elicitation/create", "sampling/createMessage", "roots/list"] and is_map(params)

  defp valid_input_request?(%{"method" => method, "params" => params}),
    do:
      method in ["elicitation/create", "sampling/createMessage", "roots/list"] and is_map(params)

  defp valid_input_request?(_), do: false

  defp missing_input_capabilities(requests, session) do
    caps = session.client_capabilities || %{}

    requests
    |> Enum.reduce([], fn {_key, request}, acc ->
      method = request[:method] || request["method"]

      case method do
        "elicitation/create" ->
          if is_map(caps[:elicitation]), do: acc, else: ["elicitation" | acc]

        "sampling/createMessage" ->
          if is_map(caps[:sampling]), do: acc, else: ["sampling" | acc]

        "roots/list" ->
          if is_map(caps[:roots]), do: acc, else: ["roots" | acc]
      end
    end)
    |> Enum.uniq()
    |> case do
      [] -> nil
      missing -> missing
    end
  end

  # These process keys let the isolated handler task respond to its transport owner.
  defp respond_to_caller(payload) do
    Session.respond(
      Process.get(:phantom_adopter),
      Process.get(:phantom_tool_request_id),
      payload
    )
  end

  defp respond_error_to_caller(error) do
    Session.respond_error(
      Process.get(:phantom_adopter),
      Process.get(:phantom_tool_request_id),
      error
    )
  end

  # A follow-up to a call whose process waits in `Session.elicit/3`: hand it
  # the client's response, and let it answer this request.
  defp resume_elicitation(%Session{state: {:__phantom_await__, pid, ref}} = session, request) do
    response = get_in(request.params, ["inputResponses", "elicitation"])
    next = {session.pid, request.id, Session.progress_token(%{session | request: request})}
    reply_to = session.pid

    spawn(fn ->
      monitor = Process.monitor(pid)
      send(pid, {:phantom_resume, ref, response, next})

      receive do
        {:DOWN, ^monitor, :process, _pid, reason} when reason in [:noproc, :noconnection] ->
          Session.respond_error(
            reply_to,
            request.id,
            Request.internal_error("The elicitation is no longer waiting for a response")
          )
      after
        :timer.seconds(5) -> :ok
      end
    end)

    {:noreply, session}
  end

  defp maybe_resume_elicitation(%Session{state: {:__phantom_await__, _, _}} = session, request),
    do: resume_elicitation(session, request)

  defp maybe_resume_elicitation(_session, _request), do: :continue

  defp elicitations_completed?(%Request{params: %{"inputResponses" => responses}})
       when is_map(responses) and map_size(responses) > 0,
       do: Enum.all?(responses, fn {_key, response} -> response["action"] == "accept" end)

  defp elicitations_completed?(_request), do: false

  defp without_state(request),
    do: %{request | params: Map.delete(request.params, "requestState")}

  @doc false
  def decode_request_state(router, session, request) do
    meta = request.meta || %{}
    info = router.__phantom__(:info)
    request_state = request.params["requestState"] || meta["requestState"]

    with token when is_binary(token) <- request_state || :none,
         {:ok, secret, salt} <- request_state_keys(info),
         binding <- Phantom.RequestState.binding(request, session),
         {:ok, term} <-
           Phantom.RequestState.decode(token, secret, salt, binding: binding) do
      {:ok, %{session | state: term}}
    else
      :none -> {:ok, session}
      {:error, :expired} -> {:error, :expired_request_state}
      _ -> {:error, :invalid_request_state}
    end
  end

  # The key may be an MFA, so a release can read it from runtime config.
  defp request_state_keys(%{secret_key_base: nil}), do: :error

  defp request_state_keys(%{secret_key_base: secret, request_state_salt: salt}),
    do: {:ok, resolve_secret_key_base!(secret), salt}

  defp resolve_secret_key_base!({mod, fun, args}),
    do: resolve_secret_key_base!(apply(mod, fun, args))

  defp resolve_secret_key_base!(secret) when is_binary(secret) and byte_size(secret) >= 64,
    do: secret

  defp resolve_secret_key_base!(secret) do
    raise ArgumentError,
          ":secret_key_base must resolve to a binary of at least 64 bytes, got: " <>
            if(is_binary(secret), do: "#{byte_size(secret)} bytes", else: inspect(secret))
  end

  defp input_response_args(%Request{params: %{"inputResponses" => responses}})
       when is_map(responses),
       do: elicit_response_args(responses["elicitation"])

  defp input_response_args(%Request{}), do: %{}

  # A re-entered handler gets the same params on every protocol: the accepted
  # content, or the response itself when there is none (decline or cancel).
  defp elicit_response_args(%{"content" => content}) when is_map(content), do: content
  defp elicit_response_args(response) when is_map(response), do: response
  defp elicit_response_args(_response), do: %{}

  @doc false
  def task_request(router, method, params, session) do
    with :ok <- validate_task_method(router, method, session),
         :ok <- validate_tasks_supported(session),
         {:ok, task_id} <- fetch_task_id(params),
         {:ok, task} <- fetch_task(router, task_id, session) do
      run_task_method(method, router, task, params, session)
    else
      {:error, error} -> {:error, error, session}
    end
  end

  @doc false
  def tasks_enabled?(router), do: function_exported?(router, :get_task, 2)

  @task_methods ["tasks/get", "tasks/update", "tasks/cancel"]

  # The extension exists only under MCP 2026-07-28.
  defp validate_task_method(router, method, session) do
    if method in @task_methods and tasks_enabled?(router) and Session.stateless?(session),
      do: :ok,
      else: {:error, Request.not_found()}
  end

  defp validate_tasks_supported(session) do
    if Session.tasks_supported?(session),
      do: :ok,
      else: {:error, Request.missing_task_capability()}
  end

  defp fetch_task_id(%{"taskId" => task_id}) when is_binary(task_id), do: {:ok, task_id}

  defp fetch_task_id(_params),
    do: {:error, Request.invalid_params(%{taskId: "must be a string"})}

  defp fetch_task(router, task_id, session) do
    case router.get_task(task_id, session) do
      {:ok, %Tasks{} = task} -> {:ok, task}
      {:error, :not_found} -> {:error, Request.task_not_found()}
      {:error, :expired} -> {:error, Request.task_expired()}
      {:error, error} when is_map(error) -> {:error, error}
      other -> raise_callback_result!(router, "get_task/2", other)
    end
  end

  defp run_task_method("tasks/get", _router, task, _params, session),
    do: {:reply, Tasks.to_json(task), session}

  # The spec recommends ignoring responses to keys the task is not waiting on.
  defp run_task_method("tasks/update", router, task, %{"inputResponses" => responses}, session)
       when is_map(responses) do
    outstanding =
      if task.status == :input_required,
        do: Map.take(responses, Map.keys(task.input_requests)),
        else: %{}

    if map_size(outstanding) > 0 and function_exported?(router, :update_task, 3),
      do:
        task_callback_result(
          router,
          "update_task/3",
          router.update_task(task, outstanding, session),
          session
        ),
      else: {:reply, %{}, session}
  end

  defp run_task_method("tasks/update", _router, _task, _params, session),
    do: {:error, Request.invalid_params(%{inputResponses: "must be an object"}), session}

  defp run_task_method("tasks/cancel", router, task, _params, session) do
    if function_exported?(router, :cancel_task, 2),
      do:
        task_callback_result(router, "cancel_task/2", router.cancel_task(task, session), session),
      else: {:reply, %{}, session}
  end

  defp task_callback_result(_router, _callback, :ok, session), do: {:reply, %{}, session}

  defp task_callback_result(_router, _callback, {:error, error}, session) when is_map(error),
    do: {:error, error, session}

  defp task_callback_result(router, callback, other, _session),
    do: raise_callback_result!(router, callback, other)

  defp raise_callback_result!(router, callback, value) do
    raise ArgumentError,
          "#{inspect(router)}.#{callback} returned an unexpected value: #{inspect(value)}"
  end

  @doc false
  def get_prompt(router, session, name) do
    Enum.find(Cache.list(session, router, :prompts), &(&1.name == name))
  end

  @doc false
  def get_prompt(router, session, %{"name" => name} = params, request) do
    case get_prompt(router, session, name) do
      nil ->
        {:error, Request.invalid_params(), session}

      prompt ->
        args = Map.get(params, "arguments", %{})
        input_response_args = input_response_args(request)

        case decode_request_state(router, session, request) do
          {:ok, %Session{state: {:__phantom_await__, _pid, _ref}} = session} ->
            resume_elicitation(session, request)

          {:ok, session} ->
            run_handler(:prompt, prompt, Map.merge(args, input_response_args), session, request)

          {:error, :invalid_request_state} ->
            {:error, Request.invalid_params(%{requestState: "Invalid request state"}), session}

          {:error, :expired_request_state} ->
            {:error,
             %{
               code: -32001,
               message: "Request state expired",
               data: %{requestState: "expired"}
             }, session}
        end
    end
  end

  @doc false
  def prompt_completion(router, session, name, arg, value, request) do
    session = %{session | request: request}

    router
    |> get_prompt(session, name)
    |> do_complete(arg, value, session)
  end

  @doc false
  def resource_completion(router, session, uri_template, arg, value, request) do
    session = %{session | request: request}

    router
    |> get_resource_template(session, uri_template)
    |> do_complete(arg, value, session)
  end

  defp do_complete(nil, _, _, session), do: {:error, Request.invalid_params(), session}

  defp do_complete(%{handler: _handler, completion_function: nil}, _, _, session) do
    Request.completion_response({:reply, [], session}, session)
  end

  defp do_complete(%{completion_function: {m, f}}, arg, value, session) do
    Request.completion_response(call_completion(m, f, arg, value, session), session)
  end

  defp do_complete(%{completion_function: {m, f, a}}, arg, value, session) do
    Request.completion_response(apply(m, f, a ++ [arg, value, session]), session)
  end

  defp do_complete(%{handler: m, completion_function: f}, arg, value, session) do
    Request.completion_response(call_completion(m, f, arg, value, session), session)
  end

  defp call_completion(module, function, arg, value, session) do
    context = session.request.params["context"] || %{}

    if function_exported?(module, function, 4),
      do: apply(module, function, [arg, value, context, session]),
      else: apply(module, function, [arg, value, session])
  end

  @doc false
  def read_resource_request(router, session, uri, request) do
    with {:ok, session} <- decode_request_state(router, session, request),
         :continue <- maybe_resume_elicitation(session, request),
         {:ok, %{scheme: scheme} = uri_struct} when is_binary(scheme) <- URI.new(uri),
         resource_router when not is_nil(resource_router) <-
           get_resource_router(router, session, scheme) do
      fake_conn = %Plug.Conn{
        assigns: %{
          session: %{session | request: request},
          uri: uri,
          result: nil
        },
        method: "POST",
        request_path: uri_struct.path || "/",
        path_info: Phantom.ResourceTemplate.path_info(uri_struct)
      }

      result = resource_router.call(fake_conn, resource_router.init([])).assigns.result
      Request.resource_response(result, uri, session)
    else
      {:noreply, _session} = resumed ->
        resumed

      {:error, :invalid_request_state} ->
        {:error, Request.invalid_params(%{requestState: "Invalid request state"}), session}

      {:error, :expired_request_state} ->
        {:error, Request.invalid_params(%{requestState: "Expired request state"}), session}

      _ ->
        {:error, Request.invalid_params(), session}
    end
  end

  @doc false
  def get_resource_router(router, session, scheme) do
    Enum.find_value(
      Cache.list(session, router, :resource_templates),
      &(&1.scheme == scheme && &1.router)
    )
  end

  @doc false
  def get_resource_template(router, session, uri_template) do
    Enum.find(
      Cache.list(session, router, :resource_templates),
      &(&1.uri_template == uri_template)
    )
  end
end
