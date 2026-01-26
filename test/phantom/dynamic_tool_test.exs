defmodule Phantom.DynamicToolTest do
  use ExUnit.Case
  import Phantom.TestDispatcher

  alias Phantom.Tool
  alias Phantom.Cache

  defmodule TestHandler do
    @moduledoc """
    Test handler module for dynamic tools
    """
    alias Phantom.Tool

    def dynamic_echo_tool(params, session) do
      message = Map.get(params, "message", "default message")
      {:reply, Tool.text("Dynamic echo: #{message}"), session}
    end

    def dynamic_math_tool(params, session) do
      a = Map.get(params, "a", 0)
      b = Map.get(params, "b", 0)
      result = a + b
      {:reply, Tool.text(%{result: result, operation: "addition"}), session}
    end

    def dynamic_error_tool(_params, session) do
      {:reply, Tool.error("This is a dynamic error"), session}
    end
  end

  defmodule TestRouter do
    @moduledoc """
    A minimal test router for dynamic tool testing
    """

    use Phantom.Router,
      name: "DynamicTest",
      vsn: "1.0",
      validate_origin: false,
      instructions: @moduledoc
  end

  setup do
    Cache.register(TestRouter)
    start_supervised({Phoenix.PubSub, name: Test.PubSub})
    start_supervised({Phantom.Tracker, [name: Phantom.Tracker, pubsub_server: Test.PubSub]})
    :ok
  end

  describe "Phantom.Tool.build/1" do
    test "builds a basic tool specification" do
      tool_spec = %{
        name: "test_tool",
        description: "A test tool",
        handler: TestHandler,
        function: :dynamic_echo_tool,
        title: "Annotated Tool",
        read_only: true,
        idempotent: true,
        input_schema: %{
          type: "object",
          properties: %{
            message: %{type: "string", description: "Message to echo"}
          },
          required: ["message"]
        },
        output_schema: %{
          type: "object",
          properties: %{
            result: %{type: "number"},
            operation: %{type: "string"}
          }
        }
      }

      tool = Tool.build(tool_spec)

      assert tool.name == "test_tool"
      assert tool.description == "A test tool"
      assert tool.handler == TestHandler
      assert tool.function == :dynamic_echo_tool
      assert tool.input_schema != nil
      assert tool.annotations != nil
      assert tool.annotations.title == "Annotated Tool"
      assert tool.annotations.read_only_hint == true
      assert tool.annotations.idempotent_hint == true
      assert tool.annotations.destructive_hint == nil
      assert is_map(tool.output_schema.properties)
    end
  end

  describe "Phantom.Cache.add_tool/2" do
    test "adds a single tool to the cache", context do
      tool_spec = %{
        name: "cached_echo_tool",
        description: "A cached echo tool",
        handler: TestHandler,
        function: :dynamic_echo_tool,
        input_schema: %{
          type: "object",
          properties: %{
            message: %{type: "string"}
          }
        }
      }

      session_id = to_string(context.test)
      request_sse_stream(session_id: session_id)
      assert_sse_connected()

      Cache.add_tool(TestRouter, tool_spec)
      tools = Cache.list(nil, TestRouter, :tools)
      tool_names = Enum.map(tools, & &1.name)

      assert "cached_echo_tool" in tool_names

      assert_notify(%{
        method: "notifications/tools/list_changed"
      })
    end

    test "adds multiple tools to the cache", context do
      tool_specs = [
        %{
          name: "multi_tool_1",
          description: "First multi tool",
          handler: TestHandler,
          function: :dynamic_echo_tool
        },
        %{
          name: "multi_tool_2",
          description: "Second multi tool",
          handler: TestHandler,
          function: :dynamic_math_tool
        }
      ]

      session_id = to_string(context.test)
      request_sse_stream(session_id: session_id)
      assert_sse_connected()

      Cache.add_tool(TestRouter, tool_specs)
      tools = Cache.list(nil, TestRouter, :tools)
      tool_names = Enum.map(tools, & &1.name)

      assert "multi_tool_1" in tool_names
      assert "multi_tool_2" in tool_names

      assert_notify(%{
        method: "notifications/tools/list_changed"
      })
    end

    test "maintains existing tools when adding new ones" do
      # Add first tool
      tool_spec_1 = %{
        name: "existing_tool",
        description: "An existing tool",
        handler: TestHandler,
        function: :dynamic_echo_tool
      }

      Cache.add_tool(TestRouter, tool_spec_1)

      # Add second tool
      tool_spec_2 = %{
        name: "new_tool",
        description: "A new tool",
        handler: TestHandler,
        function: :dynamic_math_tool
      }

      Cache.add_tool(TestRouter, tool_spec_2)
      tools = Cache.list(nil, TestRouter, :tools)
      tool_names = Enum.map(tools, & &1.name)

      assert "existing_tool" in tool_names
      assert "new_tool" in tool_names
      assert length(tools) >= 2
    end

    test "raises error for duplicate tool names" do
      tool_spec = %{
        name: "duplicate_tool",
        description: "A duplicate tool",
        handler: TestHandler,
        function: :dynamic_echo_tool
      }

      tool_spec_dupe = %{
        name: "duplicate_tool",
        description: "A different description",
        handler: TestHandler,
        function: :dynamic_echo_tool
      }

      Cache.add_tool(TestRouter, tool_spec)

      assert_raise RuntimeError, fn ->
        Cache.add_tool(TestRouter, tool_spec_dupe)
      end
    end

    test "validates that handler module and function exist" do
      tool_spec = %{
        name: "invalid_tool",
        description: "A tool with invalid handler",
        handler: NonExistentModule,
        function: :non_existent_function
      }

      assert_raise ArgumentError,
                   ~r/could not load module NonExistentModule/,
                   fn ->
                     Cache.add_tool(TestRouter, tool_spec)
                   end
    end
  end

  describe "router integration" do
    setup do
      # Add a dynamic tool for testing
      tool_spec = %{
        name: "dynamic_echo_tool",
        description: "An echo tool for router testing",
        handler: TestHandler,
        function: :dynamic_echo_tool,
        input_schema: %{
          type: "object",
          properties: %{
            message: %{type: "string", description: "Message to echo"}
          },
          required: ["message"]
        }
      }

      Cache.add_tool(TestRouter, tool_spec)
      :ok
    end

    test "dynamically added tool appears in tools/list" do
      request_tool_list(nil, router: TestRouter)

      assert_receive {:conn, conn}
      assert conn.status == 200

      assert_receive {:response, 1, "message", response}
      assert %{jsonrpc: "2.0", id: 1, result: %{tools: tools}} = response

      tool_names = Enum.map(tools, & &1.name)
      assert "dynamic_echo_tool" in tool_names
    end

    test "can invoke dynamically added tool via tools/call" do
      request_tool("dynamic_echo_tool", %{message: "hello"}, router: TestRouter)

      assert_receive {:conn, conn}
      assert conn.status == 200

      assert_receive {:response, 1, "message", response}

      assert %{
               jsonrpc: "2.0",
               id: 1,
               result: %{
                 content: [%{type: "text", text: "Dynamic echo: hello"}]
               }
             } = response
    end
  end
end
