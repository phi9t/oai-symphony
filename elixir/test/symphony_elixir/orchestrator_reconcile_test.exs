defmodule SymphonyElixir.OrchestratorReconcileTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Orchestrator.{Dispatch, Reconcile}

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
               %Issue{id: "issue-2", identifier: "MT-2", title: "other worker", state: "Todo", assigned_to_worker: false},
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
end
