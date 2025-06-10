defmodule Phantom.Router do
  @moduledoc ~S"""
  A DSL for defining MCP servers.
  This module provides functions that define tools, resources, and prompts.

  ## Usage

  ```elixir
  defmodule MyApp.MCP.Router do
    use Phantom.Router,
      name: "MyApp",
      vsn: "1.0"

    # Call MyApp.MCP.hello/3
    tool :hello, MyApp.MCP

    # Call MyApp.MCP.Router.hello/3
    tool :hello

    # Call MyApp.MCP.code_review/3
    prompt :code_review, MyApp.MCP

    # Call MyApp.MCP.studies/3
    resource "my_app:///studies/:id", MyApp.MCP, :studies,
      name: "Studies",
      mime_type: "application/json"

    # Call MyApp.MCP.questions/3
    resource "my_app:///questions/:id", MyApp.MCP, :questions,
      name: "Questions",
      mime_type: "application/html"
  end
  ```

  ## Telemetry

  Telemetry is provided with these events:

  - `[:phantom, :dispatch, :start]` with meta: `~w[method params request session]a`
  - `[:phantom, :dispatch, :stop]` with meta: `~w[method params request result session]a`
  - `[:phantom, :dispatch, :exception]` with meta: `~w[method kind reason stacktrace params request session]a`
  """

  require Logger

  import Phantom.Utils

  @callback connect(Phantom.Session.t(), String.t() | nil) ::
              {:ok, Phantom.Session.t()} | {:error, any()}
  @callback disconnect(Phantom.Session.t()) :: any()
  @callback terminate(Phantom.Session.t()) :: any()

  @callback dispatch_method(String.t(), module(), map(), Phantom.Session.t()) ::
              {:reply, any(), Phantom.Session.t()}
              | {:noreply, Phantom.Session.t()}
              | {:error, %{required(:code) => neg_integer(), required(:message) => binary()},
                 Phantom.Session.t()}

  @callback instructions(Phantom.Session.t()) :: {:ok, String.t()}
  @callback server_info(Phantom.Session.t()) ::
              {:ok, %{name: String.t(), version: String.t()}} | {:error, any()}
  @callback list_resources(String.t() | nil, map(), Phantom.Session.t()) ::
              {:reply, any(), Phantom.Session.t()}
              | {:noreply, Phantom.Session.t()}
              | {:error, any(), Phantom.Session.t()}

  @protocol_version "2025-03-26"

  defmacro __using__(opts) do
    name = Keyword.get(opts, :name, "Phantom MCP Server")
    vsn = Keyword.get(opts, :vsn, Mix.Project.config()[:version])
    instructions = Keyword.get(opts, :instructions, "")

    quote generated: true do
      @behaviour Phantom.Router
      import Phantom.Router,
        only: [tool: 2, tool: 3, resource: 3, resource: 4, prompt: 2, prompt: 3]

      import Phantom.Session, only: [assign: 2, assign: 3]

      @before_compile Phantom.Router

      @name unquote(name)
      @vsn unquote(vsn)

      Module.register_attribute(__MODULE__, :tool, accumulate: true)
      Module.register_attribute(__MODULE__, :prompt, accumulate: true)
      Module.register_attribute(__MODULE__, :resource_template, accumulate: true)

      def connect(session, _last_event_id), do: {:ok, session}
      def disconnect(session), do: {:ok, session}
      def terminate(session), do: {:ok, session}

      def instructions(_session), do: {:ok, unquote(instructions)}
      def server_info(_session), do: {:ok, %{name: @name, version: @vsn}}

      def list_resources(_cursor, _request, session) do
        {:error, %{code: -32601, message: "Resources not found"}, session}
      end

      def resource_for(%Phantom.Session{} = session, name, path_params \\ []) do
        resource_templates = Phantom.Cache.get(session, __MODULE__, :resource_templates)
        Phantom.Router.resource_for(resource_templates, name, path_params)
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

        with {:ok, protocol_version} <-
               Phantom.Router.validate_protocol(params["protocolVersion"], session) do
          {:reply,
           %{
             protocolVersion: protocol_version,
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

      def dispatch_method("tools/call", %{"name" => name} = params, request, session) do
        case Enum.find(Phantom.Cache.get(session, __MODULE__, :tools), &(&1.name == name)) do
          nil ->
            {:error, %{code: -32602, message: "Tool not found: #{name}"}, session}

          tool ->
            params = Map.get(params, "arguments", %{})

            Phantom.Router.wrap_tool_call(
              apply(tool.handler, tool.function, [params, request, session]),
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
        case Enum.find(Phantom.Cache.get(session, __MODULE__, :prompts), &(&1.name == name)) do
          nil ->
            {:error, %{code: -32602, message: "Prompt not found: #{name}"}, session}

          %{handler: _handler, completion_function: nil} ->
            {:error, %{code: -32601, message: "Completion not supported for #{name}"}, session}

          %{handler: handler, completion_function: function} ->
            Phantom.Router.wrap_completion_call(
              apply(handler, function, [arg, value, session]),
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
        case Enum.find(
               Phantom.Cache.get(session, __MODULE__, :resource_templates),
               &(&1.uri_template == uri_template)
             ) do
          nil ->
            {:error, %{code: -32602, message: "Resource template not found: #{uri_template}"},
             session}

          %{completion_function: nil} ->
            {:error, %{code: -32601, message: "Completion not supported for #{uri_template}"},
             session}

          %{handler: handler, completion_function: function} ->
            Phantom.Router.wrap_completion_call(
              apply(handler, function, [arg, value, session]),
              session
            )
        end
      end

      def dispatch_method("resources/templates/list", _params, request, session) do
        resource_templates =
          Enum.map(
            Phantom.Cache.get(session, __MODULE__, :resource_templates),
            &Phantom.ResourceTemplate.to_json/1
          )

        {:reply, %{resourceTemplates: resource_templates}, session}
      end

      def dispatch_method("resources/read", %{"uri" => uri} = _params, request, session) do
        {:ok, %{path: path, scheme: scheme}} = URI.new(uri)

        case Enum.find(
               Phantom.Cache.get(session, __MODULE__, :resource_templates),
               &(&1.scheme == scheme)
             ) do
          nil ->
            {:error, %{code: -32602, message: "Resource not found: #{uri}"}, session}

          %{router: resource_router} = _resource_template ->
            path_info =
              for segment <- :binary.split(path, "/", [:global]),
                  segment != "",
                  do: URI.decode(segment)

            fake_conn = %Plug.Conn{
              private: %{phantom_session: session, phantom_request: request, phantom_uri: uri},
              assigns: %{result: {:reply, nil, session}},
              method: "POST",
              request_path: path,
              path_info: path_info
            }

            fake_conn =
              try do
                resource_router.call(fake_conn, resource_router.init([]))
              rescue
                e in Plug.Conn.WrapperError ->
                  if e.reason == :undef do
                    fake_conn
                  else
                    reraise e, __STACKTRACE__
                  end
              end

            case fake_conn do
              %{assigns: %{result: {:reply, nil, session}}} ->
                {:error, %{code: -32002, message: "Resource not found", data: %{uri: uri}},
                 session}

              %{assigns: %{result: {:error, message}}} ->
                {:error, message, session}

              %{assigns: %{result: result}} ->
                result
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
            {:error, %{code: -32602, message: "Prompt not found: #{name}"}, session}

          prompt ->
            args = Map.get(params, "arguments", %{})

            Phantom.Router.wrap_prompt_call(
              apply(prompt.handler, prompt.function, [args, request, session]),
              prompt,
              session
            )
        end
      end

      def dispatch_method("resources/list", params, request, session) do
        list_resources(params["cursor"], request, session)
      end

      def dispatch_method("notification" <> _type, _params, _request, session) do
        {:notification, session}
      end

      def dispatch_method(_method, _params, _request, _session), do: :not_found

      @doc false
      defoverridable list_resources: 3, server_info: 1, connect: 2, terminate: 1, instructions: 1
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

      ###

      def local_echo(params, _request, session) do
        {:reply, %{type: "text", text: params["message"]}, session}
      end
  """
  defmacro tool(name, handler, opts) when is_list(opts) do
    quote line: __CALLER__.line, file: __CALLER__.file, generated: true do
      description = Module.delete_attribute(__MODULE__, :description)
      opts = Keyword.put_new(unquote(opts), :description, description)

      @tool {unquote(__CALLER__.line),
             Phantom.Tool.build(
               [
                 name: unquote(to_string(name)),
                 handler: unquote(handler),
                 function: unquote(name)
               ] ++ opts
             )}
    end
  end

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

    quote line: __CALLER__.line, file: __CALLER__.file, generated: true do
      description = Module.delete_attribute(__MODULE__, :description)
      opts = Keyword.put_new(unquote(opts), :description, description)

      @tool {unquote(__CALLER__.line),
             Phantom.Tool.build(
               [
                 name: unquote(to_string(name)),
                 handler: unquote(handler),
                 function: unquote(function)
               ] ++ opts
             )}
    end
  end

  @doc """
  Define a resource that can be read by the MCP client.

  ## Examples

      resource "app:///studies/:id", MyApp.MCP, :read_study,
        description: "A study",
        mime_type: "application/json"

      # ...

      def read_study(%{"id" => id}, _request, session) do
        {:reply, %{
          uri: "file:///project/lib/application.ex",
          mime_type: "text/x-elixir",
          text: "IO.puts \"Hi\""
        }, session}
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

    quote line: __CALLER__.line, file: __CALLER__.file, generated: true do
      description = Module.delete_attribute(__MODULE__, :description)
      opts = Keyword.put_new(unquote(opts), :description, description)

      @resource_template {unquote(__CALLER__.line),
                          Phantom.ResourceTemplate.build(
                            [
                              name: unquote(name),
                              router: unquote(resource_router),
                              uri: unquote(pattern),
                              scheme: unquote(uri.scheme),
                              path: unquote(uri.path),
                              handler: unquote(handler),
                              function: unquote(function)
                            ] ++ opts
                          )}
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

      def summarize(args, _request, session) do
        {:reply, %{}, session}
      end

      def summarize_complete("text", _, session) do
        {:reply, [], session}
      end

      def summarize_complete("resource", _, session) do
        # list of IDs
        {:reply, ["123"], session}
      end
  """
  defmacro prompt(name, handler, opts) when is_list(opts) do
    quote line: __CALLER__.line, file: __CALLER__.file, generated: true do
      description = Module.delete_attribute(__MODULE__, :description)
      opts = Keyword.put_new(unquote(opts), :description, description)

      @prompt {unquote(__CALLER__.line),
               Phantom.Prompt.build(
                 [
                   name: unquote(to_string(name)),
                   handler: unquote(handler),
                   function: unquote(name)
                 ] ++ opts
               )}
    end
  end

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

    quote line: __CALLER__.line, file: __CALLER__.file, generated: true do
      description = Module.delete_attribute(__MODULE__, :description)
      opts = Keyword.put_new(unquote(opts), :description, description)

      @prompt {unquote(__CALLER__.line),
               Phantom.Prompt.build(
                 [
                   name: unquote(to_string(name)),
                   handler: unquote(handler),
                   function: unquote(function)
                 ] ++ opts
               )}
    end
  end

  @doc false
  def wrap_completion_call({:reply, results, session}, _session) do
    {:reply,
     %{
       completion:
         remove_nils(%{
           values: Enum.take(List.wrap(results[:values] || results), 100),
           total: results[:total],
           hasMore: results[:has_more] || false
         })
     }, session}
  end

  def wrap_completion_call({:error, error}, session) do
    {:error, error, session}
  end

  def wrap_completion_call({:noreply, session}, _session) do
    {:noreply, session}
  end

  @doc false
  def wrap_prompt_call({:reply, results, session}, prompt, _session) do
    {:reply,
     %{
       description: prompt.description,
       messages:
         results
         |> List.wrap()
         |> Enum.map(fn result ->
           Enum.reduce(result, %{content: %{}}, fn
             {:role, role}, acc ->
               Map.put(acc, :role, role || "user")

             {:text, text}, acc ->
               put_in(acc[:content][:text], text || "")

             {:data, data}, acc ->
               put_in(acc[:content][:data], data || "")

             {:resource, data}, acc ->
               acc = put_in(acc[:content][:resource], data || %{})
               put_in(acc[:content][:type], "resource")

             {:mime_type, mime_type}, acc ->
               put_in(acc[:content][:mimeType], mime_type || "")

             {:type, type}, acc ->
               put_in(acc[:content][:type], type || "text")

             {key, value}, acc ->
               Map.put(acc, key, value)
           end)
         end)
     }, session}
  end

  def wrap_prompt_call({:error, error}, _prompt, session), do: {:error, error, session}
  def wrap_prompt_call(other, _prompt, _session), do: other

  @doc false
  def wrap_tool_call({:reply, results, session}, _session) do
    {results, error?} =
      Enum.reduce(List.wrap(results), {[], false}, fn result, {acc, _error?} ->
        result =
          Enum.reduce(result, %{}, fn
            {:text, nil}, acc -> Map.put(acc, :text, "")
            {:data, nil}, acc -> Map.put(acc, :data, "")
            {:mime_type, mime_type}, acc -> Map.put(acc, :mimeType, mime_type)
            {key, value}, acc -> Map.put(acc, key, value)
          end)

        {error?, result} = Map.pop(result, :error, false)
        {[result | acc], error?}
      end)

    results = Enum.reverse(results)
    result = if error?, do: %{content: results, isError: true}, else: %{content: results}
    {:reply, result, session}
  end

  def wrap_tool_call({:error, reason}, session), do: {:error, reason, session}
  def wrap_tool_call(other, _session), do: other

  @doc false
  def validate_protocol(@protocol_version, _), do: {:ok, @protocol_version}

  def validate_protocol(unsupported_protocol, session) do
    {:error,
     %{
       code: -32602,
       message: "Unsupported protocol version",
       data: %{
         supported: [@protocol_version],
         requested: unsupported_protocol
       }
     }, session}
  end

  defmacro __before_compile__(env) do
    env.module
    |> Module.get_attribute(:resource_template)
    |> Enum.map(&elem(&1, 1))
    |> Phantom.Router.warn_against_conflicts()

    [
      quote file: env.file, line: env.line, location: :keep, generated: true do
        @doc false
        def __phantom__(:info) do
          %{
            name: @name,
            version: @vsn,
            tools: Enum.map(@tool, &elem(&1, 1)),
            resource_templates: Enum.map(@resource_template, &elem(&1, 1)),
            prompts: Enum.map(@prompt, &elem(&1, 1))
          }
        end
      end,
      Enum.map(
        Enum.group_by(Module.get_attribute(env.module, :resource_template), &elem(&1, 1).router),
        fn {resource_router, resources} ->
          quote file: env.file,
                line: env.line,
                bind_quoted: [
                  resources: Macro.escape(resources),
                  resource_router: resource_router
                ],
                generated: true do
            defmodule resource_router do
              @moduledoc false
              use Plug.Router

              plug :match
              plug :dispatch

              for {_, resource} <- resources do
                match(resource.path,
                  to: Phantom.ResourcePlug,
                  private: %{phantom_resource: resource}
                )
              end
            end
          end
        end
      )
    ]
  end

  @doc false
  def warn_against_conflicts(resource_templates) do
    resource_templates
    |> Enum.group_by(&{&1.router, &1.name})
    |> Enum.each(fn
      {{_router, _name}, [_template]} ->
        :ok

      {{router, name}, templates} ->
        Logger.warning("""
        There are conflicting resources with the name #{inspect(name)}.
        Please distinguish them by providing a `:name` option.
        `resource_for(session, name, path_params)` will not work predictably with duplicate names

        #{inspect(Enum.map(templates, &{router, &1.handler, &1.function}), pretty: true)}
        """)
    end)

    :ok
  end

  @doc """
  Constructs a response map for the given resource with the provided parameters. This
  function is provided to your MCP Router that accepts the session instead.

  For example

  ```elixir
  iex> MyMCPRouter.resource_for(session, :name_of_resource, id: 123)
  %{
    uri: "myapp:///my-resource/123",
    mimeType: "application/json"
    text: "name of my resource"
  }
  ```
  """
  def resource_for(resource_templates, name, path_params) do
    resource_template = Enum.find(resource_templates, &(&1.name == name))
    path_params = Map.new(path_params)
    {params, segments} = Plug.Router.Utils.build_path_match(resource_template.path)

    if MapSet.equal?(MapSet.new(Map.keys(path_params)), MapSet.new(params)) do
      route =
        Enum.reduce(segments, "#{resource_template.scheme}://", fn
          segment, acc when is_binary(segment) -> "#{acc}/#{segment}"
          {field, _, _}, acc -> "#{acc}/#{Map.fetch!(path_params, field)}"
        end)

      {:ok,
       %{
         uri: route,
         mimeType: resource_template.mime_type,
         text: "Resource content"
       }}
    else
      {:error, "Parameters don't match resource."}
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
      Map.put(capabilities, :resources, %{subscribe: false, listChanged: false})
    else
      capabilities
    end
  end

  @doc false
  def logging_capability(capabilities, _router, _session) do
    capabilities
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
end
