defmodule SymphonyElixir.OrchestratorReconcileTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Orchestrator.{Dispatch, Reconcile}

  import SymphonyElixir.TestSupport.Scenarios,
    only: [issue_fixture: 1, put_app_env!: 2, workspace_fixture!: 1]

  test "non-active issue state stops running agent without cleaning workspace" do
    %{workspace_root: workspace_root} = workspace_fixture!("symphony-elixir-nonactive-reconcile")

    issue_id = "issue-1"
    issue_identifier = "MT-555"
    workspace = Path.join(workspace_root, issue_identifier)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      tracker_active_states: ["Todo", "In Progress", "In Review"],
      tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate"]
    )

    File.mkdir_p!(workspace)

    agent_pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    state = %Orchestrator.State{
      running: %{
        issue_id => %{
          pid: agent_pid,
          ref: nil,
          identifier: issue_identifier,
          issue: issue_fixture(id: issue_id, identifier: issue_identifier, state: "Todo"),
          started_at: DateTime.utc_now()
        }
      },
      claimed: MapSet.new([issue_id]),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue =
      issue_fixture(
        id: issue_id,
        identifier: issue_identifier,
        state: "Backlog",
        title: "Queued",
        description: "Not started",
        labels: []
      )

    updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)

    refute Map.has_key?(updated_state.running, issue_id)
    refute MapSet.member?(updated_state.claimed, issue_id)
    refute Process.alive?(agent_pid)
    assert File.exists?(workspace)
  end

  test "terminal issue state stops running agent and cleans workspace" do
    %{workspace_root: workspace_root} = workspace_fixture!("symphony-elixir-terminal-reconcile")

    issue_id = "issue-2"
    issue_identifier = "MT-556"
    workspace = Path.join(workspace_root, issue_identifier)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      tracker_active_states: ["Todo", "In Progress", "In Review"],
      tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate"]
    )

    File.mkdir_p!(workspace)

    agent_pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    state = %Orchestrator.State{
      running: %{
        issue_id => %{
          pid: agent_pid,
          ref: nil,
          identifier: issue_identifier,
          issue: issue_fixture(id: issue_id, identifier: issue_identifier, state: "In Progress"),
          started_at: DateTime.utc_now()
        }
      },
      claimed: MapSet.new([issue_id]),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue =
      issue_fixture(
        id: issue_id,
        identifier: issue_identifier,
        state: "Closed",
        title: "Done",
        description: "Completed",
        labels: []
      )

    updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)

    refute Map.has_key?(updated_state.running, issue_id)
    refute MapSet.member?(updated_state.claimed, issue_id)
    refute Process.alive?(agent_pid)
    refute File.exists?(workspace)
  end

  test "missing running issues stop active agents without cleaning the workspace" do
    %{workspace_root: workspace_root} =
      workspace_fixture!("symphony-elixir-missing-running-reconcile")

    issue_id = "issue-missing"
    issue_identifier = "MT-557"

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      tracker_active_states: ["Todo", "In Progress", "In Review"],
      tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate"],
      poll_interval_ms: 30_000
    )

    put_app_env!(:memory_tracker_issues, [])

    orchestrator_name = Module.concat(__MODULE__, :MissingRunningIssueOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    Process.sleep(50)

    assert {:ok, workspace} =
             SymphonyElixir.PathSafety.canonicalize(Path.join(workspace_root, issue_identifier))

    File.mkdir_p!(workspace)

    agent_pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: agent_pid,
      ref: nil,
      identifier: issue_identifier,
      issue: issue_fixture(id: issue_id, state: "In Progress", identifier: issue_identifier),
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(pid, :tick)
    Process.sleep(100)
    state = :sys.get_state(pid)

    refute Map.has_key?(state.running, issue_id)
    refute MapSet.member?(state.claimed, issue_id)
    refute Process.alive?(agent_pid)
    assert File.exists?(workspace)
  end

  test "reconcile updates running issue state for active issues" do
    issue_id = "issue-3"

    state = %Orchestrator.State{
      running: %{
        issue_id => %{
          pid: self(),
          ref: nil,
          identifier: "MT-557",
          issue: issue_fixture(id: issue_id, identifier: "MT-557", state: "Todo"),
          started_at: DateTime.utc_now()
        }
      },
      claimed: MapSet.new([issue_id]),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue =
      issue_fixture(
        id: issue_id,
        identifier: "MT-557",
        state: "In Progress",
        title: "Active state refresh",
        description: "State should be refreshed",
        labels: []
      )

    updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)
    updated_entry = updated_state.running[issue_id]

    assert Map.has_key?(updated_state.running, issue_id)
    assert MapSet.member?(updated_state.claimed, issue_id)
    assert updated_entry.issue.state == "In Progress"
  end

  test "reconcile stops running issue when it is reassigned away from this worker" do
    issue_id = "issue-reassigned"

    agent_pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    state = %Orchestrator.State{
      running: %{
        issue_id => %{
          pid: agent_pid,
          ref: nil,
          identifier: "MT-561",
          issue:
            issue_fixture(
              id: issue_id,
              identifier: "MT-561",
              state: "In Progress",
              assigned_to_worker: true
            ),
          started_at: DateTime.utc_now()
        }
      },
      claimed: MapSet.new([issue_id]),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue =
      issue_fixture(
        id: issue_id,
        identifier: "MT-561",
        state: "In Progress",
        title: "Reassigned active issue",
        description: "Worker should stop",
        labels: [],
        assigned_to_worker: false
      )

    updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)

    refute Map.has_key?(updated_state.running, issue_id)
    refute MapSet.member?(updated_state.claimed, issue_id)
    refute Process.alive?(agent_pid)
  end

  test "normal worker exit schedules active-state continuation retry" do
    issue_id = "issue-resume"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :ContinuationOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-558",
      issue: issue_fixture(id: issue_id, identifier: "MT-558", state: "In Progress"),
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(pid, {:DOWN, ref, :process, self(), :normal})
    Process.sleep(50)
    state = :sys.get_state(pid)

    refute Map.has_key?(state.running, issue_id)
    assert MapSet.member?(state.completed, issue_id)
    assert %{attempt: 1, due_at_ms: due_at_ms} = state.retry_attempts[issue_id]
    assert is_integer(due_at_ms)
    assert_due_in_range(due_at_ms, 0, 1_250)
  end

  test "abnormal worker exit increments retry attempt progressively" do
    issue_id = "issue-crash"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :CrashRetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-559",
      retry_attempt: 2,
      issue: issue_fixture(id: issue_id, identifier: "MT-559", state: "In Progress"),
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(pid, {:DOWN, ref, :process, self(), :boom})
    Process.sleep(50)
    state = :sys.get_state(pid)

    assert %{attempt: 3, due_at_ms: due_at_ms, identifier: "MT-559", error: "agent exited: :boom"} =
             state.retry_attempts[issue_id]

    assert_due_in_range(due_at_ms, 39_500, 40_500)
  end

  test "first abnormal worker exit waits before retrying" do
    issue_id = "issue-crash-initial"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :InitialCrashRetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-560",
      issue: issue_fixture(id: issue_id, identifier: "MT-560", state: "In Progress"),
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(pid, {:DOWN, ref, :process, self(), :boom})
    Process.sleep(50)
    state = :sys.get_state(pid)

    assert %{attempt: 1, due_at_ms: due_at_ms, identifier: "MT-560", error: "agent exited: :boom"} =
             state.retry_attempts[issue_id]

    assert_due_in_range(due_at_ms, 9_000, 10_500)
  end

  test "stale retry timer messages do not consume newer retry entries" do
    issue_id = "issue-stale-retry"
    orchestrator_name = Module.concat(__MODULE__, :StaleRetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)
    current_retry_token = make_ref()
    stale_retry_token = make_ref()

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:retry_attempts, %{
        issue_id => %{
          attempt: 2,
          timer_ref: nil,
          retry_token: current_retry_token,
          due_at_ms: System.monotonic_time(:millisecond) + 30_000,
          identifier: "MT-561",
          error: "agent exited: :boom"
        }
      })
    end)

    send(pid, {:retry_issue, issue_id, stale_retry_token})
    Process.sleep(50)

    assert %{
             attempt: 2,
             retry_token: ^current_retry_token,
             identifier: "MT-561",
             error: "agent exited: :boom"
           } = :sys.get_state(pid).retry_attempts[issue_id]
  end

  test "manual refresh coalesces repeated requests and ignores superseded ticks" do
    now_ms = System.monotonic_time(:millisecond)
    stale_tick_token = make_ref()

    state = %Orchestrator.State{
      poll_interval_ms: 30_000,
      max_concurrent_agents: 1,
      next_poll_due_at_ms: now_ms + 30_000,
      poll_check_in_progress: false,
      tick_timer_ref: nil,
      tick_token: stale_tick_token,
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      codex_rate_limits: nil
    }

    assert {:reply, %{queued: true, coalesced: false}, refreshed_state} =
             Orchestrator.handle_call(:request_refresh, {self(), make_ref()}, state)

    assert is_reference(refreshed_state.tick_timer_ref)
    assert is_reference(refreshed_state.tick_token)
    refute refreshed_state.tick_token == stale_tick_token
    assert refreshed_state.next_poll_due_at_ms <= System.monotonic_time(:millisecond)

    assert {:reply, %{queued: true, coalesced: true}, coalesced_state} =
             Orchestrator.handle_call(:request_refresh, {self(), make_ref()}, refreshed_state)

    assert coalesced_state.tick_token == refreshed_state.tick_token
    assert {:noreply, ^coalesced_state} = Orchestrator.handle_info({:tick, stale_tick_token}, coalesced_state)
  end

  test "issue_action classifies terminal, unroutable, active, and inactive issues" do
    active_states = Dispatch.active_state_set(["Todo", "In Progress"])
    terminal_states = Dispatch.terminal_state_set(["Done"])

    assert {:terminate, true, :terminal_state} =
             Reconcile.issue_action(
               %Issue{id: "issue-1", identifier: "MT-1", title: "done", state: "Done"},
               active_states,
               terminal_states
             )

    assert {:terminate, false, :unroutable} =
             Reconcile.issue_action(
               %Issue{
                 id: "issue-2",
                 identifier: "MT-2",
                 title: "other worker",
                 state: "Todo",
                 assigned_to_worker: false
               },
               active_states,
               terminal_states
             )

    assert :refresh =
             Reconcile.issue_action(
               %Issue{id: "issue-3", identifier: "MT-3", title: "active", state: "In Progress"},
               active_states,
               terminal_states
             )

    assert {:terminate, false, :inactive_state} =
             Reconcile.issue_action(
               %Issue{id: "issue-4", identifier: "MT-4", title: "waiting", state: "Blocked"},
               active_states,
               terminal_states
             )
  end

  test "missing_issue_ids returns running issues absent from the tracker refresh" do
    issues = [%Issue{id: "issue-1", identifier: "MT-1", title: "present", state: "Todo"}]

    assert Reconcile.missing_issue_ids(["issue-1", "issue-2"], issues) == ["issue-2"]
  end

  test "stall_elapsed_ms prefers the last codex activity timestamp" do
    now = DateTime.utc_now()
    started_at = DateTime.add(now, -120, :second)
    last_codex_timestamp = DateTime.add(now, -30, :second)
    running_entry = %{started_at: started_at, last_codex_timestamp: last_codex_timestamp}

    assert Reconcile.stall_elapsed_ms(running_entry, now) == 30_000
    assert Reconcile.last_activity_timestamp(running_entry) == last_codex_timestamp
    assert Reconcile.stalled?(running_entry, now, 10_000)
    refute Reconcile.stalled?(running_entry, now, 40_000)
  end

  test "reconcile helpers handle invalid inputs and missing activity timestamps" do
    now = DateTime.utc_now()

    assert Reconcile.issue_action(%{}, MapSet.new(), MapSet.new()) == :ignore
    assert Reconcile.missing_issue_ids(["issue-1"], [%{}]) == ["issue-1"]
    assert Reconcile.missing_issue_ids(:invalid, :invalid) == []
    assert Reconcile.stall_elapsed_ms(%{}, now) == nil
    assert Reconcile.stall_elapsed_ms(:invalid, now) == nil
    refute Reconcile.stalled?(%{}, now, 10_000)
    refute Reconcile.stalled?(%{started_at: now}, now, 0)
    assert Reconcile.last_activity_timestamp(:invalid) == nil
  end

  defp assert_due_in_range(due_at_ms, min_remaining_ms, max_remaining_ms) do
    remaining_ms = due_at_ms - System.monotonic_time(:millisecond)

    assert remaining_ms >= min_remaining_ms
    assert remaining_ms <= max_remaining_ms
  end
end
