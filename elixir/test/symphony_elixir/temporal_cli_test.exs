defmodule SymphonyElixir.TemporalCliTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Execution
  alias SymphonyElixir.TemporalCli

  test "TemporalCli decodes helper responses for all supported subcommands" do
    runner = fn _command, subcommand, payload ->
      {:ok,
       Jason.encode!(%{
         "subcommand" => subcommand,
         "workflowId" => Map.get(payload, "workflowId"),
         "status" => "running"
       })}
    end

    assert {:ok, %{"subcommand" => "run", "status" => "running"}} =
             TemporalCli.run(%{"workflowId" => "issue/1"}, runner: runner)

    assert {:ok, %{"subcommand" => "status", "workflowId" => "issue/1"}} =
             TemporalCli.status("issue/1", runner: runner)

    assert {:ok, %{"subcommand" => "cancel", "workflowId" => "issue/1"}} =
             TemporalCli.cancel("issue/1", runner: runner)

    assert {:ok, %{"subcommand" => "describe", "workflowId" => "issue/1"}} =
             TemporalCli.describe("issue/1", runner: runner)

    assert {:ok, %{"subcommand" => "readiness", "status" => "running"}} =
             TemporalCli.readiness(%{"temporal" => %{}}, runner: runner)
  end

  test "TemporalCli forwards Temporal connection payloads for non-run subcommands" do
    runner = fn _command, subcommand, payload ->
      {:ok,
       Jason.encode!(%{
         "subcommand" => subcommand,
         "workflowId" => Map.get(payload, "workflowId"),
         "runId" => Map.get(payload, "runId"),
         "temporal" => Map.get(payload, "temporal")
       })}
    end

    temporal = %{"address" => "temporal.example:7233", "namespace" => "customer-a"}
    status_payload = %{"workflowId" => "issue/1", "runId" => "run-001", "temporal" => temporal}
    cancel_payload = %{"workflowId" => "issue/1", "temporal" => temporal}
    describe_payload = %{"workflowId" => "issue/1", "runId" => "run-001", "temporal" => temporal}

    assert {:ok, %{"subcommand" => "status", "temporal" => ^temporal, "runId" => "run-001"}} =
             TemporalCli.status(status_payload, runner: runner)

    assert {:ok, %{"subcommand" => "cancel", "temporal" => ^temporal}} =
             TemporalCli.cancel(cancel_payload, runner: runner)

    assert {:ok, %{"subcommand" => "describe", "temporal" => ^temporal, "runId" => "run-001"}} =
             TemporalCli.describe(describe_payload, runner: runner)
  end

  test "TemporalCli reports malformed helper output" do
    runner = fn _command, _subcommand, _payload -> {:ok, "not-json"} end
    assert {:error, _reason} = TemporalCli.run(%{"workflowId" => "issue/2"}, runner: runner)
  end

  test "TemporalCli forwards readiness payloads unchanged" do
    runner = fn _command, subcommand, payload ->
      {:ok, Jason.encode!(%{"subcommand" => subcommand, "payload" => payload})}
    end

    readiness_payload = %{
      "temporal" => %{"address" => "temporal.example:7233", "namespace" => "customer-a"},
      "k3s" => %{"namespace" => "symphony"}
    }

    assert {:ok, %{"subcommand" => "readiness", "payload" => ^readiness_payload}} =
             TemporalCli.readiness(readiness_payload, runner: runner)
  end

  test "TemporalCli default runner shells out through the configured helper command" do
    helper_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-temporal-cli-success-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(helper_root)
    on_exit(fn -> File.rm_rf(helper_root) end)

    helper_script =
      write_helper_script!(
        helper_root,
        "success.py",
        """
        #!/usr/bin/env python3
        import json
        import sys

        subcommand = sys.argv[1]
        input_path = sys.argv[sys.argv.index("--input") + 1]

        with open(input_path, "r", encoding="utf-8") as handle:
            payload = json.load(handle)

        print("helper log line")
        print(json.dumps({
            "subcommand": subcommand,
            "workflowId": payload.get("workflowId"),
            "status": "running",
            "echo": payload.get("extra")
        }))
        """
      )

    assert {:ok,
            %{
              "subcommand" => "run",
              "workflowId" => "issue/3",
              "status" => "running",
              "echo" => "value"
            }} =
             TemporalCli.run(%{"workflowId" => "issue/3", "extra" => "value"},
               command: helper_script
             )
  end

  test "TemporalCli default runner surfaces helper failures and missing output" do
    helper_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-temporal-cli-failure-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(helper_root)
    on_exit(fn -> File.rm_rf(helper_root) end)

    failing_script =
      write_helper_script!(
        helper_root,
        "fail.py",
        """
        #!/usr/bin/env python3
        print("helper exploded")
        raise SystemExit(3)
        """
      )

    quiet_script =
      write_helper_script!(
        helper_root,
        "quiet.py",
        """
        #!/usr/bin/env python3
        pass
        """
      )

    assert {:error, {:temporal_helper_failed, 3, "helper exploded"}} =
             TemporalCli.run(%{"workflowId" => "issue/4"}, command: failing_script)

    assert {:error, :missing_temporal_helper_output} =
             TemporalCli.run(%{"workflowId" => "issue/4"}, command: quiet_script)
  end

  test "TemporalCli validates helper command parsing before shelling out" do
    assert {:error, :missing_temporal_helper_command} =
             TemporalCli.run(%{"workflowId" => "issue/5"}, command: "   ")

    assert {:error, :missing_temporal_helper_command} =
             TemporalCli.run(%{"workflowId" => "issue/5"}, command: "'")
  end

  test "Execution chooses remote workspace paths for temporal_k3s runs" do
    write_workflow_file!(Workflow.workflow_file_path(),
      execution_kind: "temporal_k3s",
      repository_origin_url: "https://example.com/repo.git"
    )

    running_entry = %{execution_backend: "temporal_k3s", workspace_path: "/tmp/remote/workspace"}
    assert Execution.workspace_path("MT-1", running_entry) == "/tmp/remote/workspace"
    assert Execution.workspace_path("MT-2") =~ "/tmp/symphony_projects/MT-2/workspace"
  end

  defp write_helper_script!(root, filename, body) do
    path = Path.join(root, filename)
    File.write!(path, body)
    File.chmod!(path, 0o755)
    path
  end
end
