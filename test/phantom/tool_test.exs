defmodule Phantom.ToolTest do
  use ExUnit.Case, async: true

  alias Phantom.Tool

  describe "input_required/1" do
    test "returns the MCP 2026-07-28 input_required shape" do
      input_requests = %{
        "choice" => %{method: "elicitation/create", params: %{mode: "form"}}
      }

      state = %{step: :resolve, candidates: ["a", "b"]}

      assert %{
               resultType: "input_required",
               inputRequests: ^input_requests,
               requestState: ^state
             } = Tool.input_required(input_requests: input_requests, state: state)
    end

    test "stores the request_state as a raw term (encryption happens at the Plug boundary)" do
      state = %{some: "data", nested: %{a: 1}}

      assert %{requestState: ^state} =
               Tool.input_required(
                 input_requests: %{"choice" => %{method: "elicitation/create", params: %{}}},
                 state: state
               )
    end

    test "accepts requestState without inputRequests" do
      assert %{resultType: "input_required", requestState: %{}} =
               Tool.input_required(state: %{})
    end

    test "accepts inputRequests without requestState" do
      input_requests = %{"choice" => %{method: "elicitation/create", params: %{}}}

      assert %{resultType: "input_required", inputRequests: ^input_requests} =
               Tool.input_required(input_requests: input_requests)
    end

    test "raises when neither requestState nor inputRequests is present" do
      assert_raise ArgumentError, fn -> Tool.input_required([]) end
    end
  end

  describe "response/1 passes input_required through unchanged" do
    test "does not wrap an input_required result in :content" do
      result =
        Tool.input_required(
          input_requests: %{"choice" => %{method: "elicitation/create", params: %{}}},
          state: %{a: 1}
        )

      assert Tool.response(result) == result
      refute Map.has_key?(Tool.response(result), :content)
    end
  end
end
