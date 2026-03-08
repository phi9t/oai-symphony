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
  end

  test "TemporalCli reports malformed helper output" do
    runner = fn _command, _subcommand, _payload -> {:ok, "not-json"} end
    assert {:error, _reason} = TemporalCli.run(%{"workflowId" => "issue/2"}, runner: runner)
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
end
