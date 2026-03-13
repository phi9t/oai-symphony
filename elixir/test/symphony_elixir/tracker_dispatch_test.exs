defmodule SymphonyElixir.TrackerDispatchTest do
  use SymphonyElixir.TestSupport

  import SymphonyElixir.TestSupport.Scenarios, only: [issue_fixture: 1]

  test "linear issue helpers" do
    issue =
      issue_fixture(
        id: "abc",
        labels: ["frontend", "infra"],
        assigned_to_worker: false
      )

    assert Issue.label_names(issue) == ["frontend", "infra"]
    assert issue.labels == ["frontend", "infra"]
    refute issue.assigned_to_worker
  end

  test "linear client normalizes blockers from inverse relations" do
    raw_issue = %{
      "id" => "issue-1",
      "identifier" => "MT-1",
      "title" => "Blocked todo",
      "description" => "Needs dependency",
      "priority" => 2,
      "state" => %{"name" => "Todo"},
      "branchName" => "mt-1",
      "url" => "https://example.org/issues/MT-1",
      "assignee" => %{"id" => "user-1"},
      "labels" => %{"nodes" => [%{"name" => "Backend"}]},
      "inverseRelations" => %{
        "nodes" => [
          %{
            "type" => "blocks",
            "issue" => %{
              "id" => "issue-2",
              "identifier" => "MT-2",
              "state" => %{"name" => "In Progress"}
            }
          },
          %{
            "type" => "relatesTo",
            "issue" => %{
              "id" => "issue-3",
              "identifier" => "MT-3",
              "state" => %{"name" => "Done"}
            }
          }
        ]
      },
      "createdAt" => "2026-01-01T00:00:00Z",
      "updatedAt" => "2026-01-02T00:00:00Z"
    }

    issue = Client.normalize_issue_for_test(raw_issue, "user-1")

    assert issue.blocked_by == [%{id: "issue-2", identifier: "MT-2", state: "In Progress"}]
    assert issue.labels == ["backend"]
    assert issue.priority == 2
    assert issue.state == "Todo"
    assert issue.assignee_id == "user-1"
    assert issue.assigned_to_worker
  end

  test "linear client marks explicitly unassigned issues as not routed to worker" do
    raw_issue = %{
      "id" => "issue-99",
      "identifier" => "MT-99",
      "title" => "Someone else's task",
      "state" => %{"name" => "Todo"},
      "assignee" => %{"id" => "user-2"}
    }

    issue = Client.normalize_issue_for_test(raw_issue, "user-1")

    refute issue.assigned_to_worker
  end

  test "linear client pagination merge helper preserves issue ordering" do
    issue_page_1 = [
      issue_fixture(id: "issue-1", identifier: "MT-1"),
      issue_fixture(id: "issue-2", identifier: "MT-2")
    ]

    issue_page_2 = [
      issue_fixture(id: "issue-3", identifier: "MT-3")
    ]

    merged = Client.merge_issue_pages_for_test([issue_page_1, issue_page_2])

    assert Enum.map(merged, & &1.identifier) == ["MT-1", "MT-2", "MT-3"]
  end

  test "linear client logs response bodies for non-200 graphql responses" do
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, {:linear_api_status, 400}} =
                 Client.graphql(
                   "query Viewer { viewer { id } }",
                   %{},
                   request_fun: fn _payload, _headers ->
                     {:ok,
                      %{
                        status: 400,
                        body: %{
                          "errors" => [
                            %{
                              "message" => "Variable \"$ids\" got invalid value",
                              "extensions" => %{"code" => "BAD_USER_INPUT"}
                            }
                          ]
                        }
                      }}
                   end
                 )
      end)

    assert log =~ "Linear GraphQL request failed status=400"
    assert log =~ ~s(body=%{"errors" => [%{"extensions" => %{"code" => "BAD_USER_INPUT"})
    assert log =~ "Variable \\\"$ids\\\" got invalid value"
  end

  test "fetch issues by states with empty state set is a no-op" do
    assert {:ok, []} = Client.fetch_issues_by_states([])
  end

  test "orchestrator sorts dispatch by priority then oldest created_at" do
    issue_same_priority_older =
      issue_fixture(
        id: "issue-old-high",
        identifier: "MT-200",
        title: "Old high priority",
        state: "Todo",
        priority: 1,
        created_at: ~U[2026-01-01 00:00:00Z]
      )

    issue_same_priority_newer =
      issue_fixture(
        id: "issue-new-high",
        identifier: "MT-201",
        title: "New high priority",
        state: "Todo",
        priority: 1,
        created_at: ~U[2026-01-02 00:00:00Z]
      )

    issue_lower_priority_older =
      issue_fixture(
        id: "issue-old-low",
        identifier: "MT-199",
        title: "Old lower priority",
        state: "Todo",
        priority: 2,
        created_at: ~U[2025-12-01 00:00:00Z]
      )

    sorted =
      Orchestrator.sort_issues_for_dispatch_for_test([
        issue_lower_priority_older,
        issue_same_priority_newer,
        issue_same_priority_older
      ])

    assert Enum.map(sorted, & &1.identifier) == ["MT-200", "MT-201", "MT-199"]
  end

  test "todo issue with non-terminal blocker is not dispatch-eligible" do
    state = %Orchestrator.State{
      max_concurrent_agents: 3,
      running: %{},
      claimed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue =
      issue_fixture(
        id: "blocked-1",
        identifier: "MT-1001",
        title: "Blocked work",
        state: "Todo",
        blocked_by: [%{id: "blocker-1", identifier: "MT-1002", state: "In Progress"}]
      )

    refute Orchestrator.should_dispatch_issue_for_test(issue, state)
  end

  test "issue assigned to another worker is not dispatch-eligible" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_assignee: "dev@example.com")

    state = %Orchestrator.State{
      max_concurrent_agents: 3,
      running: %{},
      claimed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue =
      issue_fixture(
        id: "assigned-away-1",
        identifier: "MT-1007",
        title: "Owned elsewhere",
        state: "Todo",
        assigned_to_worker: false
      )

    refute Orchestrator.should_dispatch_issue_for_test(issue, state)
  end

  test "todo issue with terminal blockers remains dispatch-eligible" do
    state = %Orchestrator.State{
      max_concurrent_agents: 3,
      running: %{},
      claimed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue =
      issue_fixture(
        id: "ready-1",
        identifier: "MT-1003",
        title: "Ready work",
        state: "Todo",
        blocked_by: [%{id: "blocker-2", identifier: "MT-1004", state: "Closed"}]
      )

    assert Orchestrator.should_dispatch_issue_for_test(issue, state)
  end

  test "dispatch revalidation skips stale todo issue once a non-terminal blocker appears" do
    stale_issue =
      issue_fixture(
        id: "blocked-2",
        identifier: "MT-1005",
        title: "Stale blocked work",
        state: "Todo",
        blocked_by: []
      )

    refreshed_issue =
      issue_fixture(
        id: "blocked-2",
        identifier: "MT-1005",
        title: "Stale blocked work",
        state: "Todo",
        blocked_by: [%{id: "blocker-3", identifier: "MT-1006", state: "In Progress"}]
      )

    fetcher = fn ["blocked-2"] -> {:ok, [refreshed_issue]} end

    assert {:skip, %Issue{} = skipped_issue} =
             Orchestrator.revalidate_issue_for_dispatch_for_test(stale_issue, fetcher)

    assert skipped_issue.identifier == "MT-1005"
    assert skipped_issue.blocked_by == [%{id: "blocker-3", identifier: "MT-1006", state: "In Progress"}]
  end
end
