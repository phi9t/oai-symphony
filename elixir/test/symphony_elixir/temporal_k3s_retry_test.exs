defmodule SymphonyElixir.TemporalK3sRetryTest do
  use SymphonyElixir.TestSupport

  import SymphonyElixir.TestSupport.Scenarios,
    only: [
      issue_fixture: 1,
      start_agent!: 1,
      temporal_k3s_fixture!: 1
    ]

  alias SymphonyElixir.Execution.TemporalK3s

  test "TemporalK3s retry attempts create fresh workflow and job identifiers" do
    %{k3s_project_root: k3s_project_root} =
      temporal_k3s_fixture!("symphony-temporal-retry-identifiers")

    write_workflow_file!(Workflow.workflow_file_path(),
      execution_kind: "temporal_k3s",
      repository_origin_url: "https://example.com/repo.git",
      temporal_address: "temporal.example:7233",
      temporal_namespace: "customer-a",
      temporal_status_poll_ms: 1,
      k3s_project_root: k3s_project_root
    )

    issue =
      issue_fixture(
        id: "issue-remote-retry",
        identifier: "REV-14",
        title: "Retry remote task",
        description: "Ensure remote retries use fresh identifiers",
        state: "In Progress"
      )

    runner_state = start_agent!(%{run_payloads: [], run_details: %{}})

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

    assert get_in(first_payload, ["paths", "workspacePath"]) !=
             get_in(retry_payload, ["paths", "workspacePath"])
  end
end
