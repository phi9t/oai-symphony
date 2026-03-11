defmodule SymphonyElixir.TestSupport.RecoveryScenarioHarness do
  @moduledoc false

  import ExUnit.Assertions
  import ExUnit.CaptureLog

  alias SymphonyElixir.AgentRunner
  alias SymphonyElixir.Execution
  alias SymphonyElixir.Execution.TemporalK3s
  alias SymphonyElixir.Orchestrator
  alias SymphonyElixir.TestSupport
  alias SymphonyElixir.Tracker.Issue
  alias SymphonyElixir.Workflow

  @scenario_catalog [
    %{id: :restart_recovery, description: "restart recovery"},
    %{id: :cancellation, description: "cancellation"},
    %{id: :malformed_output, description: "malformed output"},
    %{id: :stuck_turn, description: "stuck turns"},
    %{id: :workspace_cleanup, description: "workspace cleanup"},
    %{id: :tracker_sync, description: "tracker sync attribution"}
  ]

  def scenarios(layer_map) when is_map(layer_map) do
    Enum.map(@scenario_catalog, fn scenario ->
      Map.put(scenario, :layer, Map.fetch!(layer_map, scenario.id))
    end)
  end

  defmacro define_scenarios(adapter_module) do
    adapter = Macro.expand(adapter_module, __CALLER__)

    tests =
      for %{id: id, layer: layer, description: description} <- adapter.scenarios() do
        test_name = "#{adapter.backend()} #{layer} recovery scenario: #{description}"

        quote do
          test unquote(test_name) do
            unquote(adapter).run_scenario(unquote(id))
          end
        end
      end

    {:__block__, [], tests}
  end

  def tmp_root(prefix) do
    root = Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    root
  end

  def write_executable!(path, contents) do
    File.write!(path, contents)
    File.chmod!(path, 0o755)
  end

  def restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  def restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
  def restore_env(key, nil), do: System.delete_env(key)
  def restore_env(key, value), do: System.put_env(key, value)

  def assert_due_in_range(due_at_ms, min_remaining_ms, max_remaining_ms) do
    remaining_ms = due_at_ms - System.monotonic_time(:millisecond)

    assert remaining_ms >= min_remaining_ms
    assert remaining_ms <= max_remaining_ms
  end

  def assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(25)
      assert_eventually(fun, attempts - 1)
    end
  end

  def assert_eventually(_fun, 0), do: flunk("condition not met in time")

  def orchestrated_retry_run_events(trace_path) do
    if File.exists?(trace_path) do
      runs =
        trace_path
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.map(&Jason.decode!/1)
        |> Enum.filter(&(&1["event"] == "run"))

      if length(runs) >= 2 do
        {:ok, Enum.take(runs, 2)}
      else
        :pending
      end
    else
      :pending
    end
  end

  def temporal_connection_payload?(payload) do
    Map.take(payload["temporal"] || %{}, ["address", "namespace"]) == %{
      "address" => "temporal.example:7233",
      "namespace" => "customer-a"
    }
  end

  def assert_temporal_connection_payload(payload) do
    assert temporal_connection_payload?(payload)
  end

  def local_issue(id, identifier, title, description) do
    %Issue{
      id: id,
      identifier: identifier,
      title: title,
      description: description,
      state: "In Progress",
      url: "https://example.org/issues/#{identifier}",
      labels: ["recovery"]
    }
  end

  defmodule LocalAdapter do
    import ExUnit.Assertions

    alias SymphonyElixir.AgentRunner
    alias SymphonyElixir.Execution
    alias SymphonyElixir.Orchestrator
    alias SymphonyElixir.TestSupport
    alias SymphonyElixir.TestSupport.RecoveryScenarioHarness
    alias SymphonyElixir.Tracker.Issue
    alias SymphonyElixir.Workflow

    def backend, do: "local"

    def scenarios do
      RecoveryScenarioHarness.scenarios(%{
        restart_recovery: "orchestrator",
        cancellation: "worker",
        malformed_output: "worker",
        stuck_turn: "worker",
        workspace_cleanup: "cleanup",
        tracker_sync: "tracker"
      })
    end

    def run_scenario(:restart_recovery) do
      TestSupport.write_workflow_file!(Workflow.workflow_file_path(),
        tracker_api_token: nil,
        codex_stall_timeout_ms: 1_000
      )

      issue_id = "issue-local-stall"
      orchestrator_name = Module.concat(__MODULE__, :RestartRecoveryOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      try do
        worker_pid =
          spawn(fn ->
            receive do
              :done -> :ok
            end
          end)

        stale_activity_at = DateTime.add(DateTime.utc_now(), -5, :second)
        initial_state = :sys.get_state(pid)

        running_entry = %{
          pid: worker_pid,
          ref: make_ref(),
          identifier: "LOC-STALL",
          issue: %Issue{id: issue_id, identifier: "LOC-STALL", state: "In Progress"},
          session_id: "thread-local-stall-turn-local-stall",
          last_codex_message: nil,
          last_codex_timestamp: stale_activity_at,
          last_codex_event: :notification,
          started_at: stale_activity_at
        }

        :sys.replace_state(pid, fn _ ->
          initial_state
          |> Map.put(:running, %{issue_id => running_entry})
          |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
        end)

        send(pid, :tick)
        Process.sleep(100)
        state = :sys.get_state(pid)

        refute Process.alive?(worker_pid)
        refute Map.has_key?(state.running, issue_id)

        assert %{
                 attempt: 1,
                 due_at_ms: due_at_ms,
                 identifier: "LOC-STALL",
                 error: "stalled for " <> _
               } = state.retry_attempts[issue_id]

        RecoveryScenarioHarness.assert_due_in_range(due_at_ms, 9_500, 10_500)
      after
        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end
      end
    end

    def run_scenario(:cancellation) do
      root = RecoveryScenarioHarness.tmp_root("symphony-local-cancel")

      try do
        workspace_root = Path.join(root, "workspaces")
        codex_binary = Path.join(root, "fake-codex")
        File.mkdir_p!(workspace_root)

        RecoveryScenarioHarness.write_executable!(
          codex_binary,
          """
          #!/bin/sh
          count=0
          while IFS= read -r _line; do
            count=$((count + 1))
            case "$count" in
              1)
                printf '%s\\n' '{"id":1,"result":{}}'
                ;;
              2)
                ;;
              3)
                printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-local-cancel"}}}'
                ;;
              4)
                printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-local-cancel"}}}'
                printf '%s\\n' '{"method":"turn/cancelled","params":{"reason":"operator"}}'
                exit 0
                ;;
              *)
                exit 0
                ;;
            esac
          done
          """
        )

        TestSupport.write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          codex_command: "#{codex_binary} app-server"
        )

        issue =
          RecoveryScenarioHarness.local_issue(
            "issue-local-cancel",
            "LOC-1",
            "Surface local cancellation",
            "Report turn cancellation through the worker layer"
          )

        assert_raise RuntimeError, ~r/turn_cancelled/, fn ->
          AgentRunner.run(issue, self())
        end

        assert_receive {:codex_worker_update, "issue-local-cancel", %{event: :session_started}}, 500

        assert_receive {:codex_worker_update, "issue-local-cancel", %{event: :turn_cancelled, details: %{"reason" => "operator"}}},
                       500
      after
        File.rm_rf(root)
      end
    end

    def run_scenario(:malformed_output) do
      root = RecoveryScenarioHarness.tmp_root("symphony-local-malformed")

      try do
        workspace_root = Path.join(root, "workspaces")
        codex_binary = Path.join(root, "fake-codex")
        File.mkdir_p!(workspace_root)

        RecoveryScenarioHarness.write_executable!(
          codex_binary,
          """
          #!/bin/sh
          count=0
          while IFS= read -r _line; do
            count=$((count + 1))
            case "$count" in
              1)
                printf '%s\\n' '{"id":1,"result":{}}'
                ;;
              2)
                ;;
              3)
                printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-local-malformed"}}}'
                ;;
              4)
                printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-local-malformed"}}}'
                printf '%s\\n' 'not-json'
                printf '%s\\n' '{"method":"turn/completed"}'
                exit 0
                ;;
              *)
                exit 0
                ;;
            esac
          done
          """
        )

        TestSupport.write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          codex_command: "#{codex_binary} app-server"
        )

        issue =
          RecoveryScenarioHarness.local_issue(
            "issue-local-malformed",
            "LOC-2",
            "Recover from malformed worker output",
            "Ignore malformed lines and continue the turn"
          )

        assert :ok =
                 AgentRunner.run(
                   issue,
                   self(),
                   issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "Done"}]} end
                 )

        assert_receive {:codex_worker_update, "issue-local-malformed", %{event: :session_started}}, 500

        assert_receive {:codex_worker_update, "issue-local-malformed", %{event: :malformed, payload: "not-json"}},
                       500
      after
        File.rm_rf(root)
      end
    end

    def run_scenario(:stuck_turn) do
      root = RecoveryScenarioHarness.tmp_root("symphony-local-timeout")

      try do
        workspace_root = Path.join(root, "workspaces")
        codex_binary = Path.join(root, "fake-codex")
        File.mkdir_p!(workspace_root)

        RecoveryScenarioHarness.write_executable!(
          codex_binary,
          """
          #!/bin/sh
          count=0
          while IFS= read -r _line; do
            count=$((count + 1))
            case "$count" in
              1)
                printf '%s\\n' '{"id":1,"result":{}}'
                ;;
              2)
                ;;
              3)
                printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-local-timeout"}}}'
                ;;
              4)
                printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-local-timeout"}}}'
                sleep 1
                ;;
              *)
                exit 0
                ;;
            esac
          done
          """
        )

        TestSupport.write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          codex_command: "#{codex_binary} app-server",
          codex_turn_timeout_ms: 10
        )

        issue =
          RecoveryScenarioHarness.local_issue(
            "issue-local-timeout",
            "LOC-3",
            "Timeout a stuck local turn",
            "Surface worker timeouts clearly"
          )

        assert_raise RuntimeError, ~r/turn_timeout/, fn ->
          AgentRunner.run(issue, self())
        end

        assert_receive {:codex_worker_update, "issue-local-timeout", %{event: :session_started}}, 500

        assert_receive {:codex_worker_update, "issue-local-timeout", %{event: :turn_ended_with_error, reason: :turn_timeout}},
                       500
      after
        File.rm_rf(root)
      end
    end

    def run_scenario(:workspace_cleanup) do
      root = RecoveryScenarioHarness.tmp_root("symphony-local-cleanup")

      try do
        workspace_root = Path.join(root, "workspaces")
        workspace_path = Path.join(workspace_root, "LOC-4")
        marker_path = Path.join(workspace_path, "marker.txt")

        File.mkdir_p!(workspace_path)
        File.write!(marker_path, "cleanup me")

        TestSupport.write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root
        )

        assert File.exists?(marker_path)
        assert :ok = Execution.cleanup_issue_workspace("LOC-4", %{execution_backend: "local"})
        refute File.exists?(workspace_path)
      after
        File.rm_rf(root)
      end
    end

    def run_scenario(:tracker_sync) do
      root = RecoveryScenarioHarness.tmp_root("symphony-local-tracker")

      try do
        workspace_root = Path.join(root, "workspaces")
        codex_binary = Path.join(root, "fake-codex")
        File.mkdir_p!(workspace_root)

        RecoveryScenarioHarness.write_executable!(
          codex_binary,
          """
          #!/bin/sh
          count=0
          while IFS= read -r _line; do
            count=$((count + 1))
            case "$count" in
              1)
                printf '%s\\n' '{"id":1,"result":{}}'
                ;;
              2)
                ;;
              3)
                printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-local-tracker"}}}'
                ;;
              4)
                printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-local-tracker"}}}'
                printf '%s\\n' '{"method":"turn/completed"}'
                exit 0
                ;;
              *)
                exit 0
                ;;
            esac
          done
          """
        )

        TestSupport.write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          codex_command: "#{codex_binary} app-server"
        )

        issue =
          RecoveryScenarioHarness.local_issue(
            "issue-local-tracker",
            "LOC-5",
            "Surface local tracker refresh failures",
            "Keep tracker failures distinct from worker failures"
          )

        assert_raise RuntimeError, ~r/issue_state_refresh_failed/, fn ->
          AgentRunner.run(
            issue,
            self(),
            issue_state_fetcher: fn [_issue_id] -> {:error, :tracker_refresh_failed} end
          )
        end

        assert_receive {:codex_worker_update, "issue-local-tracker", %{event: :session_started}}, 500
      after
        File.rm_rf(root)
      end
    end
  end

  defmodule TemporalAdapter do
    import ExUnit.Assertions
    import ExUnit.CaptureLog

    alias SymphonyElixir.Execution
    alias SymphonyElixir.Execution.TemporalK3s
    alias SymphonyElixir.Orchestrator
    alias SymphonyElixir.TestSupport
    alias SymphonyElixir.TestSupport.RecoveryScenarioHarness
    alias SymphonyElixir.Tracker.Issue
    alias SymphonyElixir.Workflow

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

    defmodule StatefulRetryOrgClient do
      alias SymphonyElixir.Config
      alias SymphonyElixir.Tracker.Issue

      def fetch_candidate_issues do
        {:ok, filter_issues(issue_entries(), Config.tracker_active_states())}
      end

      def fetch_issues_by_states(states) do
        {:ok, filter_issues(issue_entries(), states)}
      end

      def fetch_issue_states_by_ids(issue_ids) do
        wanted_ids = MapSet.new(issue_ids)

        {:ok,
         Enum.filter(issue_entries(), fn %Issue{id: id} ->
           MapSet.member?(wanted_ids, id)
         end)}
      end

      def get_task(issue_id), do: {:ok, %{id: issue_id}}

      def get_workpad(issue_id) do
        notify({:org_get_workpad_called, issue_id})
        {:ok, "workpad for #{issue_id}"}
      end

      def replace_workpad(issue_id, content) do
        notify({:org_replace_workpad_called, issue_id, content})
        {:ok, content}
      end

      def set_task_state(issue_id, state_name) do
        Agent.update(store(), fn issues ->
          Enum.map(issues, fn
            %Issue{id: ^issue_id} = issue -> %{issue | state: state_name}
            issue -> issue
          end)
        end)

        notify({:org_set_task_state_called, issue_id, state_name})
        {:ok, %{id: issue_id, state: state_name}}
      end

      defp issue_entries do
        Agent.get(store(), & &1)
      end

      defp filter_issues(issues, states) do
        normalized_states =
          states
          |> Enum.map(&normalize_state/1)
          |> MapSet.new()

        Enum.filter(issues, fn %Issue{state: state} ->
          MapSet.member?(normalized_states, normalize_state(state))
        end)
      end

      defp normalize_state(state) when is_binary(state) do
        state
        |> String.trim()
        |> String.downcase()
      end

      defp normalize_state(_state), do: ""

      defp store do
        Application.fetch_env!(:symphony_elixir, :temporal_harness_issue_store)
      end

      defp notify(message) do
        case Application.get_env(:symphony_elixir, :temporal_harness_test_recipient) do
          pid when is_pid(pid) -> send(pid, message)
          _ -> :ok
        end
      end
    end

    def backend, do: "temporal_k3s"

    def scenarios do
      RecoveryScenarioHarness.scenarios(%{
        restart_recovery: "orchestrator",
        cancellation: "helper",
        malformed_output: "helper",
        stuck_turn: "helper",
        workspace_cleanup: "cleanup",
        tracker_sync: "tracker"
      })
    end

    def run_scenario(:restart_recovery) do
      previous_org_client_module = Application.get_env(:symphony_elixir, :org_client_module)

      Application.put_env(:symphony_elixir, :org_client_module, StatefulRetryOrgClient)
      Application.put_env(:symphony_elixir, :temporal_harness_test_recipient, self())

      {:ok, issue_store} =
        Agent.start_link(fn ->
          [
            %Issue{
              id: "issue-remote-orchestrated-retry",
              identifier: "REV-15",
              title: "Retry through orchestrator",
              description: "Exercise the real retry path",
              state: "In Progress"
            }
          ]
        end)

      Application.put_env(:symphony_elixir, :temporal_harness_issue_store, issue_store)

      helper_root =
        RecoveryScenarioHarness.tmp_root("symphony-temporal-orchestrator-retry")

      helper_script = Path.join(helper_root, "fake-temporal-helper.py")
      helper_trace = Path.join(helper_root, "temporal-helper-trace.jsonl")
      k3s_project_root = Path.join(helper_root, "projects")
      previous_trace = System.get_env("SYMPHONY_TEMPORAL_TRACE")

      File.mkdir_p!(k3s_project_root)

      RecoveryScenarioHarness.write_executable!(
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

      System.put_env("SYMPHONY_TEMPORAL_TRACE", helper_trace)

      try do
        TestSupport.write_workflow_file!(Workflow.workflow_file_path(),
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

            try do
              RecoveryScenarioHarness.assert_eventually(
                fn ->
                  match?(
                    {:ok, [_, _]},
                    RecoveryScenarioHarness.orchestrated_retry_run_events(helper_trace)
                  )
                end,
                120
              )

              assert_receive {:org_set_task_state_called, "issue-remote-orchestrated-retry", "Done"},
                             1_000

              assert {:ok, [first_run, second_run]} =
                       RecoveryScenarioHarness.orchestrated_retry_run_events(helper_trace)

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
            after
              if Process.alive?(pid) do
                Process.exit(pid, :normal)
              end
            end
          end)

        assert log =~ "scheduling retry"
      after
        RecoveryScenarioHarness.restore_env("SYMPHONY_TEMPORAL_TRACE", previous_trace)
        RecoveryScenarioHarness.restore_app_env(:temporal_harness_test_recipient, nil)
        RecoveryScenarioHarness.restore_app_env(:temporal_harness_issue_store, nil)
        RecoveryScenarioHarness.restore_app_env(:org_client_module, previous_org_client_module)

        if Process.alive?(issue_store) do
          Agent.stop(issue_store)
        end

        File.rm_rf(helper_root)
      end
    end

    def run_scenario(:cancellation) do
      runner = fn _command, subcommand, payload ->
        send(self(), {:temporal_helper_called, subcommand, payload})
        {:ok, Jason.encode!(%{"workflowId" => payload["workflowId"], "status" => "cancelled"})}
      end

      TestSupport.write_workflow_file!(Workflow.workflow_file_path(),
        execution_kind: "temporal_k3s",
        repository_origin_url: "https://example.com/repo.git",
        temporal_address: "temporal.example:7233",
        temporal_namespace: "customer-a"
      )

      assert :ok = TemporalK3s.cancel(%{workflow_id: "issue/issue-remote"}, runner: runner)
      assert_receive {:temporal_helper_called, "cancel", payload}, 500
      RecoveryScenarioHarness.assert_temporal_connection_payload(payload)
    end

    def run_scenario(:malformed_output) do
      k3s_project_root = RecoveryScenarioHarness.tmp_root("symphony-temporal-malformed")

      try do
        TestSupport.write_workflow_file!(Workflow.workflow_file_path(),
          execution_kind: "temporal_k3s",
          repository_origin_url: "https://example.com/repo.git",
          temporal_address: "temporal.example:7233",
          temporal_namespace: "customer-a",
          k3s_project_root: k3s_project_root
        )

        issue = %Issue{
          id: "issue-temporal-malformed",
          identifier: "REV-16",
          title: "Surface malformed helper output",
          description: "Do not swallow invalid helper JSON",
          state: "In Progress"
        }

        runner = fn _command, subcommand, payload ->
          send(self(), {:temporal_helper_called, subcommand, payload})
          {:ok, "not-json"}
        end

        assert_raise RuntimeError, ~r/Temporal\/K3s run failed/, fn ->
          TemporalK3s.run(issue, self(), runner: runner)
        end

        assert_receive {:temporal_helper_called, "run", payload}, 500
        RecoveryScenarioHarness.assert_temporal_connection_payload(payload)
      after
        File.rm_rf(k3s_project_root)
      end
    end

    def run_scenario(:stuck_turn) do
      k3s_project_root = RecoveryScenarioHarness.tmp_root("symphony-temporal-timeout")

      try do
        TestSupport.write_workflow_file!(Workflow.workflow_file_path(),
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

        try do
          runner = fn _command, subcommand, payload ->
            case subcommand do
              "run" ->
                RecoveryScenarioHarness.assert_temporal_connection_payload(payload)

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
                RecoveryScenarioHarness.assert_temporal_connection_payload(payload)
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
        after
          if Process.alive?(runner_state) do
            Agent.stop(runner_state)
          end
        end
      after
        File.rm_rf(k3s_project_root)
      end
    end

    def run_scenario(:workspace_cleanup) do
      k3s_project_root = RecoveryScenarioHarness.tmp_root("symphony-temporal-cleanup")

      try do
        TestSupport.write_workflow_file!(Workflow.workflow_file_path(),
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
      after
        File.rm_rf(k3s_project_root)
      end
    end

    def run_scenario(:tracker_sync) do
      previous_org_client_module = Application.get_env(:symphony_elixir, :org_client_module)
      Application.put_env(:symphony_elixir, :org_client_module, FakeOrgStateFailureClient)
      k3s_project_root = RecoveryScenarioHarness.tmp_root("symphony-temporal-org-sync")

      try do
        TestSupport.write_workflow_file!(Workflow.workflow_file_path(),
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

        try do
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

          assert_receive {:org_get_workpad_called, "issue-org-sync"}, 500
          assert_receive {:org_replace_workpad_called, "issue-org-sync", ^final_workpad}, 500
          assert_receive {:org_set_task_state_called, "issue-org-sync", "Done"}, 500
        after
          if Process.alive?(runner_state) do
            Agent.stop(runner_state)
          end
        end
      after
        RecoveryScenarioHarness.restore_app_env(:org_client_module, previous_org_client_module)
        File.rm_rf(k3s_project_root)
      end
    end
  end
end
