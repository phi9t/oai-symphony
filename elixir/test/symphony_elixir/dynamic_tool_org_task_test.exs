defmodule SymphonyElixir.Codex.DynamicToolOrgTaskTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.DynamicTool.OrgTask

  defmodule FakeOrgAdapter do
    def get_task("missing"), do: {:error, :org_task_not_found}
    def get_task("root-missing"), do: {:error, :org_root_not_found}
    def get_task(task_id), do: {:ok, %{"taskId" => task_id}}

    def update_issue_state("root-missing", _state), do: {:error, :org_root_not_found}
    def update_issue_state(_task_id, "Bad State"), do: {:error, :org_state_not_found}
    def update_issue_state(_task_id, "Boom"), do: {:error, :boom}
    def update_issue_state(_task_id, _state), do: :ok

    def get_workpad("missing"), do: {:error, :org_task_not_found}
    def get_workpad(task_id), do: {:ok, "workpad:#{task_id}"}

    def replace_workpad("emacs-status", _content), do: {:error, {:org_emacsclient_failed, 7, "boom"}}
    def replace_workpad(task_id, content), do: {:ok, "#{task_id}:#{content}"}

    def deep_dive("org-error", _content), do: {:error, {:org_error, "bad"}}
    def deep_dive(task_id, content), do: {:ok, %{"taskId" => task_id, "content" => content}}

    def deep_revision("emacs-reason", _mode, _content, _tasks), do: {:error, {:org_emacsclient_failed, :enoent}}

    def deep_revision(task_id, mode, content, tasks) do
      send(self(), {:deep_revision_called, task_id, mode, content, tasks})
      {:ok, %{"taskId" => task_id, "mode" => mode, "tasks" => tasks}}
    end
  end

  defp response_text(response) do
    response["contentItems"]
    |> hd()
    |> Map.fetch!("text")
  end

  defp response_json(response), do: Jason.decode!(response_text(response))

  test "tool metadata exposes the org task contract" do
    assert OrgTask.tool_name() == "org_task"
    assert %{"name" => "org_task", "inputSchema" => %{"required" => ["action"]}} = OrgTask.tool_spec()
  end

  test "replace_workpad, get_workpad, get_task, and set_state delegate to the org adapter" do
    response =
      OrgTask.execute(
        %{"action" => "replace_workpad", "taskId" => "REV-12", "content" => "notes"},
        org_adapter: FakeOrgAdapter
      )

    assert response["success"] == true
    assert response_json(response)["content"] == "REV-12:notes"

    assert OrgTask.execute(%{"action" => "get_workpad", "taskId" => "REV-12"}, org_adapter: FakeOrgAdapter)
           |> response_json()
           |> Map.fetch!("content") == "workpad:REV-12"

    assert OrgTask.execute(%{"action" => "get_task"}, issue: %Issue{id: "REV-12"}, org_adapter: FakeOrgAdapter)
           |> response_json()
           |> Map.fetch!("taskId") == "REV-12"

    assert OrgTask.execute(%{"action" => "set_state", "taskId" => "REV-12", "state" => " In Progress "}, org_adapter: FakeOrgAdapter)
           |> response_json()
           |> Map.fetch!("taskId") == "REV-12"
  end

  test "deep_dive and deep_revision format atom-key payloads before calling the org adapter" do
    deep_dive_response =
      OrgTask.execute(
        %{
          action: "deep_dive",
          taskId: "REV-12",
          summary: "Investigate control-plane boundaries",
          details: "   ",
          findings: ["Config owns too much", 2],
          risks: ["Merge conflicts"],
          openQuestions: ["How much API surface stays stable?"],
          recommendations: ["Keep entry points thin"],
          validation: ["mix test"]
        },
        org_adapter: FakeOrgAdapter
      )

    assert deep_dive_response["success"] == true
    assert response_json(deep_dive_response)["content"] =~ "### Summary"
    assert response_json(deep_dive_response)["content"] =~ "- 2"

    response =
      OrgTask.execute(
        %{
          action: "deep_revision",
          taskId: "REV-12",
          mode: "create",
          summary: "Need follow-on work",
          rationale: "Keep config loading isolated",
          uncertainty: "Naming can still shift",
          validation: ["mix dialyzer"],
          tasks: [
            %{
              identifier: "",
              title: "Split more config helpers",
              description: "Move remaining config normalization into its own module.",
              state: "",
              priority: 2,
              labels: ["elixir"],
              acceptanceCriteria: ["Loader owns normalization"],
              validation: ["mix test"],
              notes: ["Coordinate with docs"]
            }
          ]
        },
        org_adapter: FakeOrgAdapter
      )

    assert response["success"] == true

    assert_received {:deep_revision_called, "REV-12", "create", content, [task]}
    assert content =~ "Revision Summary"
    assert content =~ "Create clear follow-on tasks directly."
    assert task["title"] == "Split more config helpers"
    assert task["body"] =~ "Acceptance Criteria"
    assert task["state"] == "Backlog"
    assert task["identifier"] == nil
  end

  test "org task failures map to targeted error payloads" do
    assert OrgTask.execute("bad")["success"] == false

    cases = [
      {%{"action" => "unknown"}, [org_adapter: FakeOrgAdapter], "must be one of"},
      {%{"action" => "get_task"}, [org_adapter: FakeOrgAdapter], "requires `taskId`"},
      {%{"action" => "get_task", "taskId" => "   "}, [org_adapter: FakeOrgAdapter], "requires `taskId`"},
      {%{"action" => "set_state", "taskId" => "REV-12", "state" => "   "}, [org_adapter: FakeOrgAdapter], "`org_task.state`"},
      {%{"action" => "replace_workpad", "taskId" => "REV-12", "content" => 1}, [org_adapter: FakeOrgAdapter], "`org_task.content`"},
      {%{"action" => "deep_dive", "taskId" => "REV-12", "summary" => "   "}, [org_adapter: FakeOrgAdapter], "`org_task.summary`"},
      {%{"action" => "deep_revision", "taskId" => "REV-12", "summary" => "Need more work", "tasks" => [%{}]}, [org_adapter: FakeOrgAdapter], "`org_task.mode` is required"},
      {%{"action" => "deep_revision", "taskId" => "REV-12", "mode" => "ship", "summary" => "Need more work", "tasks" => [%{}]}, [org_adapter: FakeOrgAdapter],
       "`org_task.mode` must be `create` or `draft`"},
      {%{"action" => "deep_revision", "taskId" => "REV-12", "mode" => "draft", "summary" => "Need more work", "tasks" => []}, [org_adapter: FakeOrgAdapter],
       "`org_task.tasks` must contain at least one"},
      {%{"action" => "deep_revision", "taskId" => "REV-12", "mode" => "draft", "summary" => "Need more work", "tasks" => [1]}, [org_adapter: FakeOrgAdapter], "must be an object"},
      {%{
         "action" => "deep_revision",
         "taskId" => "REV-12",
         "mode" => "draft",
         "summary" => "Need more work",
         "tasks" => [%{"title" => "t", "description" => "d", "priority" => 2, "acceptanceCriteria" => [], "validation" => ["mix test"]}]
       }, [org_adapter: FakeOrgAdapter], "acceptanceCriteria"},
      {%{
         "action" => "deep_revision",
         "taskId" => "REV-12",
         "mode" => "draft",
         "summary" => "Need more work",
         "tasks" => [%{"title" => "t", "description" => "d", "priority" => 9, "acceptanceCriteria" => ["done"], "validation" => ["mix test"]}]
       }, [org_adapter: FakeOrgAdapter], "priority` must be 1, 2, or 3"},
      {%{"action" => "get_workpad", "taskId" => "missing"}, [org_adapter: FakeOrgAdapter], "was not found"},
      {%{"action" => "set_state", "taskId" => "root-missing", "state" => "In Progress"}, [org_adapter: FakeOrgAdapter], "root heading could not be found"},
      {%{"action" => "set_state", "taskId" => "REV-12", "state" => "Bad State"}, [org_adapter: FakeOrgAdapter], "requested Org state is not mapped"},
      {%{"action" => "replace_workpad", "taskId" => "emacs-status", "content" => "notes"}, [org_adapter: FakeOrgAdapter], "execution through `emacsclient` failed"},
      {%{
         "action" => "deep_revision",
         "taskId" => "emacs-reason",
         "mode" => "draft",
         "summary" => "Need more work",
         "tasks" => [%{"title" => "t", "description" => "d", "priority" => 2, "acceptanceCriteria" => ["done"], "validation" => ["mix test"]}]
       }, [org_adapter: FakeOrgAdapter], "execution through `emacsclient` failed"},
      {%{"action" => "deep_dive", "taskId" => "org-error", "summary" => "Need more work"}, [org_adapter: FakeOrgAdapter], "Org task tool execution failed"},
      {%{"action" => "set_state", "taskId" => "REV-12", "state" => "Boom"}, [org_adapter: FakeOrgAdapter], "Dynamic tool execution failed"}
    ]

    Enum.each(cases, fn {arguments, opts, expected} ->
      response = OrgTask.execute(arguments, opts)
      assert response["success"] == false
      assert response_text(response) =~ expected
    end)
  end
end
