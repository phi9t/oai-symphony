defmodule SymphonyElixir.TemporalK3sTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Execution
  alias SymphonyElixir.Execution.TemporalK3s
  alias SymphonyElixir.Tracker.Issue
  alias SymphonyElixirWeb.Presenter

  defmodule FakeOrgClient do
    def fetch_candidate_issues, do: {:ok, []}
    def fetch_issues_by_states(_states), do: {:ok, []}
    def fetch_issue_states_by_ids(_issue_ids), do: {:ok, []}

    def get_task(issue_id), do: {:ok, %{id: issue_id}}

    def get_workpad(issue_id) do
      send(self(), {:org_get_workpad_called, issue_id})
      {:ok, "workpad for #{issue_id}"}
    end

    def replace_workpad(issue_id, content) do
      send(self(), {:org_replace_workpad_called, issue_id, content})
      {:ok, content}
    end

    def set_task_state(issue_id, state_name) do
      send(self(), {:org_set_task_state_called, issue_id, state_name})
      {:ok, %{id: issue_id, state: state_name}}
    end
  end

  setup do
    previous_org_client_module = Application.get_env(:symphony_elixir, :org_client_module)

    on_exit(fn ->
      if is_nil(previous_org_client_module) do
        Application.delete_env(:symphony_elixir, :org_client_module)
      else
        Application.put_env(:symphony_elixir, :org_client_module, previous_org_client_module)
      end
    end)

    :ok
  end

  test "TemporalK3s propagates helper payloads through bounded polling and finishes Org work" do
    Application.put_env(:symphony_elixir, :org_client_module, FakeOrgClient)

    k3s_project_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-temporal-k3s-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(k3s_project_root)
    on_exit(fn -> File.rm_rf(k3s_project_root) end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "orgmode",
      tracker_file: "/tmp/revision-plan.org",
      tracker_root_id: "root-id",
      execution_kind: "temporal_k3s",
      repository_origin_url: "https://example.com/repo.git",
      temporal_status_poll_ms: 1,
      k3s_project_root: k3s_project_root
    )

    issue = %Issue{
      id: "issue-remote",
      identifier: "REV-11",
      title: "Self-land task",
      description: "Exercise the remote queue",
      state: "In Progress"
    }

    final_workpad = """
    ### Environment
    `remote:/workspace@abc123`

    ### Plan
    - [x] Land the queued task

    ### Acceptance Criteria
    - [x] Queue completed and merged

    ### Validation
    - [x] plain elixir remote smoke

    ### Notes
    - PR: https://example.com/pr/1
    - Merge commit: abc123
    """

    {:ok, runner_state} =
      Agent.start_link(fn ->
        %{
          run_payload: nil,
          workpad_path: nil,
          result_path: nil,
          workspace_path: nil,
          outputs_path: nil,
          status_calls: 0
        }
      end)

    on_exit(fn ->
      if Process.alive?(runner_state) do
        Agent.stop(runner_state)
      end
    end)

    runner = fn _command, subcommand, payload ->
      case subcommand do
        "run" ->
          workpad_path = get_in(payload, ["paths", "workpadPath"])
          result_path = get_in(payload, ["paths", "resultPath"])
          workspace_path = get_in(payload, ["paths", "workspacePath"])
          outputs_path = get_in(payload, ["paths", "outputsPath"])
          issue_path = get_in(payload, ["paths", "issuePath"])

          assert File.read!(workpad_path) == "workpad for issue-remote"
          assert File.read!(issue_path) =~ ~s("identifier": "REV-11")
          assert get_in(payload, ["repository", "originUrl"]) == "https://example.com/repo.git"

          Agent.update(runner_state, fn state ->
            %{
              state
              | run_payload: payload,
                workpad_path: workpad_path,
                result_path: result_path,
                workspace_path: workspace_path,
                outputs_path: outputs_path
            }
          end)

          {:ok,
           Jason.encode!(%{
             "workflowId" => "issue/issue-remote",
             "runId" => "run-001",
             "status" => "queued",
             "projectId" => Map.get(payload, "projectId"),
             "workspacePath" => workspace_path,
             "artifactDir" => outputs_path,
             "jobName" => "symphony-job-issue-remote"
           })}

        "status" ->
          Agent.get_and_update(runner_state, fn state ->
            call_number = state.status_calls + 1

            assert payload["workflowId"] == "issue/issue-remote"

            expected_run_id =
              case call_number do
                3 -> "run-002"
                _ -> "run-001"
              end

            assert payload["runId"] == expected_run_id

            status =
              case call_number do
                1 ->
                  %{
                    "workflowId" => "issue/issue-remote",
                    "runId" => "run-001",
                    "status" => "queued",
                    "projectId" => Map.get(state.run_payload, "projectId"),
                    "workspacePath" => state.workspace_path,
                    "artifactDir" => state.outputs_path,
                    "jobName" => "symphony-job-issue-remote"
                  }

                2 ->
                  %{
                    "workflowId" => "issue/issue-remote",
                    "runId" => "run-002",
                    "status" => "running",
                    "projectId" => Map.get(state.run_payload, "projectId"),
                    "workspacePath" => state.workspace_path,
                    "artifactDir" => state.outputs_path,
                    "jobName" => "symphony-job-issue-remote"
                  }

                3 ->
                  File.write!(state.workpad_path, final_workpad)

                  File.write!(
                    state.result_path,
                    Jason.encode!(%{
                      "status" => "succeeded",
                      "targetState" => "Done",
                      "summary" => "Merged and ready for cleanup.",
                      "validation" => ["plain elixir remote smoke"],
                      "blockedReason" => nil,
                      "needsContinuation" => false
                    })
                  )

                  %{
                    "workflowId" => "issue/issue-remote",
                    "runId" => "run-002",
                    "status" => "succeeded",
                    "projectId" => Map.get(state.run_payload, "projectId"),
                    "workspacePath" => state.workspace_path,
                    "artifactDir" => state.outputs_path,
                    "jobName" => "symphony-job-issue-remote"
                  }
              end

            {{:ok, Jason.encode!(status)}, %{state | status_calls: call_number}}
          end)
      end
    end

    assert :ok = TemporalK3s.run(issue, self(), runner: runner)

    assert_receive {:org_get_workpad_called, "issue-remote"}

    assert_receive {:codex_worker_update, "issue-remote", session_started}
    assert session_started.event == :session_started
    assert session_started.execution_backend == "temporal_k3s"
    assert session_started.workflow_id == "issue/issue-remote"
    assert session_started.workflow_run_id == "run-001"
    assert session_started.project_id == "REV-11"
    assert session_started.job_name == "symphony-job-issue-remote"
    assert session_started.payload.method == "temporal/session_started"
    assert session_started.payload.params["workflowId"] == "issue/issue-remote"
    assert session_started.payload.params["runId"] == "run-001"

    assert_receive {:codex_worker_update, "issue-remote", queued_update}
    assert_temporal_status_update(queued_update, "queued", "run-001")

    assert_receive {:codex_worker_update, "issue-remote", running_update}
    assert_temporal_status_update(running_update, "running", "run-002")

    assert_receive {:codex_worker_update, "issue-remote", success_update}
    assert_temporal_status_update(success_update, "succeeded", "run-002")

    assert_receive {:org_replace_workpad_called, "issue-remote", ^final_workpad}
    assert_receive {:org_set_task_state_called, "issue-remote", "Done"}

    assert %{status_calls: 3} = Agent.get(runner_state, & &1)
    refute_receive {:codex_worker_update, "issue-remote", _}, 20
  end

  test "orchestrator snapshots and presenter keep remote helper metadata" do
    issue_id = "issue-remote-state"

    issue = %Issue{
      id: issue_id,
      identifier: "REV-12",
      title: "Remote queue metadata",
      description: "Expose helper fields in the queue",
      state: "Merging",
      url: "https://example.org/issues/REV-12"
    }

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

  test "remote cleanup removes the temporal project workspace after completion" do
    k3s_project_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-temporal-cleanup-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(k3s_project_root)
    on_exit(fn -> File.rm_rf(k3s_project_root) end)

    write_workflow_file!(Workflow.workflow_file_path(),
      execution_kind: "temporal_k3s",
      repository_origin_url: "https://example.com/repo.git",
      k3s_project_root: k3s_project_root
    )

    workspace_path = TemporalK3s.project_workspace_path("REV-13")
    marker_path = Path.join(workspace_path, "marker.txt")

    File.mkdir_p!(workspace_path)
    File.write!(marker_path, "cleanup me")

    assert File.exists?(marker_path)
    assert :ok = Execution.cleanup_issue_workspace("REV-13", %{execution_backend: "temporal_k3s"})
    refute File.exists?(workspace_path)
    refute File.exists?(Path.dirname(workspace_path))
  end

  defp assert_temporal_status_update(update, expected_status, expected_run_id) do
    assert update.event == :notification
    assert update.execution_backend == "temporal_k3s"
    assert update.workflow_id == "issue/issue-remote"
    assert update.workflow_run_id == expected_run_id
    assert update.payload.method == "temporal/status"
    assert update.payload.params["status"] == expected_status
    assert update.payload.params["runId"] == expected_run_id
  end
end
