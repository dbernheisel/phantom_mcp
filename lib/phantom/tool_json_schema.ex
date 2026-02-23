defmodule Phantom.Tool.JSONSchema do
  @moduledoc """
  JSON Schema for tool input and output schemas.

  Provides an Ecto-like DSL for defining input schemas that both generate
  JSON Schema for clients AND validate/default incoming params at dispatch time.

  ## Standalone usage

  Define reusable schemas as modules:

      defmodule MyApp.MCP.Schemas.Filters do
        use Phantom.Tool.JSONSchema

        input_schema do
          field :category, :string
          field :min_price, :number
        end
      end

  ## Router usage

      tool :search, description: "Search for stuff" do
        field :query, :string, required: true
        field :limit, :integer, default: 10
        field :tags, {:array, :string}
      end

  ## Type System

  | DSL type | Elixir guard | JSON Schema type |
  |----------|-------------|-----------------|
  | `:string` | `is_binary` | `"string"` |
  | `:integer` | `is_integer` | `"integer"` |
  | `:number` | `is_number` | `"number"` |
  | `:boolean` | `is_boolean` | `"boolean"` |
  | `{:array, subtype}` | `is_list` + validate each | `"array"` with `items` |
  | `:map` with `do` block | `is_map` + validate nested | `"object"` with `properties` |
  | `ModuleName` | delegate to module | delegate to module |
  """

  import Phantom.Utils

  @type field :: %{
          name: atom(),
          type: atom() | {:array, atom()} | module(),
          required: boolean(),
          default: any(),
          description: String.t() | nil,
          message: String.t() | nil,
          validate:
            (any() -> :ok | {:error, String.t()}) | {module(), atom(), list()} | atom() | nil,
          enum: list() | nil,
          minimum: number() | nil,
          maximum: number() | nil,
          greater_than: number() | nil,
          less_than: number() | nil,
          min_length: non_neg_integer() | nil,
          max_length: non_neg_integer() | nil,
          length: non_neg_integer() | nil,
          pattern: String.t() | nil,
          exclusion: list() | nil,
          children: [field()] | nil
        }

  @type t :: %__MODULE__{
          required: [String.t()],
          type: String.t(),
          properties: map(),
          fields: [field()] | nil
        }

  @type json :: %{
          required(:type) => String.t(),
          optional(:required) => [String.t()],
          optional(:properties) => map()
        }

  defstruct required: [], type: "object", properties: %{}, fields: nil

  @callback __input_schema__() :: t()

  defmacro __using__(_opts) do
    quote do
      @behaviour Phantom.Tool.JSONSchema
      import Phantom.Tool.JSONSchema, only: [input_schema: 1]
      @before_compile Phantom.Tool.JSONSchema
    end
  end

  defmacro __before_compile__(env) do
    input_schema = Module.get_attribute(env.module, :phantom_input_schema)

    quote do
      def __input_schema__ do
        unquote(Macro.escape(input_schema))
      end
    end
  end

  @doc """
  Define an input schema. Returns a `%JSONSchema{}` struct with validation
  metadata that is consumed by the following `tool` macro via the
  `@phantom_input_schema` attribute.

      input_schema do
        field :query, :string, required: true
        field :limit, :integer, default: 10
      end

      tool :search, description: "Search"
  """
  defmacro input_schema(do: block) do
    {defs, fields} = transform_block(block)

    quote do
      unquote_splicing(defs)

      @phantom_input_schema Phantom.Tool.JSONSchema.build_from_fields(unquote(fields))
    end
  end

  @doc false
  def transform_block({:__block__, _, exprs}) do
    {fields, defs} =
      Enum.map_reduce(exprs, [], fn expr, acc ->
        {field_ast, new_defs} = transform_field(expr)
        {field_ast, acc ++ new_defs}
      end)

    {defs, fields}
  end

  @doc false
  def transform_block(single_expr) do
    {field_ast, defs} = transform_field(single_expr)
    {defs, [field_ast]}
  end

  @doc false
  def transform_field({:field, _meta, [name, type]}) do
    ast =
      quote do
        Phantom.Tool.JSONSchema.build_field(unquote(name), unquote(type), [])
      end

    {ast, []}
  end

  @doc false
  def transform_field({:field, meta, [name, type, opts, block_opts]})
      when is_list(opts) and is_list(block_opts) do
    transform_field({:field, meta, [name, type, opts ++ block_opts]})
  end

  @doc false
  def transform_field({:field, _meta, [name, type, opts]}) when is_list(opts) do
    {block, opts} = Keyword.pop(opts, :do)
    {validate_ast, opts} = Keyword.pop(opts, :validate)

    if block do
      {nested_defs, nested_fields} = transform_block(block)

      field_ast =
        quote do
          Phantom.Tool.JSONSchema.build_field(
            unquote(name),
            :map,
            Keyword.put(unquote(opts), :children, unquote(nested_fields))
          )
        end

      {field_ast, nested_defs}
    else
      build_field_ast(name, type, opts, validate_ast)
    end
  end

  @doc false
  def build_field_ast(name, type, opts, nil) do
    ast =
      quote do
        Phantom.Tool.JSONSchema.build_field(unquote(name), unquote(type), unquote(opts))
      end

    {ast, []}
  end

  @doc false
  def build_field_ast(name, type, opts, validate_ast) do
    case classify_validator(validate_ast) do
      :anon_function ->
        {_, [{:counter, counter} | _], _} = Macro.unique_var(:v, __MODULE__)
        func_name = :"__phantom_validate_#{counter}__"

        def_ast =
          quote do
            @doc false
            def unquote(func_name)(value), do: unquote(validate_ast).(value)
          end

        field_ast =
          quote do
            Phantom.Tool.JSONSchema.build_field(
              unquote(name),
              unquote(type),
              [{:validate, {__MODULE__, unquote(func_name), []}} | unquote(opts)]
            )
          end

        {field_ast, [def_ast]}

      :local_function ->
        ast =
          quote do
            Phantom.Tool.JSONSchema.build_field(
              unquote(name),
              unquote(type),
              [{:validate, {__MODULE__, unquote(validate_ast), []}} | unquote(opts)]
            )
          end

        {ast, []}

      :passthrough ->
        ast =
          quote do
            Phantom.Tool.JSONSchema.build_field(
              unquote(name),
              unquote(type),
              [{:validate, unquote(validate_ast)} | unquote(opts)]
            )
          end

        {ast, []}
    end
  end

  @doc false
  def classify_validator({:fn, _, _}), do: :anon_function
  def classify_validator({:&, _, [{:/, _, [{{:., _, _}, _, _}, _]}]}), do: :passthrough
  def classify_validator({:&, _, _}), do: :anon_function
  def classify_validator(atom) when is_atom(atom), do: :local_function
  def classify_validator(_), do: :passthrough

  def build(nil), do: nil
  def build(%__MODULE__{} = schema), do: schema
  def build(attrs), do: struct!(__MODULE__, attrs)

  @doc "Build a `%JSONSchema{}` from a list of field maps, pre-computing JSON Schema properties."
  def build_from_fields(fields) when is_list(fields) do
    {properties, required} = fields_to_json_schema(fields)

    %__MODULE__{
      type: "object",
      required: required,
      properties: properties,
      fields: fields
    }
  end

  @doc "Build a field map from name, type, and opts."
  def build_field(name, type, opts \\ []) do
    opts = Keyword.new(opts)

    children =
      case Keyword.get(opts, :children) do
        nil -> nil
        %__MODULE__{fields: fields} -> fields
        list when is_list(list) -> list
      end

    # Ecto alias: format: ~r// or format: string → pattern:
    {format, opts} = Keyword.pop(opts, :format)

    pattern =
      case {Keyword.fetch(opts, :pattern), format} do
        {{:ok, explicit}, _} -> explicit
        {:error, %Regex{} = r} -> Regex.source(r)
        {:error, s} when is_binary(s) -> s
        {:error, nil} -> nil
      end

    # Ecto alias: in: → enum:
    {in_values, opts} = Keyword.pop(opts, :in)
    enum = Keyword.get(opts, :enum, in_values)

    # Ecto alias: greater_than_or_equal_to: → minimum:
    {gte, opts} = Keyword.pop(opts, :greater_than_or_equal_to)
    minimum = Keyword.get(opts, :minimum, gte)

    # Ecto alias: less_than_or_equal_to: → maximum:
    {lte, opts} = Keyword.pop(opts, :less_than_or_equal_to)
    maximum = Keyword.get(opts, :maximum, lte)

    %{
      name: name,
      type: type,
      required: Keyword.get(opts, :required, false),
      default: Keyword.get(opts, :default),
      description: Keyword.get(opts, :description),
      message: Keyword.get(opts, :message),
      validate: Keyword.get(opts, :validate),
      enum: enum,
      minimum: minimum,
      maximum: maximum,
      greater_than: Keyword.get(opts, :greater_than),
      less_than: Keyword.get(opts, :less_than),
      min_length: Keyword.get(opts, :min_length),
      max_length: Keyword.get(opts, :max_length),
      length: Keyword.get(opts, :length),
      pattern: pattern,
      exclusion: Keyword.get(opts, :exclusion),
      children: children
    }
  end

  def to_json(nil), do: %{required: [], type: "object", properties: %{}}

  def to_json(%__MODULE__{} = schema) do
    remove_nils(%{
      required: schema.required,
      type: schema.type,
      properties: schema.properties
    })
  end

  @doc "Passthrough when no schema is present, or when schema has no DSL fields."
  def maybe_validate(nil, params), do: {:ok, params}
  def maybe_validate(%__MODULE__{fields: nil}, params), do: {:ok, params}

  def maybe_validate(%__MODULE__{fields: fields}, params) when is_list(fields),
    do: validate(fields, params)

  @doc """
  Validate params against the field definitions. Returns `{:ok, params_with_defaults}`
  or `{:error, [error_messages]}`.
  """
  def validate(schema_or_fields, params, handler \\ nil)

  def validate(%__MODULE__{fields: fields}, params, handler) when is_list(fields),
    do: validate(fields, params, handler)

  def validate(fields, params, handler) when is_list(fields) do
    {params, errors} = validate_fields(fields, params, "", handler)

    case errors do
      [] -> {:ok, params}
      errors -> {:error, Enum.reverse(errors)}
    end
  end

  defp validate_fields(fields, params, prefix, handler) do
    Enum.reduce(fields, {params, []}, fn field, {params, errors} ->
      key = to_string(field.name)
      field_path = if prefix == "", do: key, else: "#{prefix}.#{key}"

      case Map.fetch(params, key) do
        {:ok, value} ->
          case validate_field(field, value, field_path, handler) do
            :ok -> {params, errors}
            {:error, new_errors} -> {params, new_errors ++ errors}
          end

        :error ->
          cond do
            field.required ->
              {params, ["Missing required field: #{field_path}" | errors]}

            field.default != nil ->
              {Map.put(params, key, field.default), errors}

            true ->
              {params, errors}
          end
      end
    end)
  end

  defp validate_field(field, value, path, handler) do
    case do_validate_field(field, value, path, handler) do
      :ok ->
        :ok

      {:error, _} when not is_nil(field.message) ->
        {:error, ["Field #{path}: #{field.message}"]}

      error ->
        error
    end
  end

  defp do_validate_field(field, value, path, handler) do
    with :ok <- check_type(field.type, value, path, handler) do
      []
      |> check_enum(field.enum, value, path)
      |> check_exclusion(field.exclusion, value, path)
      |> check_minimum(field.minimum, value, path)
      |> check_maximum(field.maximum, value, path)
      |> check_greater_than(field.greater_than, value, path)
      |> check_less_than(field.less_than, value, path)
      |> check_length(field.length, value, path)
      |> check_min_length(field.min_length, value, path)
      |> check_max_length(field.max_length, value, path)
      |> check_pattern(field.pattern, value, path)
      |> check_nested(field, value, path)
      |> check_validate(field.validate, value, path, handler)
      |> case do
        [] -> :ok
        errors -> {:error, Enum.reverse(errors)}
      end
    end
  end

  defp check_type(:string, value, _path, _handler) when is_binary(value), do: :ok

  defp check_type(:string, value, path, _handler),
    do: {:error, ["Field #{path}: expected string, got #{inspect(value)}"]}

  defp check_type(:integer, value, _path, _handler) when is_integer(value), do: :ok

  defp check_type(:integer, value, path, _handler),
    do: {:error, ["Field #{path}: expected integer, got #{inspect(value)}"]}

  defp check_type(:number, value, _path, _handler) when is_number(value), do: :ok

  defp check_type(:number, value, path, _handler),
    do: {:error, ["Field #{path}: expected number, got #{inspect(value)}"]}

  defp check_type(:boolean, value, _path, _handler) when is_boolean(value), do: :ok

  defp check_type(:boolean, value, path, _handler),
    do: {:error, ["Field #{path}: expected boolean, got #{inspect(value)}"]}

  defp check_type({:array, subtype}, value, path, handler) when is_list(value) do
    errors =
      value
      |> Enum.with_index()
      |> Enum.reduce([], fn {elem, idx}, errors ->
        elem_path = "#{path}[#{idx}]"

        case check_type(subtype, elem, elem_path, handler) do
          :ok -> errors
          {:error, new_errors} -> new_errors ++ errors
        end
      end)

    case errors do
      [] -> :ok
      errors -> {:error, Enum.reverse(errors)}
    end
  end

  defp check_type({:array, _subtype}, value, path, _handler),
    do: {:error, ["Field #{path}: expected array, got #{inspect(value)}"]}

  defp check_type(:map, value, _path, _handler) when is_map(value), do: :ok

  defp check_type(:map, value, path, _handler),
    do: {:error, ["Field #{path}: expected map, got #{inspect(value)}"]}

  defp check_type(nil, _value, _path, _handler), do: :ok

  defp check_type(module, value, path, handler) when is_atom(module) do
    if function_exported?(module, :__input_schema__, 0) do
      schema = module.__input_schema__()

      do_validate_field(
        build_field(:_, nil, children: schema.fields),
        value,
        path,
        handler
      )
    else
      {:error, ["Field #{path}: unknown type #{inspect(module)}"]}
    end
  end

  defp check_enum(errors, nil, _value, _path), do: errors

  defp check_enum(errors, allowed, value, path) do
    if value in allowed do
      errors
    else
      [
        "Field #{path}: value #{inspect(value)} not in allowed values: #{inspect(allowed)}"
        | errors
      ]
    end
  end

  defp check_exclusion(errors, nil, _value, _path), do: errors

  defp check_exclusion(errors, excluded, value, path) do
    if value in excluded do
      ["Field #{path}: must not be one of #{inspect(excluded)}" | errors]
    else
      errors
    end
  end

  defp check_minimum(errors, nil, _value, _path), do: errors

  defp check_minimum(errors, min, value, path) when is_number(value) do
    if value >= min do
      errors
    else
      ["Field #{path}: value #{inspect(value)} is less than minimum #{min}" | errors]
    end
  end

  defp check_minimum(errors, _min, _value, _path), do: errors

  defp check_maximum(errors, nil, _value, _path), do: errors

  defp check_maximum(errors, max, value, path) when is_number(value) do
    if value <= max do
      errors
    else
      ["Field #{path}: value #{inspect(value)} is greater than maximum #{max}" | errors]
    end
  end

  defp check_maximum(errors, _max, _value, _path), do: errors

  defp check_greater_than(errors, nil, _, _), do: errors

  defp check_greater_than(errors, threshold, value, path) when is_number(value) do
    if value > threshold do
      errors
    else
      ["Field #{path}: must be greater than #{threshold}" | errors]
    end
  end

  defp check_greater_than(errors, _, _, _), do: errors

  defp check_less_than(errors, nil, _, _), do: errors

  defp check_less_than(errors, threshold, value, path) when is_number(value) do
    if value < threshold do
      errors
    else
      ["Field #{path}: must be less than #{threshold}" | errors]
    end
  end

  defp check_less_than(errors, _, _, _), do: errors

  defp check_length(errors, nil, _, _), do: errors

  defp check_length(errors, exact, value, path) when is_binary(value) do
    len = String.length(value)

    if len == exact do
      errors
    else
      ["Field #{path}: length must be exactly #{exact}, got #{len}" | errors]
    end
  end

  defp check_length(errors, exact, value, path) when is_list(value) do
    len = length(value)

    if len == exact do
      errors
    else
      ["Field #{path}: length must be exactly #{exact}, got #{len}" | errors]
    end
  end

  defp check_length(errors, _, _, _), do: errors

  defp check_min_length(errors, nil, _value, _path), do: errors

  defp check_min_length(errors, min, value, path) when is_binary(value) do
    len = String.length(value)

    if len >= min do
      errors
    else
      ["Field #{path}: string length #{len} is less than minimum #{min}" | errors]
    end
  end

  defp check_min_length(errors, min, value, path) when is_list(value) do
    len = length(value)

    if len >= min do
      errors
    else
      ["Field #{path}: length #{len} is less than minimum #{min}" | errors]
    end
  end

  defp check_min_length(errors, _min, _value, _path), do: errors

  defp check_max_length(errors, nil, _value, _path), do: errors

  defp check_max_length(errors, max, value, path) when is_binary(value) do
    len = String.length(value)

    if len <= max do
      errors
    else
      ["Field #{path}: string length #{len} is greater than maximum #{max}" | errors]
    end
  end

  defp check_max_length(errors, max, value, path) when is_list(value) do
    len = length(value)

    if len <= max do
      errors
    else
      ["Field #{path}: length #{len} is greater than maximum #{max}" | errors]
    end
  end

  defp check_max_length(errors, _max, _value, _path), do: errors

  defp check_pattern(errors, nil, _value, _path), do: errors

  defp check_pattern(errors, pattern, value, path) when is_binary(value) do
    case Regex.compile(pattern) do
      {:ok, regex} ->
        if Regex.match?(regex, value) do
          errors
        else
          ["Field #{path}: value does not match pattern #{pattern}" | errors]
        end

      _ ->
        errors
    end
  end

  defp check_pattern(errors, _pattern, _value, _path), do: errors

  defp check_nested(errors, %{children: children}, value, path)
       when is_list(children) and is_map(value) do
    {_params, nested_errors} = validate_fields(children, value, path, nil)
    nested_errors ++ errors
  end

  defp check_nested(errors, _field, _value, _path), do: errors

  defp check_validate(errors, nil, _value, _path, _handler), do: errors

  defp check_validate(errors, fun, value, path, _handler) when is_function(fun, 1) do
    case fun.(value) do
      :ok -> errors
      {:error, reason} -> ["Field #{path}: #{reason}" | errors]
    end
  end

  defp check_validate(errors, {m, f, a}, value, path, _handler) do
    case apply(m, f, [value | a]) do
      :ok -> errors
      {:error, reason} -> ["Field #{path}: #{reason}" | errors]
    end
  end

  defp check_validate(errors, atom, value, path, handler)
       when is_atom(atom) and not is_nil(handler) do
    case apply(handler, atom, [value]) do
      :ok -> errors
      {:error, reason} -> ["Field #{path}: #{reason}" | errors]
    end
  end

  defp check_validate(errors, _atom, _value, _path, _handler), do: errors

  defp fields_to_json_schema(fields) do
    Enum.reduce(fields, {%{}, []}, fn field, {props, required} ->
      prop = field_to_json_property(field)
      props = Map.put(props, field.name, prop)

      required =
        if field.required do
          required ++ [to_string(field.name)]
        else
          required
        end

      {props, required}
    end)
  end

  defp field_to_json_property(field) do
    base = type_to_json(field.type, field)

    base
    |> maybe_put(:description, field.description)
    |> maybe_put(:enum, field.enum)
    |> maybe_put(:minimum, field.minimum)
    |> maybe_put(:maximum, field.maximum)
    |> maybe_put(:exclusiveMinimum, field.greater_than)
    |> maybe_put(:exclusiveMaximum, field.less_than)
    |> put_length_constraints(field)
    |> maybe_put(:pattern, field.pattern)
  end

  defp put_length_constraints(json, field) do
    case field.type do
      {:array, _} ->
        json
        |> maybe_put(:minItems, field.length || field.min_length)
        |> maybe_put(:maxItems, field.length || field.max_length)

      _ ->
        json
        |> maybe_put(:minLength, field.length || field.min_length)
        |> maybe_put(:maxLength, field.length || field.max_length)
    end
  end

  defp type_to_json(:string, _field), do: %{type: "string"}
  defp type_to_json(:integer, _field), do: %{type: "integer"}
  defp type_to_json(:number, _field), do: %{type: "number"}
  defp type_to_json(:boolean, _field), do: %{type: "boolean"}

  defp type_to_json({:array, subtype}, _field) do
    %{type: "array", items: type_to_json(subtype, nil)}
  end

  defp type_to_json(:map, %{children: children}) when is_list(children) do
    {properties, required} = fields_to_json_schema(children)
    result = %{type: "object", properties: properties}
    if required == [], do: result, else: Map.put(result, :required, required)
  end

  defp type_to_json(:map, _field), do: %{type: "object"}

  defp type_to_json(module, _field) when is_atom(module) do
    if function_exported?(module, :__input_schema__, 0) do
      schema = module.__input_schema__()
      to_json(schema)
    else
      %{type: "object"}
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, []), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
