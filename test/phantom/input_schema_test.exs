defmodule Phantom.Tool.JSONSchemaTest do
  use ExUnit.Case

  alias Phantom.Tool.JSONSchema

  describe "build_from_fields/1" do
    test "builds schema from field list" do
      schema =
        JSONSchema.build_from_fields([
          JSONSchema.build_field(:query, :string, required: true),
          JSONSchema.build_field(:limit, :integer, default: 10)
        ])

      assert %JSONSchema{fields: fields} = schema
      assert length(fields) == 2

      query = Enum.find(fields, &(&1.name == :query))
      assert query.type == :string
      assert query.required == true

      limit = Enum.find(fields, &(&1.name == :limit))
      assert limit.type == :integer
      assert limit.default == 10
    end
  end

  describe "build_field/3" do
    test "builds a field with defaults" do
      field = JSONSchema.build_field(:name, :string, [])
      assert field.name == :name
      assert field.type == :string
      assert field.required == false
      assert field.default == nil
      assert field.validate == nil
      assert field.enum == nil
      assert field.children == nil
    end

    test "builds a field with all options" do
      field =
        JSONSchema.build_field(:count, :integer,
          required: true,
          default: 5,
          description: "The count",
          enum: [1, 5, 10],
          minimum: 1,
          maximum: 10
        )

      assert field.name == :count
      assert field.type == :integer
      assert field.required == true
      assert field.default == 5
      assert field.description == "The count"
      assert field.enum == [1, 5, 10]
      assert field.minimum == 1
      assert field.maximum == 10
    end

    test "builds a field with string constraints" do
      field =
        JSONSchema.build_field(:email, :string,
          min_length: 5,
          max_length: 100,
          pattern: "^[^@]+@[^@]+$"
        )

      assert field.min_length == 5
      assert field.max_length == 100
      assert field.pattern == "^[^@]+@[^@]+$"
    end

    test "builds an array field" do
      field = JSONSchema.build_field(:tags, {:array, :string}, [])
      assert field.type == {:array, :string}
    end

    test "builds a map field with children" do
      children =
        JSONSchema.build_from_fields([
          JSONSchema.build_field(:category, :string, []),
          JSONSchema.build_field(:min_price, :number, [])
        ])

      field = JSONSchema.build_field(:filters, :map, children: children)
      assert field.type == :map
      assert is_list(field.children)
      assert length(field.children) == 2
    end
  end

  describe "to_json/1" do
    test "converts flat schema to JSON Schema" do
      schema =
        JSONSchema.build_from_fields([
          JSONSchema.build_field(:query, :string, required: true, description: "Search query"),
          JSONSchema.build_field(:limit, :integer, default: 10, description: "Max results")
        ])

      json = JSONSchema.to_json(schema)

      assert json.type == "object"
      assert json.required == ["query"]
      assert json.properties.query == %{type: "string", description: "Search query"}
      assert json.properties.limit == %{type: "integer", description: "Max results"}
    end

    test "converts array type to JSON Schema" do
      schema =
        JSONSchema.build_from_fields([
          JSONSchema.build_field(:tags, {:array, :string}, description: "Tags list")
        ])

      json = JSONSchema.to_json(schema)

      assert json.properties.tags == %{
               type: "array",
               items: %{type: "string"},
               description: "Tags list"
             }
    end

    test "converts nested map to JSON Schema" do
      children =
        JSONSchema.build_from_fields([
          JSONSchema.build_field(:category, :string, description: "Category filter"),
          JSONSchema.build_field(:min_price, :number, required: true)
        ])

      schema =
        JSONSchema.build_from_fields([
          JSONSchema.build_field(:filters, :map, required: true, children: children)
        ])

      json = JSONSchema.to_json(schema)
      assert json.required == ["filters"]

      filters_prop = json.properties.filters
      assert filters_prop.type == "object"
      assert filters_prop.required == ["min_price"]
      assert filters_prop.properties.category == %{type: "string", description: "Category filter"}
      assert filters_prop.properties.min_price == %{type: "number"}
    end

    test "includes enum constraint in JSON Schema" do
      schema =
        JSONSchema.build_from_fields([
          JSONSchema.build_field(:status, :string, enum: ["active", "inactive"])
        ])

      json = JSONSchema.to_json(schema)
      assert json.properties.status == %{type: "string", enum: ["active", "inactive"]}
    end

    test "includes numeric constraints in JSON Schema" do
      schema =
        JSONSchema.build_from_fields([
          JSONSchema.build_field(:count, :integer, minimum: 1, maximum: 100)
        ])

      json = JSONSchema.to_json(schema)
      assert json.properties.count == %{type: "integer", minimum: 1, maximum: 100}
    end

    test "includes string constraints in JSON Schema" do
      schema =
        JSONSchema.build_from_fields([
          JSONSchema.build_field(:name, :string,
            min_length: 1,
            max_length: 50,
            pattern: "^[a-z]+$"
          )
        ])

      json = JSONSchema.to_json(schema)

      assert json.properties.name == %{
               type: "string",
               minLength: 1,
               maxLength: 50,
               pattern: "^[a-z]+$"
             }
    end

    test "converts array of integers" do
      schema =
        JSONSchema.build_from_fields([
          JSONSchema.build_field(:ids, {:array, :integer}, [])
        ])

      json = JSONSchema.to_json(schema)
      assert json.properties.ids == %{type: "array", items: %{type: "integer"}}
    end
  end

  describe "validate/2" do
    test "passes valid params" do
      schema =
        JSONSchema.build_from_fields([
          JSONSchema.build_field(:query, :string, required: true),
          JSONSchema.build_field(:limit, :integer, [])
        ])

      assert {:ok, %{"query" => "hello", "limit" => 5}} =
               JSONSchema.validate(schema, %{"query" => "hello", "limit" => 5})
    end

    test "errors on missing required field" do
      schema =
        JSONSchema.build_from_fields([
          JSONSchema.build_field(:query, :string, required: true)
        ])

      assert {:error, errors} = JSONSchema.validate(schema, %{})
      assert "Missing required field: query" in errors
    end

    test "applies defaults for missing optional fields" do
      schema =
        JSONSchema.build_from_fields([
          JSONSchema.build_field(:limit, :integer, default: 10),
          JSONSchema.build_field(:offset, :integer, default: 0)
        ])

      assert {:ok, params} = JSONSchema.validate(schema, %{})
      assert params["limit"] == 10
      assert params["offset"] == 0
    end

    test "does not overwrite provided values with defaults" do
      schema =
        JSONSchema.build_from_fields([
          JSONSchema.build_field(:limit, :integer, default: 10)
        ])

      assert {:ok, params} = JSONSchema.validate(schema, %{"limit" => 25})
      assert params["limit"] == 25
    end

    test "validates string type" do
      schema =
        JSONSchema.build_from_fields([
          JSONSchema.build_field(:name, :string, required: true)
        ])

      assert {:error, errors} = JSONSchema.validate(schema, %{"name" => 123})
      assert "Field name: expected string, got 123" in errors
    end

    test "validates integer type" do
      schema =
        JSONSchema.build_from_fields([
          JSONSchema.build_field(:count, :integer, required: true)
        ])

      assert {:error, errors} = JSONSchema.validate(schema, %{"count" => "abc"})
      assert "Field count: expected integer, got \"abc\"" in errors

      # floats are not integers
      assert {:error, errors} = JSONSchema.validate(schema, %{"count" => 1.5})
      assert "Field count: expected integer, got 1.5" in errors
    end

    test "validates number type" do
      schema =
        JSONSchema.build_from_fields([
          JSONSchema.build_field(:price, :number, required: true)
        ])

      # integers are valid numbers
      assert {:ok, _} = JSONSchema.validate(schema, %{"price" => 10})
      assert {:ok, _} = JSONSchema.validate(schema, %{"price" => 10.5})

      assert {:error, errors} = JSONSchema.validate(schema, %{"price" => "abc"})
      assert "Field price: expected number, got \"abc\"" in errors
    end

    test "validates boolean type" do
      schema =
        JSONSchema.build_from_fields([
          JSONSchema.build_field(:active, :boolean, required: true)
        ])

      assert {:ok, _} = JSONSchema.validate(schema, %{"active" => true})
      assert {:ok, _} = JSONSchema.validate(schema, %{"active" => false})

      assert {:error, errors} = JSONSchema.validate(schema, %{"active" => "yes"})
      assert "Field active: expected boolean, got \"yes\"" in errors
    end

    test "validates {:array, :string} - all elements must be strings" do
      schema =
        JSONSchema.build_from_fields([
          JSONSchema.build_field(:tags, {:array, :string}, required: true)
        ])

      assert {:ok, _} = JSONSchema.validate(schema, %{"tags" => ["a", "b", "c"]})

      assert {:error, errors} = JSONSchema.validate(schema, %{"tags" => ["a", 42, "c"]})
      assert "Field tags[1]: expected string, got 42" in errors
    end

    test "validates {:array, :integer} - rejects string elements" do
      schema =
        JSONSchema.build_from_fields([
          JSONSchema.build_field(:ids, {:array, :integer}, required: true)
        ])

      assert {:ok, _} = JSONSchema.validate(schema, %{"ids" => [1, 2, 3]})

      assert {:error, errors} = JSONSchema.validate(schema, %{"ids" => [1, "two", 3]})
      assert "Field ids[1]: expected integer, got \"two\"" in errors
    end

    test "validates array type - must be a list" do
      schema =
        JSONSchema.build_from_fields([
          JSONSchema.build_field(:tags, {:array, :string}, required: true)
        ])

      assert {:error, errors} = JSONSchema.validate(schema, %{"tags" => "not a list"})
      assert "Field tags: expected array, got \"not a list\"" in errors
    end

    test "validates :map with children recursively" do
      children =
        JSONSchema.build_from_fields([
          JSONSchema.build_field(:category, :string, required: true),
          JSONSchema.build_field(:min_price, :number, [])
        ])

      schema =
        JSONSchema.build_from_fields([
          JSONSchema.build_field(:filters, :map, required: true, children: children)
        ])

      # valid
      assert {:ok, _} =
               JSONSchema.validate(schema, %{
                 "filters" => %{"category" => "books", "min_price" => 9.99}
               })

      # missing nested required field
      assert {:error, errors} =
               JSONSchema.validate(schema, %{"filters" => %{"min_price" => 9.99}})

      assert "Missing required field: filters.category" in errors

      # wrong nested type
      assert {:error, errors} =
               JSONSchema.validate(schema, %{
                 "filters" => %{"category" => 123, "min_price" => 9.99}
               })

      assert "Field filters.category: expected string, got 123" in errors
    end

    test "validates map type - must be a map" do
      children =
        JSONSchema.build_from_fields([
          JSONSchema.build_field(:x, :string, [])
        ])

      schema =
        JSONSchema.build_from_fields([
          JSONSchema.build_field(:data, :map, required: true, children: children)
        ])

      assert {:error, errors} = JSONSchema.validate(schema, %{"data" => "not a map"})
      assert "Field data: expected map, got \"not a map\"" in errors
    end

    test "validates module-ref type delegates to module's schema" do
      # We'll define a simple test module inline
      defmodule TestNestedSchema do
        @moduledoc false
        def __input_schema__ do
          JSONSchema.build_from_fields([
            JSONSchema.build_field(:x, :integer, required: true),
            JSONSchema.build_field(:y, :integer, required: true)
          ])
        end
      end

      schema =
        JSONSchema.build_from_fields([
          JSONSchema.build_field(:point, TestNestedSchema, required: true)
        ])

      assert {:ok, _} = JSONSchema.validate(schema, %{"point" => %{"x" => 1, "y" => 2}})

      assert {:error, errors} =
               JSONSchema.validate(schema, %{"point" => %{"x" => 1}})

      assert "Missing required field: point.y" in errors
    end

    test "collects multiple errors" do
      schema =
        JSONSchema.build_from_fields([
          JSONSchema.build_field(:name, :string, required: true),
          JSONSchema.build_field(:age, :integer, required: true),
          JSONSchema.build_field(:active, :boolean, required: true)
        ])

      assert {:error, errors} = JSONSchema.validate(schema, %{})
      assert length(errors) == 3
      assert "Missing required field: name" in errors
      assert "Missing required field: age" in errors
      assert "Missing required field: active" in errors
    end

    test "enum constraint" do
      schema =
        JSONSchema.build_from_fields([
          JSONSchema.build_field(:status, :string,
            required: true,
            enum: ["active", "inactive"]
          )
        ])

      assert {:ok, _} = JSONSchema.validate(schema, %{"status" => "active"})

      assert {:error, errors} = JSONSchema.validate(schema, %{"status" => "deleted"})

      assert "Field status: value \"deleted\" not in allowed values: [\"active\", \"inactive\"]" in errors
    end

    test "minimum/maximum constraint" do
      schema =
        JSONSchema.build_from_fields([
          JSONSchema.build_field(:count, :integer, required: true, minimum: 1, maximum: 100)
        ])

      assert {:ok, _} = JSONSchema.validate(schema, %{"count" => 50})
      assert {:ok, _} = JSONSchema.validate(schema, %{"count" => 1})
      assert {:ok, _} = JSONSchema.validate(schema, %{"count" => 100})

      assert {:error, errors} = JSONSchema.validate(schema, %{"count" => 0})
      assert "Field count: value 0 is less than minimum 1" in errors

      assert {:error, errors} = JSONSchema.validate(schema, %{"count" => 101})
      assert "Field count: value 101 is greater than maximum 100" in errors
    end

    test "min_length/max_length constraint" do
      schema =
        JSONSchema.build_from_fields([
          JSONSchema.build_field(:name, :string, required: true, min_length: 2, max_length: 10)
        ])

      assert {:ok, _} = JSONSchema.validate(schema, %{"name" => "hi"})

      assert {:error, errors} = JSONSchema.validate(schema, %{"name" => "x"})
      assert "Field name: string length 1 is less than minimum 2" in errors

      assert {:error, errors} = JSONSchema.validate(schema, %{"name" => "this is way too long"})
      assert "Field name: string length 20 is greater than maximum 10" in errors
    end

    test "pattern constraint" do
      schema =
        JSONSchema.build_from_fields([
          JSONSchema.build_field(:code, :string, required: true, pattern: "^[A-Z]{3}$")
        ])

      assert {:ok, _} = JSONSchema.validate(schema, %{"code" => "ABC"})

      assert {:error, errors} = JSONSchema.validate(schema, %{"code" => "abc"})
      assert "Field code: value does not match pattern ^[A-Z]{3}$" in errors
    end

    test "custom validate: fn called and error propagated" do
      validator = fn value ->
        if String.starts_with?(value, "q:"), do: :ok, else: {:error, "must start with q:"}
      end

      schema =
        JSONSchema.build_from_fields([
          JSONSchema.build_field(:query, :string, required: true, validate: validator)
        ])

      assert {:ok, _} = JSONSchema.validate(schema, %{"query" => "q:hello"})

      assert {:error, errors} = JSONSchema.validate(schema, %{"query" => "hello"})
      assert "Field query: must start with q:" in errors
    end

    test "custom validate: with {m,f,a} tuple" do
      defmodule TestValidator do
        @moduledoc false
        def validate_range(value, min, max) do
          if value >= min and value <= max, do: :ok, else: {:error, "out of range"}
        end
      end

      schema =
        JSONSchema.build_from_fields([
          JSONSchema.build_field(:score, :integer,
            required: true,
            validate: {TestValidator, :validate_range, [1, 10]}
          )
        ])

      assert {:ok, _} = JSONSchema.validate(schema, %{"score" => 5})

      assert {:error, errors} = JSONSchema.validate(schema, %{"score" => 15})
      assert "Field score: out of range" in errors
    end

    test "custom validate: with atom resolves to handler module" do
      defmodule TestHandlerModule do
        @moduledoc false
        def validate_query(value) do
          if String.length(value) > 0, do: :ok, else: {:error, "must not be empty"}
        end
      end

      schema =
        JSONSchema.build_from_fields([
          JSONSchema.build_field(:query, :string,
            required: true,
            validate: :validate_query
          )
        ])

      assert {:ok, _} = JSONSchema.validate(schema, %{"query" => "hello"}, TestHandlerModule)

      assert {:error, errors} = JSONSchema.validate(schema, %{"query" => ""}, TestHandlerModule)
      assert "Field query: must not be empty" in errors
    end
  end

  describe "maybe_validate/2" do
    test "passthrough when schema is nil" do
      assert {:ok, %{"foo" => "bar"}} = JSONSchema.maybe_validate(nil, %{"foo" => "bar"})
    end

    test "validates when schema is present" do
      schema =
        JSONSchema.build_from_fields([
          JSONSchema.build_field(:query, :string, required: true)
        ])

      assert {:ok, _} = JSONSchema.maybe_validate(schema, %{"query" => "hello"})
      assert {:error, _} = JSONSchema.maybe_validate(schema, %{})
    end
  end

  describe "DSL macros" do
    test "inline do-block field macros compile tool with input schema" do
      defmodule DSLTestRouter do
        use Phantom.Router,
          name: "DSLTest",
          vsn: "1.0"

        tool :search_tool, description: "Search for stuff" do
          field :query, :string, required: true, description: "Search query"
          field :limit, :integer, default: 10
          field :category, :string, enum: ["science", "math"]
          field :tags, {:array, :string}
        end

        def search_tool(params, session) do
          {:reply, Phantom.Tool.text(params["query"]), session}
        end
      end

      info = DSLTestRouter.__phantom__(:info)
      tool = Enum.find(info.tools, &(&1.name == "search_tool"))

      assert tool != nil
      assert %JSONSchema{} = tool.input_schema

      # Verify JSON Schema was generated
      json = JSONSchema.to_json(tool.input_schema)
      assert json.required == ["query"]
      assert json.properties.query == %{type: "string", description: "Search query"}
      assert json.properties.limit == %{type: "integer"}
      assert json.properties.category == %{type: "string", enum: ["science", "math"]}
      assert json.properties.tags == %{type: "array", items: %{type: "string"}}

      # Verify fields were stored
      assert length(tool.input_schema.fields) == 4
    end

    test "inline nested field :x, :map do...end compiles correctly" do
      defmodule NestedDSLTestRouter do
        use Phantom.Router,
          name: "NestedDSLTest",
          vsn: "1.0"

        tool :nested_search_tool, description: "Search with filters" do
          field :query, :string, required: true

          field :filters, :map, required: true do
            field :category, :string
            field :min_price, :number
          end
        end

        def nested_search_tool(params, session) do
          {:reply, Phantom.Tool.text(params["query"]), session}
        end
      end

      info = NestedDSLTestRouter.__phantom__(:info)
      tool = Enum.find(info.tools, &(&1.name == "nested_search_tool"))

      assert %JSONSchema{} = tool.input_schema
      filters_field = Enum.find(tool.input_schema.fields, &(&1.name == :filters))
      assert filters_field.type == :map
      assert is_list(filters_field.children)
      assert length(filters_field.children) == 2

      # Verify JSON Schema nested structure
      json = JSONSchema.to_json(tool.input_schema)
      assert json.properties.filters.type == "object"
      assert json.properties.filters.properties.category == %{type: "string"}
      assert json.properties.filters.properties.min_price == %{type: "number"}
    end

    test "module-reference field compiles correctly" do
      defmodule SharedSchema do
        use Phantom.Tool.JSONSchema

        input_schema do
          field :category, :string, required: true
          field :min_price, :number
        end
      end

      defmodule ModRefDSLTestRouter do
        use Phantom.Router,
          name: "ModRefDSLTest",
          vsn: "1.0"

        tool :modref_search_tool, description: "Search with shared filters" do
          field :query, :string, required: true
          field :filters, SharedSchema, required: true
        end

        def modref_search_tool(params, session) do
          {:reply, Phantom.Tool.text(params["query"]), session}
        end
      end

      info = ModRefDSLTestRouter.__phantom__(:info)
      tool = Enum.find(info.tools, &(&1.name == "modref_search_tool"))

      filters_field = Enum.find(tool.input_schema.fields, &(&1.name == :filters))
      assert filters_field.type == SharedSchema

      # JSON Schema should expand the module's schema
      json = JSONSchema.to_json(tool.input_schema)
      assert json.properties.filters.type == "object"
      assert json.properties.filters.required == ["category"]
      assert json.properties.filters.properties.category == %{type: "string"}
    end

    test "use Phantom.Tool.JSONSchema standalone module defines __input_schema__/0" do
      defmodule StandaloneSchema do
        use Phantom.Tool.JSONSchema

        input_schema do
          field :name, :string, required: true
          field :age, :integer
        end
      end

      schema = StandaloneSchema.__input_schema__()
      assert %JSONSchema{} = schema
      assert length(schema.fields) == 2

      name_field = Enum.find(schema.fields, &(&1.name == :name))
      assert name_field.required == true
      assert name_field.type == :string
    end

    test "validate: :atom resolves to local function in standalone module" do
      defmodule StandaloneWithValidator do
        use Phantom.Tool.JSONSchema

        input_schema do
          field :email, :string, required: true, validate: :validate_email
        end

        def validate_email(value) do
          if String.contains?(value, "@"), do: :ok, else: {:error, "must contain @"}
        end
      end

      schema = StandaloneWithValidator.__input_schema__()

      # Works without a handler argument — the atom was resolved to {Module, :fun, []} at compile time
      assert {:ok, _} = JSONSchema.validate(schema, %{"email" => "a@b.com"})
      assert {:error, errors} = JSONSchema.validate(schema, %{"email" => "nope"})
      assert Enum.any?(errors, &String.contains?(&1, "must contain @"))
    end

    test "validate: :atom resolves to local function in router" do
      defmodule RouterWithValidator do
        use Phantom.Router,
          name: "RouterValidator",
          vsn: "1.0"

        tool :validated_tool, description: "Test" do
          field :email, :string, required: true, validate: :validate_email
        end

        def validated_tool(params, session) do
          {:reply, Phantom.Tool.text(params["email"]), session}
        end

        def validate_email(value) do
          if String.contains?(value, "@"), do: :ok, else: {:error, "must contain @"}
        end
      end

      info = RouterWithValidator.__phantom__(:info)
      tool = Enum.find(info.tools, &(&1.name == "validated_tool"))
      schema = tool.input_schema

      assert {:ok, _} = JSONSchema.validate(schema, %{"email" => "a@b.com"})
      assert {:error, errors} = JSONSchema.validate(schema, %{"email" => "nope"})
      assert Enum.any?(errors, &String.contains?(&1, "must contain @"))
    end

    test "tools/list JSON output has correct shape for DSL-defined tool" do
      defmodule JSONOutputRouter do
        use Phantom.Router,
          name: "JSONOutputTest",
          vsn: "1.0"

        tool :json_test_tool, description: "A test tool" do
          field :message, :string, required: true, description: "Message"
          field :count, :integer, default: 1
        end

        def json_test_tool(params, session) do
          {:reply, Phantom.Tool.text(params["message"]), session}
        end
      end

      info = JSONOutputRouter.__phantom__(:info)
      tool = Enum.find(info.tools, &(&1.name == "json_test_tool"))
      json = Phantom.Tool.to_json(tool)

      assert json.name == "json_test_tool"
      assert json.description == "A test tool"
      assert json.inputSchema.required == ["message"]
      assert json.inputSchema.type == "object"
      assert json.inputSchema.properties.message == %{type: "string", description: "Message"}
      assert json.inputSchema.properties.count == %{type: "integer"}
    end

    test "tool without input_schema still works (backwards compatible)" do
      defmodule NoSchemaRouter do
        use Phantom.Router,
          name: "NoSchemaTest",
          vsn: "1.0"

        tool :simple_tool, description: "No schema"

        def simple_tool(_params, session) do
          {:reply, Phantom.Tool.text("ok"), session}
        end
      end

      info = NoSchemaRouter.__phantom__(:info)
      tool = Enum.find(info.tools, &(&1.name == "simple_tool"))
      assert tool.input_schema == nil
    end

    test "raw map input_schema still works (backwards compatible)" do
      defmodule RawMapRouter do
        use Phantom.Router,
          name: "RawMapTest",
          vsn: "1.0"

        tool :raw_tool,
          description: "Raw schema",
          input_schema: %{
            required: [:message],
            properties: %{
              message: %{type: "string"}
            }
          }

        def raw_tool(params, session) do
          {:reply, Phantom.Tool.text(params["message"]), session}
        end
      end

      info = RawMapRouter.__phantom__(:info)
      tool = Enum.find(info.tools, &(&1.name == "raw_tool"))

      assert %{required: [:message], properties: %{message: %{type: "string"}}} =
               tool.input_schema
    end
  end

  describe "dispatch-time validation" do
    import Phantom.TestDispatcher

    setup do
      start_supervised({Phoenix.PubSub, name: Test.PubSub})
      start_supervised({Phantom.Tracker, [name: Phantom.Tracker, pubsub_server: Test.PubSub]})
      Phantom.Cache.register(Test.MCP.Router)
      :ok
    end

    test "tools/call with valid params succeeds" do
      request_tool("validated_echo_tool", %{"message" => "hello", "count" => 2}, [])

      assert_receive {:conn, conn}
      assert conn.status == 200

      assert_receive {:response, 1, "message", response}
      assert %{jsonrpc: "2.0", id: 1, result: %{content: [%{type: "text"}]}} = response
    end

    test "tools/call with missing required param returns -32602" do
      request_tool("validated_echo_tool", %{}, [])

      assert_receive {:conn, conn}
      assert conn.status == 200

      assert_receive {:response, 1, "message", response}

      assert %{
               jsonrpc: "2.0",
               id: 1,
               error: %{
                 code: -32602,
                 message: "Invalid Params",
                 data: %{validation_errors: errors}
               }
             } = response

      assert "Missing required field: message" in errors
    end

    test "tools/call with wrong type returns -32602" do
      request_tool("validated_echo_tool", %{"message" => 123}, [])

      assert_receive {:conn, conn}
      assert conn.status == 200

      assert_receive {:response, 1, "message", response}

      assert %{
               jsonrpc: "2.0",
               id: 1,
               error: %{
                 code: -32602,
                 data: %{validation_errors: errors}
               }
             } = response

      assert "Field message: expected string, got 123" in errors
    end

    test "tools/call applies defaults before calling handler" do
      request_tool("validated_echo_tool", %{"message" => "hello"}, [])

      assert_receive {:conn, conn}
      assert conn.status == 200

      assert_receive {:response, 1, "message", response}
      # The handler should receive count=1 as default
      result = response.result
      text = hd(result.content).text
      # The validated_echo_tool will echo back its params as JSON
      decoded = JSON.decode!(text)
      assert decoded["count"] == 1
    end

    test "tools/call with invalid array element returns -32602" do
      request_tool("validated_echo_tool", %{"message" => "hello", "tags" => ["a", 42]}, [])

      assert_receive {:conn, conn}
      assert conn.status == 200

      assert_receive {:response, 1, "message", response}

      assert %{
               jsonrpc: "2.0",
               id: 1,
               error: %{
                 code: -32602,
                 data: %{validation_errors: errors}
               }
             } = response

      assert "Field tags[1]: expected string, got 42" in errors
    end

    test "tools/call with invalid nested map field returns -32602" do
      request_tool(
        "validated_nested_tool",
        %{"query" => "hello", "filters" => %{"min_price" => "not a number"}},
        []
      )

      assert_receive {:conn, conn}
      assert conn.status == 200

      assert_receive {:response, 1, "message", response}

      assert %{
               jsonrpc: "2.0",
               id: 1,
               error: %{
                 code: -32602,
                 data: %{validation_errors: errors}
               }
             } = response

      assert Enum.any?(errors, &String.contains?(&1, "filters.min_price"))
    end

    test "tools/call with custom validator rejection returns -32602" do
      request_tool("validated_custom_tool", %{"query" => "ab"}, [])

      assert_receive {:conn, conn}
      assert conn.status == 200

      assert_receive {:response, 1, "message", response}

      assert %{
               jsonrpc: "2.0",
               id: 1,
               error: %{
                 code: -32602,
                 data: %{validation_errors: errors}
               }
             } = response

      assert Enum.any?(errors, &String.contains?(&1, "query"))
    end

    test "tools/call with raw-map input_schema does NOT validate (backwards compatible)" do
      # echo_tool uses raw map input_schema, should pass through without validation
      request_tool("echo_tool", %{"message" => 12345}, [])

      assert_receive {:conn, conn}
      assert conn.status == 200

      assert_receive {:response, 1, "message", response}
      # Should succeed even with wrong type - raw map schemas don't validate
      assert %{jsonrpc: "2.0", id: 1, result: %{content: _}} = response
    end
  end

  describe "Ecto-style aliases in build_field/3" do
    test "greater_than_or_equal_to: aliases to minimum:" do
      field = JSONSchema.build_field(:count, :integer, greater_than_or_equal_to: 1)
      assert field.minimum == 1

      # Direct minimum: still works
      field2 = JSONSchema.build_field(:count, :integer, minimum: 1)
      assert field2.minimum == 1

      # Explicit minimum: wins over alias
      field3 = JSONSchema.build_field(:count, :integer, minimum: 5, greater_than_or_equal_to: 1)
      assert field3.minimum == 5
    end

    test "less_than_or_equal_to: aliases to maximum:" do
      field = JSONSchema.build_field(:count, :integer, less_than_or_equal_to: 100)
      assert field.maximum == 100

      # Explicit maximum: wins over alias
      field2 = JSONSchema.build_field(:count, :integer, maximum: 50, less_than_or_equal_to: 100)
      assert field2.maximum == 50
    end

    test "explicit minimum: 0 is not overridden by alias" do
      field = JSONSchema.build_field(:count, :integer, minimum: 0, greater_than_or_equal_to: 5)
      assert field.minimum == 0

      field2 = JSONSchema.build_field(:count, :integer, maximum: 0, less_than_or_equal_to: 10)
      assert field2.maximum == 0
    end

    test "in: aliases to enum:" do
      field = JSONSchema.build_field(:status, :string, in: ["active", "inactive"])
      assert field.enum == ["active", "inactive"]

      # Explicit enum: wins over alias
      field2 = JSONSchema.build_field(:status, :string, enum: ["a"], in: ["a", "b"])
      assert field2.enum == ["a"]
    end

    test "format: ~r// aliases to pattern: string" do
      field = JSONSchema.build_field(:email, :string, format: ~r/@/)
      assert field.pattern == "@"

      # format: as string also works
      field2 = JSONSchema.build_field(:email, :string, format: "^[^@]+@")
      assert field2.pattern == "^[^@]+@"

      # Explicit pattern: wins over format:
      field3 = JSONSchema.build_field(:email, :string, pattern: "^x$", format: ~r/@/)
      assert field3.pattern == "^x$"
    end
  end

  describe "exclusive bounds (greater_than/less_than)" do
    test "build_field stores greater_than and less_than" do
      field = JSONSchema.build_field(:score, :number, greater_than: 0, less_than: 100)
      assert field.greater_than == 0
      assert field.less_than == 100
    end

    test "greater_than: rejects equal values, accepts strictly greater" do
      schema =
        JSONSchema.build_from_fields([
          JSONSchema.build_field(:score, :number, required: true, greater_than: 0)
        ])

      assert {:error, errors} = JSONSchema.validate(schema, %{"score" => 0})
      assert Enum.any?(errors, &String.contains?(&1, "must be greater than 0"))

      assert {:error, _} = JSONSchema.validate(schema, %{"score" => -1})

      assert {:ok, _} = JSONSchema.validate(schema, %{"score" => 1})
      assert {:ok, _} = JSONSchema.validate(schema, %{"score" => 0.001})
    end

    test "less_than: rejects equal values, accepts strictly less" do
      schema =
        JSONSchema.build_from_fields([
          JSONSchema.build_field(:score, :number, required: true, less_than: 10)
        ])

      assert {:error, errors} = JSONSchema.validate(schema, %{"score" => 10})
      assert Enum.any?(errors, &String.contains?(&1, "must be less than 10"))

      assert {:error, _} = JSONSchema.validate(schema, %{"score" => 11})

      assert {:ok, _} = JSONSchema.validate(schema, %{"score" => 9})
      assert {:ok, _} = JSONSchema.validate(schema, %{"score" => 9.999})
    end

    test "JSON Schema emits exclusiveMinimum and exclusiveMaximum" do
      schema =
        JSONSchema.build_from_fields([
          JSONSchema.build_field(:score, :number, greater_than: 0, less_than: 100)
        ])

      json = JSONSchema.to_json(schema)
      assert json.properties.score.exclusiveMinimum == 0
      assert json.properties.score.exclusiveMaximum == 100
    end
  end

  describe "exact length (length:)" do
    test "build_field stores length" do
      field = JSONSchema.build_field(:code, :string, length: 5)
      assert field.length == 5
    end

    test "length: validates exact string length" do
      schema =
        JSONSchema.build_from_fields([
          JSONSchema.build_field(:code, :string, required: true, length: 5)
        ])

      assert {:ok, _} = JSONSchema.validate(schema, %{"code" => "abcde"})

      assert {:error, errors} = JSONSchema.validate(schema, %{"code" => "abcd"})
      assert Enum.any?(errors, &String.contains?(&1, "length must be exactly 5"))

      assert {:error, errors} = JSONSchema.validate(schema, %{"code" => "abcdef"})
      assert Enum.any?(errors, &String.contains?(&1, "length must be exactly 5"))
    end

    test "length: validates exact array length" do
      schema =
        JSONSchema.build_from_fields([
          JSONSchema.build_field(:coords, {:array, :number}, required: true, length: 3)
        ])

      assert {:ok, _} = JSONSchema.validate(schema, %{"coords" => [1.0, 2.0, 3.0]})

      assert {:error, errors} = JSONSchema.validate(schema, %{"coords" => [1.0, 2.0]})
      assert Enum.any?(errors, &String.contains?(&1, "length must be exactly 3"))
    end

    test "JSON Schema emits minLength==maxLength for strings" do
      schema =
        JSONSchema.build_from_fields([
          JSONSchema.build_field(:code, :string, length: 5)
        ])

      json = JSONSchema.to_json(schema)
      assert json.properties.code.minLength == 5
      assert json.properties.code.maxLength == 5
    end

    test "JSON Schema emits minItems==maxItems for arrays" do
      schema =
        JSONSchema.build_from_fields([
          JSONSchema.build_field(:coords, {:array, :number}, length: 3)
        ])

      json = JSONSchema.to_json(schema)
      assert json.properties.coords.minItems == 3
      assert json.properties.coords.maxItems == 3
    end
  end

  describe "array length validation (min_length/max_length on arrays)" do
    test "min_length: on arrays validates array length" do
      schema =
        JSONSchema.build_from_fields([
          JSONSchema.build_field(:tags, {:array, :string}, required: true, min_length: 2)
        ])

      assert {:ok, _} = JSONSchema.validate(schema, %{"tags" => ["a", "b"]})
      assert {:ok, _} = JSONSchema.validate(schema, %{"tags" => ["a", "b", "c"]})

      assert {:error, errors} = JSONSchema.validate(schema, %{"tags" => ["a"]})
      assert Enum.any?(errors, &String.contains?(&1, "length"))
    end

    test "max_length: on arrays validates array length" do
      schema =
        JSONSchema.build_from_fields([
          JSONSchema.build_field(:tags, {:array, :string}, required: true, max_length: 3)
        ])

      assert {:ok, _} = JSONSchema.validate(schema, %{"tags" => ["a", "b", "c"]})

      assert {:error, errors} = JSONSchema.validate(schema, %{"tags" => ["a", "b", "c", "d"]})
      assert Enum.any?(errors, &String.contains?(&1, "length"))
    end

    test "JSON Schema emits minItems/maxItems for arrays" do
      schema =
        JSONSchema.build_from_fields([
          JSONSchema.build_field(:tags, {:array, :string}, min_length: 1, max_length: 10)
        ])

      json = JSONSchema.to_json(schema)
      assert json.properties.tags.minItems == 1
      assert json.properties.tags.maxItems == 10
      # Should NOT have minLength/maxLength (those are for strings)
      refute Map.has_key?(json.properties.tags, :minLength)
      refute Map.has_key?(json.properties.tags, :maxLength)
    end
  end

  describe "exclusion:" do
    test "build_field stores exclusion" do
      field = JSONSchema.build_field(:role, :string, exclusion: ["admin", "superuser"])
      assert field.exclusion == ["admin", "superuser"]
    end

    test "exclusion: rejects values in the exclusion list" do
      schema =
        JSONSchema.build_from_fields([
          JSONSchema.build_field(:role, :string,
            required: true,
            exclusion: ["admin", "superuser"]
          )
        ])

      assert {:ok, _} = JSONSchema.validate(schema, %{"role" => "user"})
      assert {:ok, _} = JSONSchema.validate(schema, %{"role" => "editor"})

      assert {:error, errors} = JSONSchema.validate(schema, %{"role" => "admin"})
      assert Enum.any?(errors, &String.contains?(&1, "must not be one of"))

      assert {:error, _} = JSONSchema.validate(schema, %{"role" => "superuser"})
    end

    test "exclusion: is NOT emitted in JSON Schema output" do
      schema =
        JSONSchema.build_from_fields([
          JSONSchema.build_field(:role, :string, exclusion: ["admin"])
        ])

      json = JSONSchema.to_json(schema)
      refute Map.has_key?(json.properties.role, :exclusion)
    end
  end

  describe "format: ~r// with validation" do
    test "format: ~r// validates string values" do
      schema =
        JSONSchema.build_from_fields([
          JSONSchema.build_field(:email, :string, required: true, format: ~r/@/)
        ])

      assert {:ok, _} = JSONSchema.validate(schema, %{"email" => "user@example.com"})

      assert {:error, errors} = JSONSchema.validate(schema, %{"email" => "nope"})
      assert Enum.any?(errors, &String.contains?(&1, "pattern"))
    end

    test "format: ~r// emits pattern in JSON Schema" do
      schema =
        JSONSchema.build_from_fields([
          JSONSchema.build_field(:email, :string, format: ~r/@/)
        ])

      json = JSONSchema.to_json(schema)
      assert json.properties.email.pattern == "@"
    end
  end
end
