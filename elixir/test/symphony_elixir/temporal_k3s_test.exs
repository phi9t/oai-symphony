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

  defmodule FakeOrgStateFailureClient do
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
      {:error, :org_write_failed}
    end
  end

  defmodule FakeOrgWorkpadFailureClient do
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
      {:error, :org_workpad_write_failed}
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
    assert status_calls > 1
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

  test "TemporalK3s retry attempts create fresh workflow and job identifiers" do
    k3s_project_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-temporal-retry-identifiers-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(k3s_project_root)
    on_exit(fn -> File.rm_rf(k3s_project_root) end)

    write_workflow_file!(Workflow.workflow_file_path(),
      execution_kind: "temporal_k3s",
      repository_origin_url: "https://example.com/repo.git",
      temporal_address: "temporal.example:7233",
      temporal_namespace: "customer-a",
      temporal_status_poll_ms: 1,
      k3s_project_root: k3s_project_root
    )

    issue = %Issue{
      id: "issue-remote-retry",
      identifier: "REV-14",
      title: "Retry remote task",
      description: "Ensure remote retries use fresh identifiers",
      state: "In Progress"
    }

    {:ok, runner_state} =
      Agent.start_link(fn ->
        %{
          run_payloads: [],
          run_details: %{}
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
          workflow_id = payload["workflowId"]
          project_id = payload["projectId"]
          workspace_path = get_in(payload, ["paths", "workspacePath"])
          outputs_path = get_in(payload, ["paths", "outputsPath"])
          result_path = get_in(payload, ["paths", "resultPath"])

          run_number =
            Agent.get_and_update(runner_state, fn state ->
              run_number = length(state.run_payloads) + 1

              updated_state = %{
                state
                | run_payloads: state.run_payloads ++ [payload],
                  run_details:
                    Map.put(state.run_details, workflow_id, %{
                      run_number: run_number,
                      project_id: project_id,
                      workspace_path: workspace_path,
                      outputs_path: outputs_path,
                      result_path: result_path
                    })
              }

              {run_number, updated_state}
            end)

          {:ok,
           Jason.encode!(%{
             "workflowId" => workflow_id,
             "runId" => "run-00#{run_number}",
             "status" => "queued",
             "projectId" => project_id,
             "workspacePath" => workspace_path,
             "artifactDir" => outputs_path,
             "jobName" => "symphony-job-#{project_id}"
           })}

        "status" ->
          run_details = Agent.get(runner_state, & &1.run_details)
          run_detail = Map.fetch!(run_details, payload["workflowId"])

          assert payload["runId"] == "run-00#{run_detail.run_number}"

          status_payload =
            case run_detail.run_number do
              1 ->
                %{
                  "workflowId" => payload["workflowId"],
                  "runId" => payload["runId"],
                  "status" => "failed",
                  "projectId" => run_detail.project_id,
                  "workspacePath" => run_detail.workspace_path,
                  "artifactDir" => run_detail.outputs_path,
                  "jobName" => "symphony-job-#{run_detail.project_id}"
                }

              2 ->
                File.write!(
                  run_detail.result_path,
                  Jason.encode!(%{
                    "status" => "succeeded",
                    "targetState" => "Done",
                    "summary" => "Retry succeeded with fresh identifiers.",
                    "validation" => ["temporal retry identifier regression"],
                    "blockedReason" => nil,
                    "needsContinuation" => false
                  })
                )

                %{
                  "workflowId" => payload["workflowId"],
                  "runId" => payload["runId"],
                  "status" => "succeeded",
                  "projectId" => run_detail.project_id,
                  "workspacePath" => run_detail.workspace_path,
                  "artifactDir" => run_detail.outputs_path,
                  "jobName" => "symphony-job-#{run_detail.project_id}"
                }
            end

          {:ok, Jason.encode!(status_payload)}
      end
    end

    assert_raise RuntimeError, ~r/Temporal\/K3s workflow ended with status=failed/, fn ->
      TemporalK3s.run(issue, self(), runner: runner)
    end

    assert_receive {:codex_worker_update, "issue-remote-retry", first_session_started}
    assert first_session_started.event == :session_started
    assert first_session_started.workflow_id == "issue/issue-remote-retry"
    assert first_session_started.project_id == "REV-14"
    assert first_session_started.job_name == "symphony-job-REV-14"

    assert_receive {:codex_worker_update, "issue-remote-retry", first_failed_update}
    assert first_failed_update.payload.params["status"] == "failed"
    assert first_failed_update.job_name == "symphony-job-REV-14"

    assert :ok = TemporalK3s.run(issue, self(), runner: runner, attempt: 1)

    assert_receive {:codex_worker_update, "issue-remote-retry", retry_session_started}
    assert retry_session_started.event == :session_started
    assert retry_session_started.workflow_id != first_session_started.workflow_id
    assert retry_session_started.workflow_id =~ "/attempt-1-"
    assert retry_session_started.project_id != first_session_started.project_id
    assert String.starts_with?(retry_session_started.project_id, "REV-14-attempt-1-")
    assert retry_session_started.job_name != first_session_started.job_name
    assert String.starts_with?(retry_session_started.job_name, "symphony-job-REV-14-attempt-1-")

    assert_receive {:codex_worker_update, "issue-remote-retry", retry_success_update}
    assert retry_success_update.payload.params["status"] == "succeeded"
    assert retry_success_update.workflow_id == retry_session_started.workflow_id
    assert retry_success_update.job_name == retry_session_started.job_name

    assert %{run_payloads: [first_payload, retry_payload]} = Agent.get(runner_state, & &1)
    assert first_payload["workflowId"] == first_session_started.workflow_id
    assert retry_payload["workflowId"] == retry_session_started.workflow_id
    assert first_payload["projectId"] == first_session_started.project_id
    assert retry_payload["projectId"] == retry_session_started.project_id
    assert get_in(first_payload, ["paths", "workspacePath"]) != get_in(retry_payload, ["paths", "workspacePath"])
  end

  test "TemporalK3s raises when final Org workpad sync fails" do
    Application.put_env(:symphony_elixir, :org_client_module, FakeOrgWorkpadFailureClient)

    k3s_project_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-temporal-org-workpad-#{System.unique_integer([:positive])}"
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
      k3s_project_root: k3s_project_root
    )

    issue = %Issue{
      id: "issue-org-workpad",
      identifier: "REV-8",
      title: "Surface workpad sync failures",
      description: "Do not swallow final Org workpad update errors",
      state: "In Progress"
    }

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

    {:ok, runner_state} =
      Agent.start_link(fn ->
        %{
          workpad_path: nil,
          result_path: nil,
          workspace_path: nil,
          outputs_path: nil
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
          %{
            workpad_path: workpad_path,
            result_path: result_path,
            workspace_path: workspace_path,
            outputs_path: outputs_path
          } =
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
    Application.put_env(:symphony_elixir, :org_client_module, FakeOrgStateFailureClient)

    k3s_project_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-temporal-org-sync-#{System.unique_integer([:positive])}"
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
      k3s_project_root: k3s_project_root
    )

    issue = %Issue{
      id: "issue-org-sync",
      identifier: "REV-8",
      title: "Surface state sync failures",
      description: "Do not swallow final Org state update errors",
      state: "In Progress"
    }

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

    {:ok, runner_state} =
      Agent.start_link(fn ->
        %{
          workpad_path: nil,
          result_path: nil,
          workspace_path: nil,
          outputs_path: nil
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
          %{
            workpad_path: workpad_path,
            result_path: result_path,
            workspace_path: workspace_path,
            outputs_path: outputs_path
          } =
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

  test "remote cleanup removes all temporal project workspaces after completion" do
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

  defp assert_temporal_status_update(update, expected_status, expected_run_id) do
    assert update.event == :notification
    assert update.execution_backend == "temporal_k3s"
    assert update.workflow_id == "issue/issue-remote"
    assert update.workflow_run_id == expected_run_id
    assert update.payload.method == "temporal/status"
    assert update.payload.params["status"] == expected_status
    assert update.payload.params["runId"] == expected_run_id
  end

  defp assert_temporal_connection_payload(payload) do
    assert temporal_connection_payload?(payload)
  end

  defp temporal_connection_payload?(payload) do
    Map.take(payload["temporal"] || %{}, ["address", "namespace"]) == %{
      "address" => "temporal.example:7233",
      "namespace" => "customer-a"
    }
  end
end
