defmodule SymphonyElixir.AgentRunnerTest do
  use SymphonyElixir.TestSupport

  import SymphonyElixir.TestSupport.Scenarios,
    only: [
      issue_fixture: 1,
      put_env!: 2,
      template_repo_fixture!: 2,
      workspace_fixture!: 1,
      write_executable!: 2
    ]

  test "agent runner keeps workspace after successful codex run" do
    %{test_root: test_root, workspace_root: workspace_root} =
      workspace_fixture!("symphony-elixir-agent-runner-retain-workspace")

    template_repo = template_repo_fixture!(test_root, %{"README.md" => "# test"})
    codex_binary = Path.join(test_root, "fake-codex")

    write_executable!(
      codex_binary,
      """
      #!/bin/sh
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        case "$count" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-1\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-1\"}}}'
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            ;;
        esac
      done
      """
    )

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
      codex_command: "#{codex_binary} app-server"
    )

    issue =
      issue_fixture(
        identifier: "S-99",
        title: "Smoke test",
        description: "Run and keep workspace",
        state: "In Progress",
        labels: ["backend"]
      )

    before = MapSet.new(File.ls!(workspace_root))

    assert :ok =
             AgentRunner.run(
               issue,
               nil,
               issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "Done"}]} end
             )

    entries_after = MapSet.new(File.ls!(workspace_root))

    created =
      MapSet.difference(entries_after, before)
      |> Enum.filter(&(&1 == "S-99"))
      |> MapSet.new()

    assert MapSet.size(created) == 1
    assert created |> Enum.to_list() |> List.first() == "S-99"

    workspace = Path.join(workspace_root, "S-99")
    assert File.exists?(workspace)
    assert File.exists?(Path.join(workspace, "README.md"))
  end

  test "agent runner forwards timestamped codex updates to recipient" do
    %{test_root: test_root, workspace_root: workspace_root} =
      workspace_fixture!("symphony-elixir-agent-runner-updates")

    template_repo = template_repo_fixture!(test_root, %{"README.md" => "# test"})
    codex_binary = Path.join(test_root, "fake-codex")

    write_executable!(
      codex_binary,
      """
      #!/bin/sh
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        case "$count" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-live\"}}}'
            ;;
          3)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-live\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            ;;
          *)
            ;;
        esac
      done
      """
    )

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
      codex_command: "#{codex_binary} app-server"
    )

    issue =
      issue_fixture(
        id: "issue-live-updates",
        identifier: "MT-99",
        title: "Smoke test",
        description: "Capture codex updates",
        state: "In Progress",
        labels: ["backend"]
      )

    test_pid = self()

    assert :ok =
             AgentRunner.run(
               issue,
               test_pid,
               issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "Done"}]} end
             )

    assert_receive {:codex_worker_update, "issue-live-updates",
                    %{
                      event: :session_started,
                      timestamp: %DateTime{},
                      session_id: session_id
                    }},
                   500

    assert session_id == "thread-live-turn-live"
  end

  test "agent runner continues with a follow-up turn while the issue remains active" do
    %{test_root: test_root, workspace_root: workspace_root} =
      workspace_fixture!("symphony-elixir-agent-runner-continuation")

    template_repo = template_repo_fixture!(test_root, %{"README.md" => "# test"})
    codex_binary = Path.join(test_root, "fake-codex")
    trace_file = Path.join(test_root, "codex.trace")

    write_executable!(
      codex_binary,
      """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex.trace}"
      run_id="$(date +%s%N)-$$"
      printf 'RUN:%s\\n' "$run_id" >> "$trace_file"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"
        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-cont"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-cont-1"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
          5)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-cont-2"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """
    )

    put_env!("SYMP_TEST_CODEx_TRACE", trace_file)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
      codex_command: "#{codex_binary} app-server",
      max_turns: 3
    )

    parent = self()

    state_fetcher = fn [_issue_id] ->
      attempt = Process.get(:agent_turn_fetch_count, 0) + 1
      Process.put(:agent_turn_fetch_count, attempt)
      send(parent, {:issue_state_fetch, attempt})

      state =
        if attempt == 1 do
          "In Progress"
        else
          "Done"
        end

      {:ok,
       [
         issue_fixture(
           id: "issue-continue",
           identifier: "MT-247",
           title: "Continue until done",
           description: "Still active after first turn",
           state: state
         )
       ]}
    end

    issue =
      issue_fixture(
        id: "issue-continue",
        identifier: "MT-247",
        title: "Continue until done",
        description: "Still active after first turn",
        state: "In Progress",
        labels: []
      )

    assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: state_fetcher)
    assert_receive {:issue_state_fetch, 1}
    assert_receive {:issue_state_fetch, 2}

    lines = File.read!(trace_file) |> String.split("\n", trim: true)

    assert length(Enum.filter(lines, &String.starts_with?(&1, "RUN:"))) == 1
    assert length(Enum.filter(lines, &String.contains?(&1, "\"method\":\"thread/start\""))) == 1

    turn_texts =
      lines
      |> Enum.filter(&String.starts_with?(&1, "JSON:"))
      |> Enum.map(&String.trim_leading(&1, "JSON:"))
      |> Enum.map(&Jason.decode!/1)
      |> Enum.filter(&(&1["method"] == "turn/start"))
      |> Enum.map(fn payload ->
        get_in(payload, ["params", "input"])
        |> Enum.map_join("\n", &Map.get(&1, "text", ""))
      end)

    assert length(turn_texts) == 2
    assert Enum.at(turn_texts, 0) =~ "You are an agent for this repository."
    refute Enum.at(turn_texts, 1) =~ "You are an agent for this repository."
    assert Enum.at(turn_texts, 1) =~ "Continuation guidance:"
    assert Enum.at(turn_texts, 1) =~ "continuation turn #2 of 3"
  end

  test "agent runner stops continuing once agent.max_turns is reached" do
    %{test_root: test_root, workspace_root: workspace_root} =
      workspace_fixture!("symphony-elixir-agent-runner-max-turns")

    template_repo = template_repo_fixture!(test_root, %{"README.md" => "# test"})
    codex_binary = Path.join(test_root, "fake-codex")
    trace_file = Path.join(test_root, "codex.trace")

    write_executable!(
      codex_binary,
      """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex.trace}"
      printf 'RUN\\n' >> "$trace_file"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"
        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-max"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-max-1"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
          5)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-max-2"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """
    )

    put_env!("SYMP_TEST_CODEx_TRACE", trace_file)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
      codex_command: "#{codex_binary} app-server",
      max_turns: 2
    )

    state_fetcher = fn [_issue_id] ->
      {:ok,
       [
         issue_fixture(
           id: "issue-max-turns",
           identifier: "MT-248",
           title: "Stop at max turns",
           description: "Still active",
           state: "In Progress"
         )
       ]}
    end

    issue =
      issue_fixture(
        id: "issue-max-turns",
        identifier: "MT-248",
        title: "Stop at max turns",
        description: "Still active",
        state: "In Progress",
        labels: []
      )

    assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: state_fetcher)

    trace = File.read!(trace_file)
    assert length(String.split(trace, "RUN", trim: true)) == 1
    assert length(Regex.scan(~r/"method":"turn\/start"/, trace)) == 2
  end
end
