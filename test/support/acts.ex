defmodule Phantom.Test.ACTS do
  @moduledoc """
  Runs the A2A conformance suite (ACTS) from `a2aproject/a2a-itk` against
  `Phantom.ACTS.Agent`, served three ways: the default agent, one that
  doesn't stream (`--reduced-sut-url`), and one behind bearer authentication
  (`--auth-sut-url`). See test/acts/README.md.
  """

  @itk_repository "https://github.com/a2aproject/a2a-itk.git"
  @itk_ref "d53108aaf378a38eaff64ea39029a3d795591827"
  @ports [default: 4130, reduced: 4131, auth: 4132]
  @dir Path.expand("../acts", __DIR__)

  @doc "Children that serve the three agents"
  def children do
    [
      {Phoenix.PubSub, name: Phantom.ACTS.PubSub},
      Phantom.ACTS.Store,
      bandit(:default, pubsub: Phantom.ACTS.PubSub),
      bandit(:reduced, []),
      bandit(:auth, pubsub: Phantom.ACTS.PubSub, router: Phantom.ACTS.AuthRouter)
    ]
  end

  defp bandit(name, opts) do
    Supervisor.child_spec(
      {Bandit,
       plug: {Phantom.ACTS.HTTP, opts},
       ip: {127, 0, 0, 1},
       port: Keyword.fetch!(@ports, name),
       startup_log: false},
      id: {__MODULE__, name}
    )
  end

  @doc "The URL of each agent"
  def url(name), do: "http://127.0.0.1:#{Keyword.fetch!(@ports, name)}"

  @doc """
  Run the suite over JSON-RPC. Returns `{exit_status, output, report}`, where
  the report is the decoded ACTS report, or `nil` when none was written.
  """
  def run(args \\ []) do
    itk = itk!()
    out = Path.join(System.tmp_dir!(), "phantom-acts-#{System.unique_integer([:positive])}")

    {output, status} =
      System.cmd(
        "uv",
        [
          "run",
          "run_acts.py",
          "--sut-url",
          url(:default),
          "--reduced-sut-url",
          url(:reduced),
          "--auth-sut-url",
          url(:auth),
          "--sdk",
          "phantom_mcp",
          "--language",
          "elixir",
          "--behaviors",
          Path.join(@dir, "sut-behaviors.yaml"),
          "--transport",
          "jsonrpc",
          "--out",
          out | args
        ],
        cd: itk,
        stderr_to_stdout: true,
        env: [{"NO_COLOR", "1"}]
      )

    report =
      case Path.wildcard(Path.join(out, "*.json")) do
        [path] -> path |> File.read!() |> JSON.decode!()
        [] -> nil
      end

    File.rm_rf(out)
    {status, output, report}
  end

  @doc "The test ids in a report, by result"
  def results(report) do
    for suite <- report["suites"], test <- suite["tests"], reduce: %{} do
      acc -> Map.update(acc, test["result"], [test["id"]], &[test["id"] | &1])
    end
  end

  @doc "The ids in expected-failures.yml"
  def expected_failures do
    for line <- File.stream!(Path.join(@dir, "expected-failures.yml")),
        [_, id] <- [Regex.run(~r/^- ([A-Z0-9-]+)/, line)],
        do: id
  end

  # A checkout given in A2A_ITK_PATH, or the pinned ref cloned into _build.
  defp itk! do
    path = System.get_env("A2A_ITK_PATH") || Path.join(Mix.Project.build_path(), "../a2a-itk")

    if not File.exists?(Path.join(path, "run_acts.py")) do
      File.rm_rf!(path)
      cmd!("git", ["clone", "--quiet", @itk_repository, path])
      cmd!("git", ["checkout", "--quiet", @itk_ref], cd: path)
    end

    cmd!("uv", ["sync", "--quiet"], cd: path)
    path
  end

  defp cmd!(command, args, opts \\ []) do
    case System.cmd(command, args, [stderr_to_stdout: true] ++ opts) do
      {_output, 0} -> :ok
      {output, status} -> raise "#{command} #{Enum.join(args, " ")} exited #{status}:\n#{output}"
    end
  end
end
