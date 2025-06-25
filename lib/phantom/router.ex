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

  require Logger

  import Plug.Router.Utils, only: [build_path_match: 1]

  alias Phantom.Request
  alias Phantom.Resource
  alias Phantom.Session

  @callback connect(Session.t(), Plug.Conn.headers()) ::
              {:ok, Session.t()}
              | {:unauthorized | 403, www_authenticate_header :: Phantom.Plug.www_authenticate()}
              | {:forbidden | 401, message :: String.t()}
              | {:error, any()}
  @callback disconnect(Session.t()) :: any()
  @callback terminate(Session.t()) :: {:ok, any()} | {:error, any()}

  @callback dispatch_method(String.t(), module(), map(), Session.t()) ::
              {:reply, any(), Session.t()}
              | {:noreply, Session.t()}
              | {:error, %{required(:code) => neg_integer(), required(:message) => binary()},
                 Session.t()}

  @callback instructions(Session.t()) :: {:ok, String.t()}
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
        only: [tool: 2, tool: 3, resource: 2, resource: 3, resource: 4, prompt: 2, prompt: 3]

      @before_compile Phantom.Router
      @after_verify Phantom.Router

      @name unquote(name)
      @vsn unquote(vsn)

      Module.register_attribute(__MODULE__, :phantom_tools, accumulate: true)
      Module.register_attribute(__MODULE__, :phantom_prompts, accumulate: true)
      Module.register_attribute(__MODULE__, :phantom_resource_templates, accumulate: true)

      def connect(session, _auth_info), do: {:ok, session}
      def disconnect(session), do: {:ok, session}
      def terminate(session), do: {:error, nil}

      def instructions(_session), do: {:ok, unquote(instructions)}
      def server_info(_session), do: {:ok, %{name: @name, version: @vsn}}

      def list_resources(_cursor, session) do
        {:error, Request.not_found(), session}
      end

      def resource_uri(%Session{} = session, name, path_params \\ %{}) do
        Phantom.Router.resource_uri(
          Phantom.Cache.get(session, __MODULE__, :resource_templates),
          name,
          path_params
        )
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
            _ -> ""
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

      def dispatch_method("tools/list", _params, _request, session) do
        tools = Enum.map(Phantom.Cache.get(session, __MODULE__, :tools), &Phantom.Tool.to_json/1)
        {:reply, %{tools: tools}, session}
      end

      def dispatch_method(
            "logging/setLevel",
            %{"level" => log_level},
            request,
            session
          ) do
        case Session.set_log_level(session, request, log_level) do
          :ok ->
            {:reply, %{}, session}

          :error ->
            {:error, Request.closed(), session}
        end
      end

      def dispatch_method("tools/call", %{"name" => name} = params, request, session) do
        case Phantom.Router.get_tool(__MODULE__, session, name) do
          nil ->
            {:error, Request.invalid_params(), session}

          tool ->
            params = Map.get(params, "arguments", %{})

            Phantom.Router.wrap(
              :tool,
              apply(
                tool.handler,
                tool.function,
                [params, %{session | request: %{request | spec: tool}}]
              ),
              session
            )
        end
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
        case Phantom.Router.get_prompt(__MODULE__, session, name) do
          nil ->
            {:error, Request.invalid_params(), session}

          %{handler: _handler, completion_function: nil} ->
            Request.completion_response({:noreply, [], session}, session)

          %{handler: handler, completion_function: function} ->
            Request.completion_response(
              apply(handler, function, [arg, value, %{session | request: request}]),
              session
            )
        end
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
        case Phantom.Router.get_resource_template(__MODULE__, session, uri_template) do
          nil ->
            {:error, Request.invalid_params(), session}

          %{completion_function: nil} ->
            Request.completion_response({:reply, [], session}, session)

          %{handler: handler, completion_function: function} ->
            Request.completion_response(
              apply(handler, function, [arg, value, %{session | request: request}]),
              session
            )
        end
      end

      def dispatch_method("resources/templates/list", _params, _request, session) do
        resource_templates =
          Enum.map(
            Phantom.Cache.get(session, __MODULE__, :resource_templates),
            &Phantom.ResourceTemplate.to_json/1
          )

        {:reply, %{resourceTemplates: resource_templates}, session}
      end

      def dispatch_method("resources/subscribe", %{"uri" => uri} = _params, request, session) do
        if is_nil(session.pubsub) do
          {:error, Request.method_not_found(), session}
        else
          case Session.subscribe_to_resource(session, uri) do
            :ok ->
              {:reply, nil, session}

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

      def resource_for(%Session{} = session, name, path_params \\ []) do
        with {:ok, uri} <- resource_uri(session, name, path_params),
             {:ok, uri_struct} <- URI.new(uri) do
          case Enum.find(
                 Phantom.Cache.get(session, __MODULE__, :resource_templates),
                 &(&1.scheme == uri_struct.scheme)
               ) do
            nil ->
              {:error, Request.invalid_params(), session}

            resource_template ->
              {:ok, uri, resource_template}
          end
        end
      end

      def read_resource(%Session{} = session, name, path_params \\ []) do
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

      def dispatch_method("prompts/list", _params, _request, session) do
        prompts = Phantom.Cache.get(session, __MODULE__, :prompts)
        {:reply, %{prompts: Enum.map(prompts, &Phantom.Prompt.to_json/1)}, session}
      end

      def dispatch_method("prompts/get", %{"name" => name} = params, request, session) do
        prompts = Phantom.Cache.get(session, __MODULE__, :prompts)

        case Enum.find(prompts, &(&1.name == name)) do
          nil ->
            {:error, Request.invalid_params(), session}

          prompt ->
            args = Map.get(params, "arguments", %{})

            Phantom.Router.wrap(
              :prompt,
              apply(prompt.handler, prompt.function, [
                args,
                %{session | request: %{request | spec: prompt}}
              ]),
              session
            )
        end
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
        # or supply a `@description` before defining the tool
        input_schema: %{
          required: [:message],
          properties: %{
            message: %{
              type: "string",
              description: "message to echo"
            }
          }
        }

      ### handled by your function syncronously:

      def local_echo(params, session) do
        # Maps will be JSON-encoded and also provided
        # as structured content.
        {:reply, Phantom.Tool.text(params), session}
      end

      # Or asyncronously:

      def local_echo(params, session) do
        Task.async(fn ->
          Process.sleep(1000)
          Session.respond(session, Phantom.Tool.text(params))
        end)

        {:noreply, session}
      end
  """
  defmacro tool(name, handler, opts) when is_list(opts) do
    meta = %{line: __CALLER__.line, file: __CALLER__.file}

    quote line: meta.line, file: meta.file, generated: true do
      description = Module.delete_attribute(__MODULE__, :description)
      opts = Keyword.put_new(unquote(opts), :description, description)

      @phantom_tools Phantom.Tool.build(
                       [
                         name: unquote(to_string(name)),
                         handler: unquote(handler),
                         function: unquote(name),
                         meta: unquote(Macro.escape(meta))
                       ] ++ opts
                     )
    end
  end

  @doc "See `tool/3`"
  defmacro tool(name, opts_or_handler \\ []) do
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
                       [
                         name: unquote(to_string(name)),
                         handler: unquote(handler),
                         function: unquote(function),
                         meta: unquote(Macro.escape(meta))
                       ] ++ opts
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
          Response.text("IO.puts \"Hi\"")
        ), session}
      end
  """

  defmacro resource(pattern, handler, function_or_opts, opts \\ []) do
    uri =
      case URI.new(pattern) do
        {:ok, %{path: path, scheme: scheme} = uri}
        when is_binary(path) and is_binary(scheme) ->
          uri

        _ ->
          raise "Provided an invalid URI. Resource URIs must contain a path and a scheme. Provided: #{pattern}"
      end

    # TODO: better error handling
    {handler, function, opts} =
      if is_atom(function_or_opts) do
        {handler, function_or_opts, opts}
      else
        {__CALLER__.module, handler, function_or_opts}
      end

    resource_router =
      Module.concat([__CALLER__.module, ResourceRouter, Macro.camelize(uri.scheme)])

    name = opts[:name] || function
    meta = %{line: __CALLER__.line, file: __CALLER__.file}

    quote line: meta.line, file: meta.file, generated: true do
      description = Module.delete_attribute(__MODULE__, :description)
      opts = Keyword.put_new(unquote(opts), :description, description)

      @phantom_resource_templates Phantom.ResourceTemplate.build(
                                    [
                                      name: unquote(name),
                                      router: unquote(resource_router),
                                      uri: unquote(pattern),
                                      scheme: unquote(uri.scheme),
                                      path: unquote(uri.path),
                                      handler: unquote(handler),
                                      function: unquote(function),
                                      meta: unquote(Macro.escape(meta))
                                    ] ++ opts
                                  )
    end
  end

  @doc "See `resource/4`"
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
                         [
                           name: unquote(to_string(name)),
                           handler: unquote(handler),
                           function: unquote(name),
                           meta: unquote(Macro.escape(meta))
                         ] ++ opts
                       )
    end
  end

  @doc "See prompt/3"
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
                         [
                           name: unquote(to_string(name)),
                           handler: unquote(handler),
                           function: unquote(function),
                           meta: unquote(Macro.escape(meta))
                         ] ++ opts
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
    Phantom.Cache.raise_if_duplicates(info.prompts)
    Phantom.Cache.raise_if_duplicates(info.tools)
    Phantom.Cache.raise_if_duplicates(info.resource_templates)
    Phantom.Cache.validate!(info.prompts)
    Phantom.Cache.validate!(info.tools)
    Phantom.Cache.validate!(info.resource_templates)
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

        :code.soft_purge(resource_router)
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
  {:error, "Parameters don't match resource."}

  iex> MyApp.MCP.Router.resource_uri(session, :unknown, id: 123)
  {:error, "Router not found for resource"}
  ```
  """

  def resource_uri(router_or_templates, name, path_params \\ %{})

  def resource_uri(router, name, path_params) when is_atom(router) do
    resource_uri(router.__phantom__(:info).resource_templates, name, path_params)
  end

  def resource_uri(resource_templates, name, path_params) do
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
        {:error, "Parameters don't match resource."}
      end
    else
      {:error, "Router not found for resource"}
    end
  end

  @doc false
  def tool_capability(capabilities, router, session) do
    if Enum.any?(Phantom.Cache.get(session, router, :tools)) do
      Map.put(capabilities, :tools, %{listChanged: false})
    else
      capabilities
    end
  end

  @doc false
  def prompt_capability(capabilities, router, session) do
    if Enum.any?(Phantom.Cache.get(session, router, :prompts)) do
      Map.put(capabilities, :prompts, %{listChanged: false})
    else
      capabilities
    end
  end

  @doc false
  def resource_capability(capabilities, router, session) do
    if Enum.any?(Phantom.Cache.get(session, router, :resource_templates)) do
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
    resource_templates = Phantom.Cache.get(session, router, :resource_templates)
    prompts = Phantom.Cache.get(session, router, :prompts)

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

  This is available on your router as: `MyApp.MCP.Router.read_resource(session, name, params)`

  For example:

  ```elixir
  iex> MyApp.MCP.Router.read_resource(session, :my_resource, id: 321)
  #=> {:ok, "myapp:///resources/123", %{
  #   blob: "abc123"
  #   uri: "myapp:///resources/123",
  #   mimeType: "audio/wav",
  #   name: "Some audio",
  #   title: "Super audio"
  # }
  ```
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
    {:reply, Phantom.Prompt.response(result, session.request.spec), session}
  end

  def wrap(:tool, {:reply, result, %Session{} = session}, _session) do
    {:reply, Phantom.Tool.response(result), session}
  end

  @doc false
  def get_tool(router, session, name) do
    Enum.find(Phantom.Cache.get(session, router, :tools), &(&1.name == name))
  end

  @doc false
  def get_prompt(router, session, name) do
    Enum.find(Phantom.Cache.get(session, router, :prompts), &(&1.name == name))
  end

  @doc false
  def get_resource_router(router, session, scheme) do
    Enum.find_value(
      Phantom.Cache.get(session, router, :resource_templates),
      &(&1.scheme == scheme && &1.router)
    )
  end

  @doc false
  def get_resource_template(router, session, uri_template) do
    Enum.find(
      Phantom.Cache.get(session, router, :resource_templates),
      &(&1.uri_template == uri_template)
    )
  end
end
