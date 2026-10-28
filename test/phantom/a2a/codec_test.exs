defmodule Phantom.A2A.CodecTest do
  use ExUnit.Case, async: true

  alias Phantom.A2A.{Artifact, ArtifactUpdate, Message, Part, StatusUpdate, Task, TaskStatus}

  describe "Part" do
    test "decodes each kind of content" do
      assert {:ok, %Part{text: "hi"}} = Part.from_json(%{"text" => "hi"})

      assert {:ok, %Part{raw: "bytes", media_type: "application/octet-stream", filename: "a.bin"}} =
               Part.from_json(%{
                 "raw" => Base.encode64("bytes"),
                 "mediaType" => "application/octet-stream",
                 "filename" => "a.bin"
               })

      assert {:ok, %Part{url: "https://example.com/a.pdf"}} =
               Part.from_json(%{"url" => "https://example.com/a.pdf"})

      assert {:ok, %Part{data: %{"study_id" => 42}}} =
               Part.from_json(%{"data" => %{"study_id" => 42}})
    end

    test "rejects a part without content or with invalid raw bytes" do
      assert {:error, _} = Part.from_json(%{"mediaType" => "text/plain"})
      assert {:error, _} = Part.from_json(%{"raw" => "not base64!"})
      assert {:error, _} = Part.from_json("text")
    end

    test "encodes only the fields that are set" do
      assert %{"text" => "hi"} == Part.to_json(Part.text("hi"))

      assert %{"raw" => "Ynl0ZXM=", "mediaType" => "image/png"} ==
               Part.to_json(Part.raw("bytes", media_type: "image/png"))

      assert %{"data" => %{"ok" => true}} == Part.to_json(Part.data(%{"ok" => true}))
    end
  end

  describe "Message" do
    test "decodes a client message" do
      json = %{
        "messageId" => "m1",
        "role" => "ROLE_USER",
        "contextId" => "ctx",
        "taskId" => "t1",
        "parts" => [%{"text" => "hello"}],
        "metadata" => %{"k" => "v"},
        "referenceTaskIds" => ["t0"]
      }

      assert {:ok,
              %Message{
                message_id: "m1",
                role: :user,
                context_id: "ctx",
                task_id: "t1",
                parts: [%Part{text: "hello"}],
                metadata: %{"k" => "v"},
                reference_task_ids: ["t0"]
              }} = Message.from_json(json)
    end

    test "requires messageId, a role, and parts" do
      assert {:error, _} = Message.from_json(%{"role" => "ROLE_USER", "parts" => []})
      assert {:error, _} = Message.from_json(%{"messageId" => "m1", "parts" => []})

      assert {:error, _} =
               Message.from_json(%{"messageId" => "m1", "role" => "ROLE_BOSS", "parts" => []})

      assert {:error, _} = Message.from_json(%{"messageId" => "m1", "role" => "ROLE_USER"})

      assert {:error, _} =
               Message.from_json(%{"messageId" => "m1", "role" => "ROLE_USER", "parts" => [%{}]})
    end

    test "builds an agent message from text or parts" do
      assert %Message{role: :agent, parts: [%Part{text: "pong"}], message_id: id} =
               Message.agent("pong")

      assert is_binary(id)

      assert %Message{parts: [%Part{data: %{"a" => 1}}]} = Message.agent([Part.data(%{"a" => 1})])
    end

    test "encodes to ProtoJSON" do
      message = %Message{
        message_id: "m2",
        role: :agent,
        context_id: "ctx",
        parts: [Part.text("pong")]
      }

      assert %{
               "messageId" => "m2",
               "role" => "ROLE_AGENT",
               "contextId" => "ctx",
               "parts" => [%{"text" => "pong"}]
             } == Message.to_json(message)
    end
  end

  describe "Task" do
    test "encodes to ProtoJSON" do
      task = %Task{
        id: "t1",
        context_id: "ctx",
        status: %TaskStatus{
          state: :input_required,
          message: %Message{message_id: "m3", role: :agent, parts: [Part.text("More?")]},
          timestamp: ~U[2026-10-27 12:00:00Z]
        },
        artifacts: [Artifact.new("review", [Part.text("## Gaps")], name: "Review")],
        history: [%Message{message_id: "m1", role: :user, parts: [Part.text("Review")]}]
      }

      assert %{
               "id" => "t1",
               "contextId" => "ctx",
               "status" => %{
                 "state" => "TASK_STATE_INPUT_REQUIRED",
                 "message" => %{"messageId" => "m3", "role" => "ROLE_AGENT"},
                 "timestamp" => "2026-10-27T12:00:00Z"
               },
               "artifacts" => [
                 %{
                   "artifactId" => "review",
                   "name" => "Review",
                   "parts" => [%{"text" => "## Gaps"}]
                 }
               ],
               "history" => [%{"messageId" => "m1", "role" => "ROLE_USER"}]
             } = Task.to_json(task)
    end

    test "trims history to the requested length" do
      history = for i <- 1..4, do: %Message{message_id: "m#{i}", role: :user, parts: []}

      task = %Task{
        id: "t1",
        context_id: "c",
        status: %TaskStatus{state: :working},
        history: history
      }

      assert %{"history" => [%{"messageId" => "m3"}, %{"messageId" => "m4"}]} =
               Task.to_json(task, history_length: 2)

      assert %{"history" => []} = Task.to_json(task, history_length: 0)
      assert %{"history" => [_, _, _, _]} = Task.to_json(task)
    end

    test "status updates and artifact updates encode as stream events" do
      status = Task.status(:working, "Reading study…")

      assert %StatusUpdate{status: %TaskStatus{state: :working, message: %Message{role: :agent}}} =
               status

      update = Artifact.update("review", [Part.text("- More")], append: true)
      assert %ArtifactUpdate{append: true, artifact: %Artifact{artifact_id: "review"}} = update

      status = %{status | task_id: "t1", context_id: "c"}
      update = %{update | task_id: "t1", context_id: "c"}

      assert %{
               "statusUpdate" => %{
                 "taskId" => "t1",
                 "contextId" => "c",
                 "status" => %{"state" => "TASK_STATE_WORKING"}
               }
             } = Phantom.A2A.event_to_json(status)

      assert %{
               "artifactUpdate" => %{
                 "taskId" => "t1",
                 "append" => true,
                 "artifact" => %{"artifactId" => "review"}
               }
             } = Phantom.A2A.event_to_json(update)
    end
  end

  describe "decoding what a server sends" do
    alias Phantom.A2A.{AgentSkill, Card, Error}

    test "a task round-trips through ProtoJSON" do
      task = %Task{
        id: "t1",
        context_id: "c",
        status: %TaskStatus{
          state: :input_required,
          message: %Message{message_id: "m", role: :agent, parts: [Part.text("More?")]},
          timestamp: ~U[2026-10-27 12:00:00Z]
        },
        artifacts: [
          Artifact.new("a", [Part.text("x"), Part.data(%{"k" => 1})], name: "A"),
          Artifact.new("f", [Part.raw("pdf", media_type: "application/pdf", filename: "r.pdf")])
        ],
        history: [%Message{message_id: "m0", role: :user, parts: [Part.url("https://x.test/f")]}],
        metadata: %{"m" => true}
      }

      assert {:ok, ^task} = task |> Task.to_json() |> Task.from_json()
      assert {:error, _} = Task.from_json(%{"id" => "t1"})

      assert {:error, _} =
               Task.from_json(%{
                 "id" => "t1",
                 "contextId" => "c",
                 "status" => %{"state" => "NOPE"}
               })
    end

    test "stream events" do
      status = %{Task.status(:working, "Hi") | task_id: "t1", context_id: "c", sequence: nil}

      update = %{
        Artifact.update("a", [Part.text("x")], append: true, last_chunk: true)
        | task_id: "t1",
          context_id: "c"
      }

      message = Message.agent("hi")
      task = %Task{id: "t1", context_id: "c", status: %TaskStatus{state: :completed}}

      for event <- [status, update, message, task] do
        assert {:ok, ^event} =
                 event |> Phantom.A2A.event_to_json() |> Phantom.A2A.event_from_json()
      end

      assert {:error, _} = Phantom.A2A.event_from_json(%{"nope" => %{}})
    end

    test "an agent card" do
      json = %{
        "name" => "Agent",
        "description" => "Does things",
        "version" => "1.0",
        "supportedInterfaces" => [
          %{
            "url" => "https://x.test/a2a",
            "protocolBinding" => "JSONRPC",
            "protocolVersion" => "1.0"
          }
        ],
        "capabilities" => %{
          "streaming" => true,
          "extensions" => [%{"uri" => "https://x.test/ext", "required" => true}]
        },
        "defaultInputModes" => ["text/plain"],
        "defaultOutputModes" => ["text/plain"],
        "skills" => [%{"id" => "s", "name" => "S", "description" => "Skill", "tags" => ["t"]}],
        "securitySchemes" => %{"bearer" => %{}}
      }

      assert {:ok,
              %Card{
                name: "Agent",
                skills: [%AgentSkill{id: "s", tags: ["t"]}],
                capabilities: %{"streaming" => true},
                extensions: [%{uri: "https://x.test/ext", required: true}],
                supported_interfaces: [%{"protocolBinding" => "JSONRPC"}]
              } = card} = Card.from_json(json)

      assert Card.to_json(card)["name"] == "Agent"
      assert {:error, _} = Card.from_json(%{"description" => "no name"})
    end

    test "errors from either binding" do
      assert %Error{code: -32001, message: "Task not found"} =
               Error.from_json(%{"code" => -32001, "message" => "Task not found"})

      assert %Error{code: -32001, message: "gone"} =
               Error.from_json(%{
                 "code" => 404,
                 "status" => "NOT_FOUND",
                 "message" => "gone",
                 "details" => [%{"reason" => "TASK_NOT_FOUND"}]
               })

      assert %Error{code: -32603} = Error.from_json(%{"code" => 500, "message" => "boom"})
    end
  end
end
