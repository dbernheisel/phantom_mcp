defmodule Phantom.Router do
  @moduledoc ~S"""
  A DSL for defining MCP servers.
  This module provides functions that define tools, resources, and prompts.

  See `Phantom` for usage examples.

  ## Telemetry

  Telemetry is provided with these events:

  - `[:phantom, :dispatch, :start]` with meta: `~w[method params request session]a`
  - `[:phantom, :dispatch, :stop]` with meta: `~w[method params request result session]a`
  - `[:phantom, :dispatch, :exception]` with meta: `~w[method kind reason stacktrace params request session]a`
  """

  import Plug.Router.Utils, only: [build_path_match: 1]

  alias Phantom.Cache
  alias Phantom.Prompt
  alias Phantom.Request
  alias Phantom.Resource
  alias Phantom.ResourceTemplate
  alias Phantom.Session
  alias Phantom.Tool
  alias Phantom.Tool.JSONSchema

  @doc """
  When the connection is opening, this callback will be invoked.

  This is critical for authentication and authorization.

  - `{:ok, session}` - The session is authenticated and authorized.
  - `{:unauthorized | 401, www_authenticate_header}` - The session is not authenticated. The `www_authenticate_header` should
  reveal to the client how to authenticate. This can either be a string to represent a built header, or a map
  that is passed into `Phantom.Plug.www_authenticate/1` to build the header.
  - `{:forbidden | 403, message}` - The session is not authorized. For example, the user is authenticated,
  but lacks the account permissions to access the MCP server.
  - `{:error, message}` - The connection should be rejected for any other reason.
  """
  @callback connect(Session.t(), %{
              optional(:headers) => Plug.Conn.headers(),
              optional(:params) => Plug.Conn.query_params()
            }) ::
              {:ok, Session.t()}
              | {:unauthorized | 401, www_authenticate_header :: Phantom.Plug.www_authenticate()}
              | {:forbidden | 403, message :: String.t()}
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
  """
  @callback server_info(Session.t()) ::
              {:ok, %{name: String.t(), version: String.t()}} | {:error, any()}
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

  @supported_protocol_versions ~w[2024-11-05 2025-03-26 2025-06-18]

  defmacro __using__(opts) do
    name = Keyword.get(opts, :name, "Phantom MCP Server")
    vsn = Keyword.get(opts, :vsn, Mix.Project.config()[:version])
    instructions = Keyword.get(opts, :instructions, "")

    quote location: :keep, generated: true do
      @behaviour Phantom.Router

      require Phantom.ClientLogger
      require Phantom.Prompt
      require Phantom.Resource
      require Phantom.Session
      require Phantom.Tool

      import Phantom.Router,
        only: [
          tool: 2,
          tool: 3,
          tool: 4,
          resource: 2,
          resource: 3,
          resource: 4,
          prompt: 2,
          prompt: 3
        ]

      @before_compile Phantom.Router
      @after_verify Phantom.Router

      @name unquote(name)
      @vsn unquote(vsn)
      @instructions unquote(instructions)

      Module.register_attribute(__MODULE__, :phantom_tools, accumulate: true)
      Module.register_attribute(__MODULE__, :phantom_prompts, accumulate: true)
      Module.register_attribute(__MODULE__, :phantom_resource_templates, accumulate: true)

      def connect(session, _auth_info), do: {:ok, session}
      def disconnect(session), do: {:ok, session}
      def terminate(session), do: {:error, nil}

      def instructions(_session), do: {:ok, @instructions}
      def server_info(_session), do: {:ok, %{name: @name, version: @vsn}}

      def list_resources(_cursor, session) do
        {:error, Request.not_found(), session}
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
          %{method: method, params: params, request: request, session: session},
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

        session = %{
          session
          | client_info: params["clientInfo"],
            client_capabilities: %{
              roots: params["roots"],
              sampling: params["sampling"],
              elicitation: params["elicitation"]
            }
        }

        with {:ok, protocol_version} <-
               Phantom.Router.validate_protocol(params["protocolVersion"], session) do
          {:reply,
           %{
             protocolVersion: protocol_version,
             # %{elicitation: %{}}
             capabilities:
               %{}
               |> Phantom.Router.tool_capability(__MODULE__, session)
               |> Phantom.Router.prompt_capability(__MODULE__, session)
               |> Phantom.Router.resource_capability(__MODULE__, session)
               |> Phantom.Router.completion_capability(__MODULE__, session)
               |> Phantom.Router.logging_capability(__MODULE__, session),
             serverInfo: server_info,
             instructions: instructions
           }, session}
        end
      end

      def dispatch_method("ping", _params, _request, session) do
        {:reply, %{}, session}
      end

      def dispatch_method("tools/list", params, _request, session) do
        Phantom.Router.list_tools(__MODULE__, session, params["cursor"])
      end

      def dispatch_method(
            "logging/setLevel",
            %{"level" => log_level},
            request,
            session
          ) do
        case Session.set_log_level(session, request, log_level) do
          :ok -> {:reply, %{}, session}
          :error -> {:error, Request.closed(), session}
        end
      end

      def dispatch_method("tools/call", %{"name" => name} = params, request, session) do
        Phantom.Router.get_tool(__MODULE__, session, params, request)
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

      def dispatch_method("resources/subscribe", %{"uri" => uri} = _params, request, session) do
        if is_nil(session.pubsub) do
          {:error, Request.method_not_found(), session}
        else
          case Session.subscribe_to_resource(session, uri) do
            :ok ->
              {:reply, Request.empty(), session}

            _ ->
              {:error, Request.not_found("SSE stream not open"), session}
          end
        end
      end

      def dispatch_method("resources/unsubscribe", %{"uri" => uri} = _params, request, session) do
        if is_nil(session.pubsub) do
          {:error, Request.method_not_found(), session}
        else
          case Session.unsubscribe_to_resource(session, uri) do
            :ok ->
              {:reply, Request.empty(), session}

            _ ->
              {:error, Request.not_found("SSE stream not open"), session}
          end
        end
      end

      def dispatch_method("resources/read", %{"uri" => uri} = _params, request, session) do
        {:ok, %{path: path, scheme: scheme}} = URI.new(uri)

        case Phantom.Router.get_resource_router(__MODULE__, session, scheme) do
          nil ->
            {:error, Request.invalid_params(), session}

          router ->
            path_info =
              for segment <- :binary.split(path, "/", [:global]),
                  segment != "",
                  do: URI.decode(segment)

            fake_conn = %Plug.Conn{
              assigns: %{
                session: %{session | request: request},
                uri: uri,
                result: nil
              },
              method: "POST",
              request_path: path,
              path_info: path_info
            }

            result = router.call(fake_conn, router.init([])).assigns.result
            Request.resource_response(result, uri, session)
        end
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

      def dispatch_method("notification" <> type, _params, _request, session) do
        {:reply, nil, session}
      end

      # if Code.ensure_loaded?(Phoenix.PubSub) do
      #   def dispatch_method(
      #         _method,
      #         _params,
      #         %{id: request_id, response: %{} = response} = request,
      #         session
      #       ) do
      #     case Phantom.Tracker.pid_for_request(request.id) do
      #       nil -> :ok
      #       pid -> GenServer.cast(pid, {:response, request.id, response})
      #     end

      #     {:reply, nil, session}
      #   end
      # end

      def dispatch_method(method, _params, request, session) do
        {:error, Request.not_found(), session}
      end

      @doc false
      defoverridable list_resources: 2,
                     server_info: 1,
                     disconnect: 1,
                     connect: 2,
                     terminate: 1,
                     instructions: 1
    end
  end

  @doc """
  Define a tool that can be called by the MCP client.

  ## Examples

      tool :local_echo,
        description: "A test that echos your message",
        input_schema: %{
          required: [:message],
          properties: %{
            message: %{
              type: "string",
              description: "message to echo"
            }
          }
        }

      # Or with the inline DSL:

      tool :search, description: "Search for stuff" do
        field :query, :string, required: true
        field :limit, :integer, default: 10
      end

      # With an external handler module:

      tool :search, MyApp.MCP, description: "Search" do
        field :query, :string, required: true
      end
  """

  # tool/4: handler + opts + do block
  defmacro tool(name, handler, opts, [{:do, block}]) when is_list(opts) do
    {defs, fields} = JSONSchema.transform_block(block)
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
    end
  end

  # tool/3: opts + do block (self handler), OR handler + opts (no do block)
  @doc false
  defmacro tool(name, opts, [{:do, block}]) when is_list(opts) do
    {defs, fields} = JSONSchema.transform_block(block)
    handler = __CALLER__.module
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
    end
  end

  defmacro tool(name, handler, opts) when is_list(opts) do
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
        {:ok, %{scheme: scheme, path: path}} when is_binary(scheme) and is_binary(path) ->
          scheme

        _ ->
          raise "Provided an invalid URI. Resource URIs must contain a path and a scheme. Provided: #{pattern}"
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
  def validate_protocol(protocol_version, _)
      when protocol_version in @supported_protocol_versions do
    {:ok, protocol_version}
  end

  def validate_protocol(unsupported_protocol, session) do
    {:error,
     Request.invalid_params(
       data: %{
         supported: @supported_protocol_versions,
         requested: unsupported_protocol
       }
     ), session}
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
            prompts: @phantom_prompts
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

            for resource_template <- unquote(Macro.escape(resource_templates)) do
              match(resource_template.path,
                to: Phantom.ResourcePlug,
                assigns: %{resource_template: resource_template}
              )
            end

            match(_, to: Phantom.ResourcePlug.NotFound)
          end

        true = :code.soft_purge(resource_router)
        Module.create(resource_router, body, Macro.Env.location(env))
      end
    )
  end

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
          Enum.reduce(segments, "#{resource_template.scheme}://", fn
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
  def logging_capability(capabilities, _router, %{pubsub: nil}), do: capabilities

  def logging_capability(capabilities, _router, _session) do
    Map.put(capabilities, :logging, %{})
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
        receive do
          {:"$gen_cast", {:respond, ^request_id, %{result: result}}} ->
            result

          other ->
            send(session_pid, other)
        after
          10_000 ->
            {:error, Request.internal_error(), session}
        end
      end)

    intercept_session = %{session | pid: task.pid}

    path_info =
      for segment <- :binary.split(uri_struct.path, "/", [:global]),
          segment != "",
          do: URI.decode(segment)

    fake_conn = %Plug.Conn{
      assigns: %{
        session: %{intercept_session | request: fake_request},
        uri: uri,
        result: nil
      },
      method: "POST",
      request_path: uri_struct.path,
      path_info: path_info
    }

    case router.call(fake_conn, router.init([])).assigns.result do
      {:noreply, _session} ->
        case Task.yield(task) do
          {:ok, result} -> {:ok, uri, result}
          {:error, error} -> {:error, error, session}
          {:error, error, session} -> {:error, error, session}
        end

      {:reply, result, _session} ->
        Task.shutdown(task)
        {:ok, uri, List.first(result.contents)}

      _other ->
        Task.shutdown(task)
        {:error, Request.invalid_params()}
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

  def wrap(:tool, {:reply, result, %Session{} = session}, _session) do
    {:reply, Tool.response(result), session}
  end

  defp paginate(entities, cursor, fun) do
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
    |> case do
      [page, cursor] -> {page, cursor}
      [page] -> {page, nil}
      [] -> {[], nil}
    end
  end

  @doc false
  def list_tools(router, session, cursor) do
    {page, next_cursor} =
      session
      |> Cache.list(router, :tools)
      |> paginate(cursor, &Tool.to_json/1)

    {:reply, Map.merge(%{tools: page}, next_cursor || %{}), session}
  end

  @doc false
  def list_resource_templates(router, session, cursor) do
    {page, next_cursor} =
      session
      |> Cache.list(router, :resource_templates)
      |> paginate(cursor, &ResourceTemplate.to_json/1)

    {:reply, Map.merge(%{resourceTemplates: page}, next_cursor || %{}), session}
  end

  @doc false
  def list_prompts(router, session, cursor) do
    {page, next_cursor} =
      session
      |> Cache.list(router, :prompts)
      |> paginate(cursor, &Prompt.to_json/1)

    {:reply, Map.merge(%{prompts: page}, next_cursor || %{}), session}
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
        params = Map.get(params, "arguments", %{})

        case JSONSchema.maybe_validate(tool.input_schema, params) do
          {:ok, params} ->
            wrap(
              :tool,
              apply(
                tool.handler,
                tool.function,
                [params, %{session | request: %{request | spec: tool}}]
              ),
              session
            )

          {:error, reasons} ->
            {:error, Request.invalid_params(%{validation_errors: reasons}), session}
        end
    end
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

        wrap(
          :prompt,
          apply(prompt.handler, prompt.function, [
            args,
            %{session | request: %{request | spec: prompt}}
          ]),
          session
        )
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
    Request.completion_response(apply(m, f, [arg, value, session]), session)
  end

  defp do_complete(%{completion_function: {m, f, a}}, arg, value, session) do
    Request.completion_response(apply(m, f, a ++ [arg, value, session]), session)
  end

  defp do_complete(%{handler: m, completion_function: f}, arg, value, session) do
    Request.completion_response(apply(m, f, [arg, value, session]), session)
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
