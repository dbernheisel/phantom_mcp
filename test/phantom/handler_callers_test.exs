defmodule Phantom.HandlerCallersTest do
  use ExUnit.Case, async: true

  defmodule Router do
    use Phantom.Router, name: "HandlerCallers", vsn: "1.0"

    require Phantom.Prompt, as: Prompt
    alias Phantom.Tool

    tool :stubbed_tool, description: "Replies with a stubbed HTTP response"
    prompt :stubbed_prompt, description: "Replies with a stubbed HTTP response"

    def stubbed_tool(_params, session) do
      {:reply, Tool.text(fetch_stub()), session}
    end

    def stubbed_prompt(_params, session) do
      {:reply, Prompt.response(user: Prompt.text(fetch_stub())), session}
    end

    defp fetch_stub, do: Req.get!(plug: {Req.Test, __MODULE__}, retry: false).body
  end

  import Phantom.Test

  setup do
    Phantom.Test.start(router: Router)
    Req.Test.stub(Router, &Req.Test.text(&1, "stubbed"))
    {:ok, session: build_session(Router)}
  end

  test "a tool handler can use stubs owned by the calling test", %{session: session} do
    session
    |> call_tool(:stubbed_tool, %{})
    |> assert_tool_text("stubbed")
  end

  test "a prompt handler can use stubs owned by the calling test", %{session: session} do
    session
    |> get_prompt(:stubbed_prompt, %{})
    |> assert_prompt_message(text: "stubbed")
  end
end
