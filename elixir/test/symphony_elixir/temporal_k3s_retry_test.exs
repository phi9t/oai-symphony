defmodule SymphonyElixir.TemporalK3sRetryTest do
  use SymphonyElixir.TestSupport

  import SymphonyElixir.TestSupport.Scenarios,
    only: [
      issue_fixture: 1,
      put_app_env!: 2,
      put_env!: 2,
      start_agent!: 1,
      temporal_k3s_fixture!: 1,
      write_executable!: 2
    ]

  import SymphonyElixir.TestSupport.TemporalK3s

  alias SymphonyElixir.Execution.TemporalK3s
  alias SymphonyElixir.TestSupport.TemporalK3s.StatefulRetryOrgClient

  test "Orchestrator retries a failed remote run with fresh workflow and job identifiers" do
    %{test_root: helper_root, k3s_project_root: k3s_project_root} =
      temporal_k3s_fixture!("symphony-temporal-orchestrator-retry")

    put_app_env!(:org_client_module, StatefulRetryOrgClient)
    put_app_env!(:temporal_retry_test_recipient, self())

    issue_store =
      start_agent!([
        issue_fixture(
          id: "issue-remote-orchestrated-retry",
          identifier: "REV-15",
          title: "Retry through orchestrator",
          description: "Exercise the real retry path",
          state: "In Progress"
        )
      ])

    put_app_env!(:temporal_retry_issue_store, issue_store)

    helper_script = Path.join(helper_root, "fake-temporal-helper.py")
    helper_trace = Path.join(helper_root, "temporal-helper-trace.jsonl")

    write_executable!(
      helper_script,
      """
      #!/usr/bin/env python3
      import json
      import os
      import sys

      def load_json(path):
          with open(path, "r", encoding="utf-8") as handle:
              return json.load(handle)

      def write_json(path, payload):
          with open(path, "w", encoding="utf-8") as handle:
              json.dump(payload, handle)

      def append_event(path, payload):
          with open(path, "a", encoding="utf-8") as handle:
              handle.write(json.dumps(payload) + "\\n")

      def parse_input_path(argv):
          for index, arg in enumerate(argv):
              if arg == "--input":
                  return argv[index + 1]
          raise RuntimeError("--input argument missing")

      subcommand = sys.argv[1]
      payload = load_json(parse_input_path(sys.argv))
      trace_path = os.environ["SYMPHONY_TEMPORAL_TRACE"]
      state_path = trace_path + ".state.json"

      if os.path.exists(state_path):
          state = load_json(state_path)
      else:
          state = {"runs": []}

      if subcommand == "run":
          run_number = len(state["runs"]) + 1
          run_id = "run-%03d" % run_number
          run = {
              "run_number": run_number,
              "workflowId": payload["workflowId"],
              "projectId": payload["projectId"],
              "workspacePath": payload["paths"]["workspacePath"],
              "artifactDir": payload["paths"]["outputsPath"],
              "resultPath": payload["paths"]["resultPath"],
              "jobName": "symphony-job-" + payload["projectId"],
              "runId": run_id,
          }
          state["runs"].append(run)
          write_json(state_path, state)
          append_event(
              trace_path,
              {
                  "event": "run",
                  "workflowId": run["workflowId"],
                  "projectId": run["projectId"],
                  "jobName": run["jobName"],
                  "runId": run["runId"],
                  "workspacePath": run["workspacePath"],
              },
          )
          print(
              json.dumps(
                  {
                      "workflowId": run["workflowId"],
                      "runId": run["runId"],
                      "status": "queued",
                      "projectId": run["projectId"],
                      "workspacePath": run["workspacePath"],
                      "artifactDir": run["artifactDir"],
                      "jobName": run["jobName"],
                  }
              )
          )
      elif subcommand == "status":
          run = next(item for item in state["runs"] if item["workflowId"] == payload["workflowId"])
          append_event(
              trace_path,
              {
                  "event": "status",
                  "workflowId": run["workflowId"],
                  "projectId": run["projectId"],
                  "jobName": run["jobName"],
                  "runId": payload.get("runId"),
                  "run_number": run["run_number"],
              },
          )

          if run["run_number"] == 1:
              response = {
                  "workflowId": run["workflowId"],
                  "runId": run["runId"],
                  "status": "failed",
                  "projectId": run["projectId"],
                  "workspacePath": run["workspacePath"],
                  "artifactDir": run["artifactDir"],
                  "jobName": run["jobName"],
              }
          else:
              write_json(
                  run["resultPath"],
                  {
                      "status": "succeeded",
                      "targetState": "Done",
                      "summary": "Orchestrator retry succeeded with fresh identifiers.",
                      "validation": ["orchestrator retry identifier regression"],
                      "blockedReason": None,
                      "needsContinuation": False,
                  },
              )
              response = {
                  "workflowId": run["workflowId"],
                  "runId": run["runId"],
                  "status": "succeeded",
                  "projectId": run["projectId"],
                  "workspacePath": run["workspacePath"],
                  "artifactDir": run["artifactDir"],
                  "jobName": run["jobName"],
              }

          print(json.dumps(response))
      else:
          print(json.dumps({"workflowId": payload.get("workflowId"), "status": "unknown"}))
      """
    )

    put_env!("SYMPHONY_TEMPORAL_TRACE", helper_trace)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "orgmode",
      tracker_file: "/tmp/revision-plan.org",
      tracker_root_id: "root-id",
      execution_kind: "temporal_k3s",
      repository_origin_url: "https://example.com/repo.git",
      temporal_helper_command: helper_script,
      temporal_address: "temporal.example:7233",
      temporal_namespace: "customer-a",
      temporal_status_poll_ms: 1,
      poll_interval_ms: 5_000,
      max_retry_backoff_ms: 1,
      k3s_project_root: k3s_project_root
    )

    orchestrator_name = Module.concat(__MODULE__, :RemoteRetryOrchestrator)

    log =
      capture_log(fn ->
        {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

        on_exit(fn ->
          if Process.alive?(pid) do
            Process.exit(pid, :normal)
          end
        end)

        assert_eventually(
          fn ->
            match?({:ok, [_, _]}, orchestrated_retry_run_events(helper_trace))
          end,
          120
        )

        assert_receive {:org_set_task_state_called, "issue-remote-orchestrated-retry", "Done"},
                       1_000

        assert {:ok, [first_run, second_run]} = orchestrated_retry_run_events(helper_trace)

        assert first_run["workflowId"] == "issue/issue-remote-orchestrated-retry"
        assert first_run["projectId"] == "REV-15"
        assert first_run["jobName"] == "symphony-job-REV-15"

        assert second_run["workflowId"] != first_run["workflowId"]
        assert second_run["workflowId"] =~ "/attempt-1-"
        assert second_run["projectId"] != first_run["projectId"]
        assert String.starts_with?(second_run["projectId"], "REV-15-attempt-1-")
        assert second_run["jobName"] != first_run["jobName"]
        assert String.starts_with?(second_run["jobName"], "symphony-job-REV-15-attempt-1-")
        assert second_run["workspacePath"] != first_run["workspacePath"]
      end)

    assert log =~ "scheduling retry"
  end

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
