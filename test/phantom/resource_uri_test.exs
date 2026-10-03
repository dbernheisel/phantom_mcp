defmodule Phantom.ResourceURITest.Router do
  use Phantom.Router, name: "Resource URI test", vsn: "1.0"

  require Phantom.Resource, as: Resource

  resource "test://static-text", :static_text, mime_type: "text/plain"
  resource "test:///static-text", :pathless_text, mime_type: "text/plain"
  resource "test://template/:id/data", :template_data, mime_type: "application/json"
  resource "https://example.com/studies/:study_id/md", :study, mime_type: "text/markdown"
  resource "https://other.example/studies/:study_id/md", :other_study, mime_type: "text/markdown"

  def static_text(_params, session), do: {:reply, Resource.text("host only"), session}
  def pathless_text(_params, session), do: {:reply, Resource.text("empty host"), session}
  def template_data(%{"id" => id}, session), do: {:reply, Resource.text("data #{id}"), session}
  def study(%{"study_id" => id}, session), do: {:reply, Resource.text("study #{id}"), session}

  def other_study(%{"study_id" => id}, session),
    do: {:reply, Resource.text("other study #{id}"), session}
end

defmodule Phantom.ResourceURITest do
  use ExUnit.Case

  import Phantom.TestDispatcher

  alias Phantom.ResourceTemplate
  alias Phantom.ResourceURITest.Router
  alias Phantom.Session

  setup do
    Phantom.Cache.register(Router)
    {:ok, session: Session.new("session", router: Router)}
  end

  test "advertises URI templates with their host" do
    templates =
      Router.__phantom__(:info).resource_templates
      |> Map.new(&{&1.name, ResourceTemplate.to_json(&1).uriTemplate})

    assert templates == %{
             "static_text" => "test://static-text",
             "pathless_text" => "test:///static-text",
             "template_data" => "test://template/{id}/data",
             "study" => "https://example.com/studies/{study_id}/md",
             "other_study" => "https://other.example/studies/{study_id}/md"
           }
  end

  test "builds URIs with their host" do
    assert Router.resource_uri(:static_text) == {:ok, "test://static-text"}
    assert Router.resource_uri(:pathless_text) == {:ok, "test:///static-text"}
    assert Router.resource_uri(:template_data, id: 7) == {:ok, "test://template/7/data"}

    assert Router.resource_uri(:study, study_id: 5) ==
             {:ok, "https://example.com/studies/5/md"}
  end

  test "resolves a URI only against templates with the same host", %{session: session} do
    resolved = fn uri ->
      Router
      |> Phantom.Router.resolve_resources(session, [uri])
      |> Enum.map(fn {_uri, params, template} -> {template.name, params} end)
    end

    assert resolved.("test://static-text") == [{"static_text", %{}}]
    assert resolved.("test:///static-text") == [{"pathless_text", %{}}]
    assert resolved.("test://template/7/data") == [{"template_data", %{"id" => "7"}}]
    assert resolved.("https://example.com/studies/5/md") == [{"study", %{"study_id" => "5"}}]
    assert resolved.("https://EXAMPLE.com/studies/5/md") == [{"study", %{"study_id" => "5"}}]

    assert resolved.("https://other.example/studies/5/md") ==
             [{"other_study", %{"study_id" => "5"}}]

    assert resolved.("https://evil.example/studies/5/md") == []
    assert resolved.("test://evil.example/static-text") == []
    assert resolved.("test:///template/7/data") == []
  end

  test "reads resources by URI with a host" do
    for {uri, id, text} <- [
          {"test://static-text", 1, "host only"},
          {"test:///static-text", 2, "empty host"},
          {"test://template/7/data", 3, "data 7"},
          {"https://other.example/studies/5/md", 4, "other study 5"}
        ] do
      request_resource_read(uri, id: id, router: Router, pubsub: nil)

      assert_response(id, %{result: %{contents: [%{uri: ^uri, text: ^text}]}})
    end
  end

  test "an unknown URI without a path is not found" do
    uri = "test://unknown-resource"
    request_resource_read(uri, id: 5, router: Router, pubsub: nil)

    assert_response(5, %{
      error: %{code: -32002, message: "Resource not found", data: %{uri: ^uri}}
    })
  end
end
