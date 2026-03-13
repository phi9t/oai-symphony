defmodule SymphonyElixir.TemporalK3sTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Execution.TemporalK3s
  alias SymphonyElixir.Tracker.Issue
  import SymphonyElixir.TestSupport.TemporalK3s

  alias SymphonyElixir.TestSupport.TemporalK3s.FakeOrgClient

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

  @tag :smoke
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
      temporal_address: "temporal.example:7233",
      temporal_namespace: "customer-a",
      temporal_status_poll_ms: 1,
      codex_stall_timeout_ms: 50,
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
          status_calls: 0,
          status_payloads: []
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
          assert_temporal_connection_payload(payload)

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
            assert_temporal_connection_payload(payload)

            expected_run_id =
              case call_number do
                4 -> "run-002"
                _ -> "run-001"
              end

            assert payload["runId"] == expected_run_id

            response =
              case call_number do
                1 ->
                  {:error, :temporary_unreachable}

                2 ->
                  {:ok,
                   %{
                     "workflowId" => "issue/issue-remote",
                     "runId" => "run-001",
                     "status" => "queued",
                     "projectId" => Map.get(state.run_payload, "projectId"),
                     "workspacePath" => state.workspace_path,
                     "artifactDir" => state.outputs_path,
                     "jobName" => "symphony-job-issue-remote"
                   }}

                3 ->
                  {:ok,
                   %{
                     "workflowId" => "issue/issue-remote",
                     "runId" => "run-002",
                     "status" => "running",
                     "projectId" => Map.get(state.run_payload, "projectId"),
                     "workspacePath" => state.workspace_path,
                     "artifactDir" => state.outputs_path,
                     "jobName" => "symphony-job-issue-remote"
                   }}

                4 ->
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

                  {:ok,
                   %{
                     "workflowId" => "issue/issue-remote",
                     "runId" => "run-002",
                     "status" => "succeeded",
                     "projectId" => Map.get(state.run_payload, "projectId"),
                     "workspacePath" => state.workspace_path,
                     "artifactDir" => state.outputs_path,
                     "jobName" => "symphony-job-issue-remote"
                   }}
              end

            updated_state = %{
              state
              | status_calls: call_number,
                status_payloads: [payload | state.status_payloads]
            }

            reply =
              case response do
                {:ok, status} -> {:ok, Jason.encode!(status)}
                {:error, reason} -> {:error, reason}
              end

            {reply, updated_state}
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

    assert %{status_calls: 4, status_payloads: status_payloads} = Agent.get(runner_state, & &1)
    assert length(status_payloads) == 4
    assert Enum.all?(status_payloads, &temporal_connection_payload?/1)
    refute_receive {:codex_worker_update, "issue-remote", _}, 20
  end

  test "TemporalK3s raises once repeated status failures exceed the stall timeout budget" do
    k3s_project_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-temporal-timeout-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(k3s_project_root)
    on_exit(fn -> File.rm_rf(k3s_project_root) end)

    write_workflow_file!(Workflow.workflow_file_path(),
      execution_kind: "temporal_k3s",
      repository_origin_url: "https://example.com/repo.git",
      temporal_address: "temporal.example:7233",
      temporal_namespace: "customer-a",
      temporal_status_poll_ms: 1,
      codex_stall_timeout_ms: 5,
      k3s_project_root: k3s_project_root
    )

    issue = %Issue{
      id: "issue-stall",
      identifier: "REV-8",
      title: "Bound remote poll failures",
      description: "Fail when Temporal status remains unreachable",
      state: "In Progress"
    }

    {:ok, runner_state} = Agent.start_link(fn -> %{status_calls: 0} end)

    on_exit(fn ->
      if Process.alive?(runner_state) do
        Agent.stop(runner_state)
      end
    end)

    runner = fn _command, subcommand, payload ->
      case subcommand do
        "run" ->
          assert_temporal_connection_payload(payload)

          {:ok,
           Jason.encode!(%{
             "workflowId" => "issue/issue-stall",
             "runId" => "run-001",
             "status" => "queued",
             "projectId" => Map.get(payload, "projectId"),
             "workspacePath" => get_in(payload, ["paths", "workspacePath"]),
             "artifactDir" => get_in(payload, ["paths", "outputsPath"]),
             "jobName" => "symphony-job-issue-stall"
           })}

        "status" ->
          Agent.update(runner_state, fn state ->
            %{state | status_calls: state.status_calls + 1}
          end)

          assert payload["workflowId"] == "issue/issue-stall"
          assert payload["runId"] == "run-001"
          assert_temporal_connection_payload(payload)
          {:error, :temporal_unreachable}
      end
    end

    assert_raise RuntimeError,
                 ~r/Temporal\/K3s status checks stalled .* after \d+ms \(timeout=5ms\): :temporal_unreachable/,
                 fn ->
                   TemporalK3s.run(issue, self(), runner: runner)
                 end

    assert %{status_calls: status_calls} = Agent.get(runner_state, & &1)
    assert status_calls >= 1
  end

  test "TemporalK3s keeps retrying status errors when the stall timeout is disabled" do
    k3s_project_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-temporal-no-timeout-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(k3s_project_root)
    on_exit(fn -> File.rm_rf(k3s_project_root) end)

    write_workflow_file!(Workflow.workflow_file_path(),
      execution_kind: "temporal_k3s",
      repository_origin_url: "https://example.com/repo.git",
      temporal_address: "temporal.example:7233",
      temporal_namespace: "customer-a",
      temporal_status_poll_ms: 1,
      codex_stall_timeout_ms: 0,
      k3s_project_root: k3s_project_root
    )

    issue = %Issue{
      id: "issue-no-timeout",
      identifier: "REV-8",
      title: "Allow explicit timeout disable",
      description: "Do not time out remote status failures when disabled",
      state: "In Progress"
    }

    {:ok, runner_state} = Agent.start_link(fn -> %{status_calls: 0} end)

    on_exit(fn ->
      if Process.alive?(runner_state) do
        Agent.stop(runner_state)
      end
    end)

    runner = fn _command, subcommand, payload ->
      case subcommand do
        "run" ->
          {:ok,
           Jason.encode!(%{
             "workflowId" => "issue/issue-no-timeout",
             "runId" => "run-001",
             "status" => "queued",
             "projectId" => Map.get(payload, "projectId"),
             "workspacePath" => get_in(payload, ["paths", "workspacePath"]),
             "artifactDir" => get_in(payload, ["paths", "outputsPath"]),
             "jobName" => "symphony-job-issue-no-timeout"
           })}

        "status" ->
          call_number =
            Agent.get_and_update(runner_state, fn state ->
              next_call = state.status_calls + 1
              {next_call, %{state | status_calls: next_call}}
            end)

          assert payload["workflowId"] == "issue/issue-no-timeout"
          assert payload["runId"] == "run-001"
          assert_temporal_connection_payload(payload)

          case call_number do
            call_number when call_number < 3 ->
              {:error, :temporal_unreachable}

            3 ->
              {:ok,
               Jason.encode!(%{
                 "workflowId" => "issue/issue-no-timeout",
                 "runId" => "run-001",
                 "status" => "succeeded",
                 "projectId" => Map.get(payload, "projectId"),
                 "workspacePath" => get_in(payload, ["paths", "workspacePath"]),
                 "artifactDir" => get_in(payload, ["paths", "outputsPath"]),
                 "jobName" => "symphony-job-issue-no-timeout"
               })}
          end
      end
    end

    assert :ok = TemporalK3s.run(issue, self(), runner: runner)

    assert %{status_calls: 3} = Agent.get(runner_state, & &1)
  end
end
