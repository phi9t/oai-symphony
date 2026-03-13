defmodule SymphonyElixir.TemporalK3sOrgSyncTest do
  use SymphonyElixir.TestSupport

  import SymphonyElixir.TestSupport.Scenarios,
    only: [
      issue_fixture: 1,
      start_agent!: 1,
      temporal_k3s_fixture!: 1,
      temporal_k3s_fixture!: 2
    ]

  import SymphonyElixir.TestSupport.TemporalK3s, only: [assert_temporal_connection_payload: 1]

  alias SymphonyElixir.Execution
  alias SymphonyElixir.Execution.TemporalK3s

  alias SymphonyElixir.TestSupport.TemporalK3s.{
    FakeOrgStateFailureClient,
    FakeOrgWorkpadFailureClient
  }

  alias SymphonyElixirWeb.Presenter

  test "TemporalK3s raises when final Org workpad sync fails" do
    %{k3s_project_root: k3s_project_root} =
      temporal_k3s_fixture!(
        "symphony-temporal-org-workpad",
        org_client_module: FakeOrgWorkpadFailureClient
      )

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "orgmode",
      tracker_file: "/tmp/revision-plan.org",
      tracker_root_id: "root-id",
      execution_kind: "temporal_k3s",
      repository_origin_url: "https://example.com/repo.git",
      temporal_address: "temporal.example:7233",
      temporal_namespace: "customer-a",
      temporal_status_poll_ms: 1,
      k3s_project_root: k3s_project_root
    )

    issue =
      issue_fixture(
        id: "issue-org-workpad",
        identifier: "REV-8",
        title: "Surface workpad sync failures",
        description: "Do not swallow final Org workpad update errors",
        state: "In Progress"
      )

    final_workpad = """
    ### Environment
    `remote:/workspace@abc123`

    ### Plan
    - [x] Fail loudly on workpad sync errors

    ### Acceptance Criteria
    - [x] Workpad sync failures stop the run

    ### Validation
    - [x] direct ExUnit regression

    ### Notes
    - Workpad update failed intentionally
    """

    runner_state =
      start_agent!(%{
        workpad_path: nil,
        result_path: nil,
        workspace_path: nil,
        outputs_path: nil
      })

    runner = fn _command, subcommand, payload ->
      case subcommand do
        "run" ->
          Agent.update(runner_state, fn state ->
            %{
              state
              | workpad_path: get_in(payload, ["paths", "workpadPath"]),
                result_path: get_in(payload, ["paths", "resultPath"]),
                workspace_path: get_in(payload, ["paths", "workspacePath"]),
                outputs_path: get_in(payload, ["paths", "outputsPath"])
            }
          end)

          {:ok,
           Jason.encode!(%{
             "workflowId" => "issue/issue-org-workpad",
             "runId" => "run-001",
             "status" => "queued",
             "projectId" => Map.get(payload, "projectId"),
             "workspacePath" => get_in(payload, ["paths", "workspacePath"]),
             "artifactDir" => get_in(payload, ["paths", "outputsPath"]),
             "jobName" => "symphony-job-issue-org-workpad"
           })}

        "status" ->
          %{workpad_path: workpad_path, result_path: result_path, workspace_path: workspace_path, outputs_path: outputs_path} =
            Agent.get(runner_state, & &1)

          File.write!(workpad_path, final_workpad)

          File.write!(
            result_path,
            Jason.encode!(%{
              "status" => "succeeded",
              "targetState" => "Done",
              "summary" => "Completed, but workpad sync failed.",
              "validation" => ["direct ExUnit regression"],
              "blockedReason" => nil,
              "needsContinuation" => false
            })
          )

          {:ok,
           Jason.encode!(%{
             "workflowId" => "issue/issue-org-workpad",
             "runId" => "run-001",
             "status" => "succeeded",
             "projectId" => Map.get(payload, "projectId"),
             "workspacePath" => workspace_path,
             "artifactDir" => outputs_path,
             "jobName" => "symphony-job-issue-org-workpad"
           })}
      end
    end

    assert_raise RuntimeError,
                 ~r/Temporal\/K3s failed to sync Org workpad .* :org_workpad_write_failed/,
                 fn ->
                   TemporalK3s.run(issue, self(), runner: runner)
                 end

    assert_receive {:org_get_workpad_called, "issue-org-workpad"}
    assert_receive {:org_replace_workpad_called, "issue-org-workpad", ^final_workpad}
    refute_receive {:org_set_task_state_called, "issue-org-workpad", _}
  end

  test "TemporalK3s raises when final Org state sync fails" do
    %{k3s_project_root: k3s_project_root} =
      temporal_k3s_fixture!(
        "symphony-temporal-org-sync",
        org_client_module: FakeOrgStateFailureClient
      )

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "orgmode",
      tracker_file: "/tmp/revision-plan.org",
      tracker_root_id: "root-id",
      execution_kind: "temporal_k3s",
      repository_origin_url: "https://example.com/repo.git",
      temporal_address: "temporal.example:7233",
      temporal_namespace: "customer-a",
      temporal_status_poll_ms: 1,
      k3s_project_root: k3s_project_root
    )

    issue =
      issue_fixture(
        id: "issue-org-sync",
        identifier: "REV-8",
        title: "Surface state sync failures",
        description: "Do not swallow final Org state update errors",
        state: "In Progress"
      )

    final_workpad = """
    ### Environment
    `remote:/workspace@abc123`

    ### Plan
    - [x] Fail loudly on sync errors

    ### Acceptance Criteria
    - [x] State sync failures stop the run

    ### Validation
    - [x] direct ExUnit regression

    ### Notes
    - Tracker update failed intentionally
    """

    runner_state =
      start_agent!(%{
        workpad_path: nil,
        result_path: nil,
        workspace_path: nil,
        outputs_path: nil
      })

    runner = fn _command, subcommand, payload ->
      case subcommand do
        "run" ->
          Agent.update(runner_state, fn state ->
            %{
              state
              | workpad_path: get_in(payload, ["paths", "workpadPath"]),
                result_path: get_in(payload, ["paths", "resultPath"]),
                workspace_path: get_in(payload, ["paths", "workspacePath"]),
                outputs_path: get_in(payload, ["paths", "outputsPath"])
            }
          end)

          {:ok,
           Jason.encode!(%{
             "workflowId" => "issue/issue-org-sync",
             "runId" => "run-001",
             "status" => "queued",
             "projectId" => Map.get(payload, "projectId"),
             "workspacePath" => get_in(payload, ["paths", "workspacePath"]),
             "artifactDir" => get_in(payload, ["paths", "outputsPath"]),
             "jobName" => "symphony-job-issue-org-sync"
           })}

        "status" ->
          %{workpad_path: workpad_path, result_path: result_path, workspace_path: workspace_path, outputs_path: outputs_path} =
            Agent.get(runner_state, & &1)

          File.write!(workpad_path, final_workpad)

          File.write!(
            result_path,
            Jason.encode!(%{
              "status" => "succeeded",
              "targetState" => "Done",
              "summary" => "Completed, but tracker sync failed.",
              "validation" => ["direct ExUnit regression"],
              "blockedReason" => nil,
              "needsContinuation" => false
            })
          )

          {:ok,
           Jason.encode!(%{
             "workflowId" => "issue/issue-org-sync",
             "runId" => "run-001",
             "status" => "succeeded",
             "projectId" => Map.get(payload, "projectId"),
             "workspacePath" => workspace_path,
             "artifactDir" => outputs_path,
             "jobName" => "symphony-job-issue-org-sync"
           })}
      end
    end

    assert_raise RuntimeError,
                 ~r/Temporal\/K3s failed to sync Org state=Done .* :org_write_failed/,
                 fn ->
                   TemporalK3s.run(issue, self(), runner: runner)
                 end

    assert_receive {:org_get_workpad_called, "issue-org-sync"}
    assert_receive {:org_replace_workpad_called, "issue-org-sync", ^final_workpad}
    assert_receive {:org_set_task_state_called, "issue-org-sync", "Done"}
  end

  test "TemporalK3s cancel propagates configured Temporal connection settings" do
    write_workflow_file!(Workflow.workflow_file_path(),
      execution_kind: "temporal_k3s",
      temporal_address: "temporal.example:7233",
      temporal_namespace: "customer-a"
    )

    runner = fn _command, subcommand, payload ->
      send(self(), {:temporal_helper_called, subcommand, payload})
      {:ok, Jason.encode!(%{"workflowId" => payload["workflowId"], "status" => "cancelled"})}
    end

    assert :ok = TemporalK3s.cancel(%{workflow_id: "issue/issue-remote"}, runner: runner)

    assert_receive {:temporal_helper_called, "cancel", payload}
    assert payload["workflowId"] == "issue/issue-remote"
    assert_temporal_connection_payload(payload)
  end

  test "orchestrator snapshots and presenter keep remote helper metadata" do
    issue_id = "issue-remote-state"

    issue =
      issue_fixture(
        id: issue_id,
        identifier: "REV-12",
        title: "Remote queue metadata",
        description: "Expose helper fields in the queue",
        state: "Merging",
        url: "https://example.org/issues/REV-12"
      )

    orchestrator_name = Module.concat(__MODULE__, :RemoteMetadataOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)
    started_at = DateTime.utc_now()

    running_entry = %{
      pid: self(),
      ref: make_ref(),
      identifier: issue.identifier,
      issue: issue,
      session_id: nil,
      turn_count: 0,
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      started_at: started_at
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
    end)

    now = DateTime.utc_now()

    send(
      pid,
      {:codex_worker_update, issue_id,
       %{
         event: :session_started,
         timestamp: now,
         session_id: "issue/issue-remote-state/run-001",
         execution_backend: "temporal_k3s",
         workflow_id: "issue/issue-remote-state",
         workflow_run_id: "run-001",
         project_id: "rev-12",
         workspace_path: "/tmp/remote/rev-12/workspace",
         artifact_dir: "/tmp/remote/rev-12/outputs",
         job_name: "symphony-job-rev-12",
         payload: %{
           method: "temporal/session_started",
           params: %{"workflowId" => "issue/issue-remote-state", "runId" => "run-001"}
         }
       }}
    )

    send(
      pid,
      {:codex_worker_update, issue_id,
       %{
         event: :notification,
         timestamp: now,
         session_id: "issue/issue-remote-state/run-002",
         execution_backend: "temporal_k3s",
         workflow_id: "issue/issue-remote-state",
         workflow_run_id: "run-002",
         project_id: "rev-12",
         workspace_path: "/tmp/remote/rev-12/workspace",
         artifact_dir: "/tmp/remote/rev-12/outputs",
         job_name: "symphony-job-rev-12",
         payload: %{
           method: "temporal/status",
           params: %{"status" => "running", "runId" => "run-002"}
         }
       }}
    )

    assert %{running: [snapshot_entry]} = Orchestrator.snapshot(orchestrator_name, 100)
    assert snapshot_entry.execution_backend == "temporal_k3s"
    assert snapshot_entry.workflow_id == "issue/issue-remote-state"
    assert snapshot_entry.workflow_run_id == "run-002"
    assert snapshot_entry.project_id == "rev-12"
    assert snapshot_entry.workspace_path == "/tmp/remote/rev-12/workspace"
    assert snapshot_entry.artifact_dir == "/tmp/remote/rev-12/outputs"
    assert snapshot_entry.job_name == "symphony-job-rev-12"
    assert snapshot_entry.last_execution_status == "running"
    assert snapshot_entry.turn_count == 1

    assert {:ok, payload} = Presenter.issue_payload("REV-12", orchestrator_name, 100)
    assert payload.status == "running"
    assert payload.workspace.path == "/tmp/remote/rev-12/workspace"
    assert payload.running.execution_backend == "temporal_k3s"
    assert payload.running.workflow_id == "issue/issue-remote-state"
    assert payload.running.workflow_run_id == "run-002"
    assert payload.running.project_id == "rev-12"
    assert payload.running.workspace_path == "/tmp/remote/rev-12/workspace"
    assert payload.running.artifact_dir == "/tmp/remote/rev-12/outputs"
    assert payload.running.job_name == "symphony-job-rev-12"
    assert payload.running.last_execution_status == "running"
  end

  test "remote cleanup removes all temporal project workspaces after completion" do
    %{k3s_project_root: k3s_project_root} =
      temporal_k3s_fixture!("symphony-temporal-cleanup")

    write_workflow_file!(Workflow.workflow_file_path(),
      execution_kind: "temporal_k3s",
      repository_origin_url: "https://example.com/repo.git",
      k3s_project_root: k3s_project_root
    )

    workspace_path = TemporalK3s.project_workspace_path("REV-13")
    marker_path = Path.join(workspace_path, "marker.txt")
    retry_workspace_path = Path.join([k3s_project_root, "REV-13-attempt-2-abc123", "workspace"])
    retry_marker_path = Path.join(retry_workspace_path, "marker.txt")

    File.mkdir_p!(workspace_path)
    File.write!(marker_path, "cleanup me")
    File.mkdir_p!(retry_workspace_path)
    File.write!(retry_marker_path, "cleanup retry too")

    assert File.exists?(marker_path)
    assert File.exists?(retry_marker_path)
    assert :ok = Execution.cleanup_issue_workspace("REV-13", %{execution_backend: "temporal_k3s"})
    refute File.exists?(workspace_path)
    refute File.exists?(retry_workspace_path)
    refute File.exists?(Path.dirname(workspace_path))
  end
end
