defmodule Phantom.TasksTest do
  use ExUnit.Case, async: true

  alias Phantom.Tasks

  @created_at ~U[2025-11-25 10:30:00Z]
  @updated_at ~U[2025-11-25 10:50:00Z]

  defp attrs(overrides \\ []) do
    Keyword.merge(
      [
        id: "786512e2-9e0d-44bd-8f29-789f320fe840",
        status: :working,
        created_at: @created_at,
        last_updated_at: @updated_at,
        ttl_ms: 3_600_000,
        poll_interval_ms: 5_000
      ],
      overrides
    )
  end

  describe "new/1" do
    test "builds a working task" do
      assert %Tasks{id: "786512e2-9e0d-44bd-8f29-789f320fe840", status: :working} =
               Tasks.new(attrs())
    end

    test "accepts a map and a status string, as loaded from a database" do
      task =
        Tasks.new(
          attrs()
          |> Map.new()
          |> Map.put(:status, "input_required")
          |> Map.put(:input_requests, %{"a" => %{method: "elicitation/create", params: %{}}})
        )

      assert task.status == :input_required
    end

    test "defaults last_updated_at to created_at and ttl_ms to unlimited" do
      task = Tasks.new(id: "t", status: :working, created_at: @created_at)
      assert task.last_updated_at == @created_at
      assert task.ttl_ms == nil
    end

    test "rejects an unknown status" do
      assert_raise ArgumentError, ~r/status/, fn -> Tasks.new(attrs(status: :done)) end
      assert_raise ArgumentError, ~r/status/, fn -> Tasks.new(attrs(status: "done")) end
    end

    test "requires an id and created_at" do
      assert_raise ArgumentError, ~r/:id/, fn -> Tasks.new(attrs(id: nil)) end
      assert_raise ArgumentError, ~r/:id/, fn -> Tasks.new(attrs(id: "")) end
      assert_raise ArgumentError, ~r/:created_at/, fn -> Tasks.new(attrs(created_at: nil)) end

      assert_raise ArgumentError, ~r/:last_updated_at/, fn ->
        Tasks.new(attrs(last_updated_at: "2025-11-25T10:50:00Z"))
      end
    end

    test "requires a result when completed" do
      assert_raise ArgumentError, ~r/:result/, fn -> Tasks.new(attrs(status: :completed)) end
    end

    test "requires a JSON-RPC error when failed" do
      assert_raise ArgumentError, ~r/:error/, fn -> Tasks.new(attrs(status: :failed)) end

      assert_raise ArgumentError, ~r/:error/, fn ->
        Tasks.new(attrs(status: :failed, error: %{message: "no code"}))
      end
    end

    test "requires input requests when input_required" do
      assert_raise ArgumentError, ~r/:input_requests/, fn ->
        Tasks.new(attrs(status: :input_required))
      end

      assert_raise ArgumentError, ~r/:input_requests/, fn ->
        Tasks.new(attrs(status: :input_required, input_requests: %{}))
      end
    end

    test "rejects negative or non-integer durations" do
      assert_raise ArgumentError, ~r/:ttl_ms/, fn -> Tasks.new(attrs(ttl_ms: -1)) end

      assert_raise ArgumentError, ~r/:poll_interval_ms/, fn ->
        Tasks.new(attrs(poll_interval_ms: 1.5))
      end
    end

    test "converts Phantom.Elicit input requests" do
      elicit =
        Phantom.Elicit.form(%{
          message: "Please enter your name.",
          requested_schema: [%{name: "name", type: :string, required: true}]
        })

      task = Tasks.new(attrs(status: :input_required, input_requests: %{"name" => elicit}))

      assert %{"name" => %{method: "elicitation/create", params: %{mode: "form"}}} =
               task.input_requests
    end
  end

  describe "encoding a task changed with struct update syntax" do
    test "validates it" do
      task = Tasks.new(attrs())

      assert_raise ArgumentError, ~r/:result/, fn ->
        Tasks.to_json(%{task | status: :completed})
      end
    end

    test "normalizes a status string" do
      task = Tasks.new(attrs())
      assert Tasks.to_json(%{task | status: "cancelled"}).status == "cancelled"
      assert Tasks.to_create_result(%{task | status: "cancelled"}).status == "cancelled"
    end
  end

  describe "generate_id/0" do
    test "is URL-safe and unique" do
      id = Tasks.generate_id()
      assert id =~ ~r/^[A-Za-z0-9_-]{43}$/
      refute id == Tasks.generate_id()
    end
  end

  describe "to_json/1" do
    test "encodes a working task as in the spec" do
      assert Tasks.to_json(Tasks.new(attrs(status_message: "The operation is now in progress."))) ==
               %{
                 taskId: "786512e2-9e0d-44bd-8f29-789f320fe840",
                 status: "working",
                 statusMessage: "The operation is now in progress.",
                 createdAt: "2025-11-25T10:30:00Z",
                 lastUpdatedAt: "2025-11-25T10:50:00Z",
                 ttlMs: 3_600_000,
                 pollIntervalMs: 5_000
               }
    end

    test "keeps ttlMs as null when unlimited and omits a missing poll interval" do
      json = Tasks.to_json(Tasks.new(attrs(ttl_ms: nil, poll_interval_ms: nil)))
      assert Map.fetch!(json, :ttlMs) == nil
      refute Map.has_key?(json, :pollIntervalMs)
    end

    test "inlines the input requests when input_required" do
      request = %{
        method: "elicitation/create",
        params: %{mode: "form", message: "Please enter your name."}
      }

      json =
        Tasks.to_json(
          Tasks.new(attrs(status: :input_required, input_requests: %{"name" => request}))
        )

      assert json.status == "input_required"
      assert json.inputRequests == %{"name" => request}
    end

    test "inlines the result when completed" do
      result = %{content: [%{type: "text", text: "Hello, Luca!"}], isError: false}
      json = Tasks.to_json(Tasks.new(attrs(status: :completed, result: result)))
      assert json.status == "completed"
      assert json.result == result
      refute Map.has_key?(json, :inputRequests)
    end

    test "inlines the error when failed" do
      error = %{code: -32603, message: "API rate limit exceeded"}
      json = Tasks.to_json(Tasks.new(attrs(status: :failed, error: error)))
      assert json.status == "failed"
      assert json.error == error
    end

    test "omits status-specific fields for other statuses" do
      json =
        Tasks.to_json(
          Tasks.new(
            attrs(
              status: :cancelled,
              result: %{content: []},
              error: %{code: -32603, message: "x"},
              input_requests: %{"a" => %{method: "elicitation/create", params: %{}}}
            )
          )
        )

      assert json.status == "cancelled"
      refute Map.has_key?(json, :result)
      refute Map.has_key?(json, :error)
      refute Map.has_key?(json, :inputRequests)
    end
  end
end
