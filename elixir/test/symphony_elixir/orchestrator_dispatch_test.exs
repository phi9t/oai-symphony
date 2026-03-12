defmodule SymphonyElixir.OrchestratorDispatchTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Orchestrator.Dispatch

  test "sort_issues orders by priority, created_at, and identifier" do
    now = DateTime.utc_now()

    issues = [
      %Issue{id: "3", identifier: "MT-300", title: "third", state: "Todo", priority: 2, created_at: now},
      %Issue{id: "2", identifier: "MT-200", title: "second", state: "Todo", priority: 1, created_at: DateTime.add(now, 60, :second)},
      %Issue{id: "1", identifier: "MT-100", title: "first", state: "Todo", priority: 1, created_at: now}
    ]

    assert Enum.map(Dispatch.sort_issues(issues), & &1.identifier) == ["MT-100", "MT-200", "MT-300"]
  end

  test "should_dispatch blocks todo issues with active blockers and respects per-state limits" do
    active_states = Dispatch.active_state_set(["Todo", "In Progress"])
    terminal_states = Dispatch.terminal_state_set(["Done"])

    blocked_issue = %Issue{
      id: "issue-1",
      identifier: "MT-1",
      title: "blocked",
      state: "Todo",
      blocked_by: [%{state: "In Progress"}]
    }

    refute Dispatch.should_dispatch?(blocked_issue, %{running: %{}, claimed: MapSet.new()}, active_states, terminal_states,
             available_slots: 1,
             state_limit_fun: fn _state_name -> 1 end
           )

    state_limited_issue = %Issue{
      id: "issue-2",
      identifier: "MT-2",
      title: "state limited",
      state: "In Progress"
    }

    running = %{
      "issue-3" => %{
        issue: %Issue{id: "issue-3", identifier: "MT-3", title: "running", state: "In Progress"}
      }
    }

    refute Dispatch.should_dispatch?(state_limited_issue, %{running: running, claimed: MapSet.new()}, active_states, terminal_states,
             available_slots: 1,
             state_limit_fun: fn
               "In Progress" -> 1
               _state_name -> 10
             end
           )
  end

  test "revalidate_issue_for_dispatch returns refreshed active issues and skips missing or terminal issues" do
    active_states = Dispatch.active_state_set(["Todo", "In Progress"])
    terminal_states = Dispatch.terminal_state_set(["Done"])

    issue = %Issue{id: "issue-1", identifier: "MT-1", title: "active", state: "Todo"}

    assert {:ok, %Issue{id: "issue-1", state: "In Progress"}} =
             Dispatch.revalidate_issue_for_dispatch(
               issue,
               fn [_issue_id] ->
                 {:ok, [%Issue{id: "issue-1", identifier: "MT-1", title: "active", state: "In Progress"}]}
               end,
               active_states,
               terminal_states
             )

    assert {:skip, %Issue{id: "issue-1", state: "Done"}} =
             Dispatch.revalidate_issue_for_dispatch(
               issue,
               fn [_issue_id] ->
                 {:ok, [%Issue{id: "issue-1", identifier: "MT-1", title: "active", state: "Done"}]}
               end,
               active_states,
               terminal_states
             )

    assert {:skip, :missing} =
             Dispatch.revalidate_issue_for_dispatch(
               issue,
               fn [_issue_id] -> {:ok, []} end,
               active_states,
               terminal_states
             )
  end

  test "dispatch helpers cover invalid inputs, error refreshes, and convenience wrappers" do
    active_states = Dispatch.active_state_set([" Todo "])
    terminal_states = Dispatch.terminal_state_set([" Done "])

    assert Dispatch.should_dispatch?(
             %Issue{id: "issue-10", identifier: "MT-10", title: "ready", state: "Todo"},
             %{running: %{}, claimed: MapSet.new()},
             active_states,
             terminal_states
           ) == false

    assert Dispatch.dispatch_slots_available?(
             %Issue{id: "issue-11", identifier: "MT-11", title: "ready", state: "Todo"},
             %{running: %{}}
           ) == false

    assert Dispatch.revalidate_issue_for_dispatch(
             %Issue{id: "issue-12", identifier: "MT-12", title: "ready", state: "Todo"},
             fn [_issue_id] -> {:error, :tracker_down} end,
             active_states,
             terminal_states
           ) == {:error, :tracker_down}

    passthrough_issue = %Issue{id: nil, identifier: "MT-13", title: "ready", state: "Todo"}

    assert Dispatch.revalidate_issue_for_dispatch(
             passthrough_issue,
             fn _ -> :ignored end,
             active_states,
             terminal_states
           ) == {:ok, passthrough_issue}

    assert Dispatch.should_dispatch?(%{}, %{}, active_states, terminal_states, []) == false
    assert Dispatch.retry_candidate_issue?(%{}, active_states, terminal_states) == false
    assert Dispatch.dispatch_slots_available?(%{}, %{}, available_slots: 1, state_limit_fun: fn _ -> 1 end) == false

    assert Dispatch.dispatch_slots_available?(
             %Issue{id: "issue-16", identifier: "MT-16", title: "ready", state: "Todo"},
             %{running: :invalid},
             available_slots: 1,
             state_limit_fun: :invalid
           ) == false

    assert Dispatch.dispatch_slots_available?(
             %Issue{id: "issue-17", identifier: "MT-17", title: "ready", state: "Todo"},
             %{running: %{"broken" => :entry}},
             available_slots: 1,
             state_limit_fun: fn _ -> 1 end
           )

    assert Dispatch.active_state_set(:invalid) == MapSet.new()
    assert Dispatch.terminal_state_set(:invalid) == MapSet.new()
    assert Dispatch.candidate_issue?(%{}, active_states, terminal_states) == false
    assert Dispatch.issue_routable_to_worker?(%{}) == true
    assert Dispatch.todo_issue_blocked_by_non_terminal?(%{}, terminal_states) == false

    assert Dispatch.todo_issue_blocked_by_non_terminal?(
             %Issue{id: "issue-14", identifier: "MT-14", title: "todo", state: "Todo", blocked_by: [%{}]},
             terminal_states
           )

    assert Dispatch.terminal_issue_state?(nil, terminal_states) == false
    assert Dispatch.active_issue_state?(nil, active_states) == false
    assert Dispatch.normalize_issue_state(nil) == ""

    sorted =
      Dispatch.sort_issues([
        %{},
        %Issue{id: "issue-15", identifier: "MT-15", title: "present", state: "Todo", priority: 4}
      ])

    assert match?(%Issue{}, hd(sorted))
  end
end
