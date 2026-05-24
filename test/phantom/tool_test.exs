defmodule Phantom.ToolTest do
  use ExUnit.Case, async: true

  alias Phantom.Tool

  describe "input_required/1" do
    test "returns the MCP 2026-07-28 inputRequired shape" do
      input_requests = [%{name: "choice", schema: %{type: "string"}}]
      state = %{step: :resolve, candidates: ["a", "b"]}

      assert %{
               resultType: "inputRequired",
               inputRequests: ^input_requests,
               requestState: ^state
             } = Tool.input_required(input_requests: input_requests, request_state: state)
    end

    test "stores the request_state as a raw term (encryption happens at the Plug boundary)" do
      state = %{some: "data", nested: %{a: 1}}

      assert %{requestState: ^state} =
               Tool.input_required(input_requests: [], request_state: state)
    end

    test "raises when :input_requests is missing" do
      assert_raise KeyError, fn ->
        Tool.input_required(request_state: %{})
      end
    end

    test "raises when :request_state is missing" do
      assert_raise KeyError, fn ->
        Tool.input_required(input_requests: [])
      end
    end
  end

  describe "response/1 passes inputRequired through unchanged" do
    test "does not wrap an inputRequired result in :content" do
      result = Tool.input_required(input_requests: [], request_state: %{a: 1})

      assert Tool.response(result) == result
      refute Map.has_key?(Tool.response(result), :content)
    end
  end
end
