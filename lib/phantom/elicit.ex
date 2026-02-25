defmodule Phantom.Elicit do
  @moduledoc """
  The Model Context Protocol (MCP) provides a standardized way for
  servers to request additional information from users through the
  client during interactions. This flow allows clients to maintain
  control over user interactions and data sharing while enabling
  servers to gather necessary information dynamically. Servers
  request structured data from users with JSON schemas to validate
  responses.

  https://modelcontextprotocol.io/specification/2025-06-18/client/elicitation

  ```mermaid
  sequenceDiagram
      participant User
      participant Client
      participant Server

      Note over Server,Client: Server initiates elicitation
      Server->>Client: elicitation/create

      Note over Client,User: Human interaction
      Client->>User: Present elicitation UI
      User-->>Client: Provide requested information

      Note over Server,Client: Complete request
      Client-->>Server: Return user response

      Note over Server: Continue processing with new information
  ```

  ## Form mode

  Form mode presents a structured form to the user within the client.
  The server defines the schema and the client renders it as a form.
  This is the default mode and works with any client that declares
  elicitation support.

  Build a form elicitation with `build/1` (or `form/1`) and send it
  with `Phantom.Session.elicit/3`:

      @elicit_name Phantom.Elicit.build(%{
        message: "What is your info?",
        requested_schema: [
          %{type: :string, name: "name", required: true, title: "Your name"},
          %{type: :string, name: "email", required: true, title: "Email", format: :email},
          %{type: :enum, name: "role", required: true, title: "Role",
            enum: [{"dev", "Developer"}, {"pm", "Product Manager"}]}
        ]
      })

      def my_tool(params, session) do
        case Phantom.Session.elicit(session, @elicit_name) do
          {:ok, %{"action" => "accept", "content" => content}} ->
            {:reply, Tool.text("Hello \#{content["name"]}"), session}

          {:ok, _rejected} ->
            {:reply, Tool.error("Rejected"), session}

          :not_supported ->
            # Client doesn't support elicitation; use a fallback
            {:reply, Tool.text("Hello stranger"), session}

          :timeout -> {:reply, Tool.error("Timed out"), session}
          :error -> {:reply, Tool.error("Failed"), session}
        end
      end

  ### Supported property types

  - `:string` — options: `:min_length`, `:max_length`, `:pattern` (string or `Regex`), `:format` (`:email`, `:uri`, `:date`, `:date_time`)
  - `:boolean` — options: `:default`
  - `:number` / `:integer` — options: `:minimum`, `:maximum`
  - `:enum` — options: `:enum` (list of values or `{value, title}` tuples), `:multi` (boolean), `:min`, `:max`

  All property types accept `:name`, `:required`, `:title`, and `:description`.

  ## URL mode

  URL mode directs the user to an external URL (e.g., an OAuth flow
  or a custom form hosted by your application). The client opens
  the URL in a browser and waits for the server to signal completion.

  > #### Client support {: .info}
  >
  > Cursor supports elicitation (both form and URL mode). Claude
  > Desktop does not support elicitation at this time.

  This mode requires two identifiers:

  - **JSON-RPC `request_id`** — managed automatically by Phantom. The
    client includes this in its JSON-RPC response to unblock the
    waiting `Phantom.Session.elicit/3` call.
  - **`elicitation_id`** — an application-level identifier you provide.
    When the user completes the external flow, your backend calls
    `Phantom.Tracker.notify_elicitation_complete/1` with this ID to
    notify the client that the URL workflow is finished.

  ```mermaid
  sequenceDiagram
      participant Server
      participant Client
      participant Browser
      participant App as Your App (URL)

      Server->>Client: elicitation/create (mode: url, elicitationId)
      Client->>Browser: Open URL
      Browser->>App: User completes flow
      App->>Server: Flow complete
      Server->>Client: notifications/elicitation/complete (elicitationId)
      Client-->>Server: JSON-RPC response (action: accept)
  ```

  The `elicitation_id` must be embedded in the URL so that your
  backend can identify which elicitation to complete when the user
  finishes the external flow. Generate the ID yourself, include
  it in the URL, and use `Phantom.Session.elicit/3` with `url/1`:

      def my_tool(params, session) do
        elicitation_id = UUIDv7.generate()
        url = "https://example.com/oauth?elicitation_id=\#{elicitation_id}"

        elicitation = Phantom.Elicit.url(%{
          message: "Please authenticate",
          url: url,
          elicitation_id: elicitation_id
        })

        case Phantom.Session.elicit(session, elicitation) do
          {:ok, %{"action" => "accept", "content" => content}} ->
            {:reply, Tool.text("Authenticated"), session}

          {:ok, _rejected} ->
            {:reply, Tool.error("Auth rejected"), session}

          :not_supported ->
            {:reply, Tool.error("URL elicitation not supported"), session}

          :timeout -> {:reply, Tool.error("Timed out"), session}
          :error -> {:reply, Tool.error("Failed"), session}
        end
      end

  Then in your callback controller, extract the ID and notify:

      def callback(conn, %{"elicitation_id" => elicitation_id}) do
        Phantom.Tracker.notify_elicitation_complete(elicitation_id)
        # Render a success page for the user
      end

  > #### URL mode client support {: .warning}
  >
  > URL mode requires the client to advertise `"url"` in its
  > elicitation capabilities (e.g., `elicitation: %{"url" => %{}}`).
  > If the client only sends `elicitation: %{}`, URL mode returns
  > `:not_supported` while form mode still works.

  ## Returning `{:elicitation_required, elicitations}`

  For tools that cannot proceed without user interaction, you can
  return `{:elicitation_required, elicitations}` directly from
  the tool handler. This returns a JSON-RPC error with code `-32042`
  containing the elicitation specs, allowing the client to initiate
  the flow:

      def my_tool(_params, _session) do
        {:elicitation_required, [
          Phantom.Elicit.url(%{
            message: "Please authenticate first",
            url: "https://example.com/oauth?elicitation_id=unique-id",
            elicitation_id: "unique-id"
          })
        ]}
      end
  """

  @enforce_keys ~w[message]a

  defstruct [:message, :requested_schema, :url, :elicitation_id, mode: :form]

  @type string_property :: %{
          name: String.t(),
          required: boolean(),
          type: :string,
          title: String.t(),
          description: String.t(),
          min_length: pos_integer(),
          max_length: pos_integer(),
          pattern: String.t() | Regex.t(),
          format: :email | :uri | :date | :datetime
        }

  @type enum_property :: %{
          name: String.t(),
          required: boolean(),
          type: :enum,
          title: String.t(),
          description: String.t(),
          enum: [String.t() | {value :: String.t(), title :: String.t()}],
          multi: boolean(),
          min: pos_integer(),
          max: pos_integer()
        }

  @type boolean_property :: %{
          name: String.t(),
          required: boolean(),
          type: :boolean,
          title: String.t(),
          description: String.t(),
          default: boolean()
        }

  @type number_property :: %{
          name: String.t(),
          required: boolean(),
          type: :number | :integer,
          title: String.t(),
          description: String.t(),
          minimum: pos_integer(),
          maximum: pos_integer()
        }

  @type t :: %__MODULE__{
          message: String.t(),
          mode: :form | :url,
          url: String.t() | nil,
          elicitation_id: String.t() | nil,
          requested_schema: [
            number_property() | boolean_property() | enum_property() | string_property()
          ]
        }

  @type json :: %{
          message: String.t(),
          requestedSchema: %{
            type: String.t(),
            required: [String.t()],
            properties: %{String.t() => map()}
          }
        }

  @spec build(%{
          message: String.t(),
          requested_schema: [
            number_property() | boolean_property() | enum_property() | string_property()
          ]
        }) :: t
  def build(attrs), do: form(attrs)

  @doc "Build a form mode elicitation"
  def form(attrs) do
    %{struct!(__MODULE__, attrs) |
      mode: :form,
      requested_schema: attrs[:requested_schema] |> List.wrap() |> Enum.map(&build_property/1)
    }
  end

  @doc "Build a URL mode elicitation"
  @spec url(%{message: String.t(), url: String.t(), elicitation_id: String.t()}) :: t
  def url(attrs) do
    %__MODULE__{
      mode: :url,
      message: Map.fetch!(attrs, :message),
      url: Map.fetch!(attrs, :url),
      elicitation_id: Map.fetch!(attrs, :elicitation_id)
    }
  end

  defp build_property(%{type: :string} = attrs) do
    attrs =
      Map.take(
        attrs,
        ~w[name required type title description min_length max_length pattern format]a
      )

    if format = attrs[:format] do
      format in ~w[email uri date date_time]a || raise "Invalid format in string property"
    end

    attrs
  end

  defp build_property(%{type: :enum} = attrs) do
    Map.take(attrs, ~w[name required type title description enum multi min max]a)
  end

  defp build_property(%{type: :boolean} = attrs) do
    Map.take(
      attrs,
      ~w[name required type title description default]a
    )
  end

  @integer ~w[integer number]a
  defp build_property(%{type: type} = attrs) when type in @integer do
    Map.take(
      attrs,
      ~w[name required type title description minimum maximum]a
    )
  end

  def to_json(%__MODULE__{mode: :url} = elicit) do
    %{
      mode: "url",
      message: elicit.message,
      url: elicit.url,
      elicitationId: elicit.elicitation_id
    }
  end

  def to_json(%__MODULE__{} = elicit) do
    %{
      mode: "form",
      message: elicit.message,
      requestedSchema: %{
        type: "object",
        required:
          Enum.reduce(elicit.requested_schema, [], fn property, acc ->
            if property.required, do: [property.name | acc], else: acc
          end),
        properties:
          Enum.reduce(elicit.requested_schema, %{}, fn property, acc ->
            property = Map.drop(property, [:required])
            {name, attrs} = Map.pop(property, :name)

            Map.put(acc, name, property_to_json(attrs))
          end)
      }
    }
  end

  defp property_to_json(%{type: :enum, enum: values} = attrs) do
    multi? = Map.get(attrs, :multi, false)
    titled? = match?([{_, _} | _], values)

    base =
      attrs
      |> Map.take(~w[title description]a)
      |> Enum.into(%{}, fn {k, v} -> {k, v} end)

    case {multi?, titled?} do
      {false, false} ->
        Map.merge(base, %{type: "string", enum: values})

      {false, true} ->
        Map.merge(base, %{
          type: "string",
          oneOf: Enum.map(values, fn {v, t} -> %{const: v, title: t} end)
        })

      {true, false} ->
        Map.merge(base, %{
          type: "array",
          items: %{type: "string", enum: values}
        })
        |> maybe_put(:minItems, attrs[:min])
        |> maybe_put(:maxItems, attrs[:max])

      {true, true} ->
        Map.merge(base, %{
          type: "array",
          items: %{oneOf: Enum.map(values, fn {v, t} -> %{const: v, title: t} end)}
        })
        |> maybe_put(:minItems, attrs[:min])
        |> maybe_put(:maxItems, attrs[:max])
    end
  end

  defp property_to_json(attrs) do
    Enum.reduce(attrs, %{}, fn
      {:min_length, v}, acc -> Map.put(acc, :minLength, v)
      {:max_length, v}, acc -> Map.put(acc, :maxLength, v)
      {:pattern, %Regex{} = v}, acc -> Map.put(acc, :pattern, Regex.source(v))
      {:format, :date_time}, acc -> Map.put(acc, :format, "date-time")
      {k, v}, acc -> Map.put(acc, k, v)
    end)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
