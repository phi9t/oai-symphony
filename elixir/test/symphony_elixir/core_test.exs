defmodule SymphonyElixir.CoreTest do
  use SymphonyElixir.TestSupport

  test "config defaults and validation checks" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: nil,
      tracker_project_slug: nil,
      poll_interval_ms: nil,
      tracker_active_states: nil,
      tracker_terminal_states: nil,
      codex_command: nil
    )

    config = Config.settings!()
    assert config.polling.interval_ms == 30_000
    assert config.tracker.active_states == ["Todo", "In Progress"]
    assert config.tracker.terminal_states == ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"]
    assert config.tracker.assignee == nil
    assert config.agent.max_turns == 20

    write_workflow_file!(Workflow.workflow_file_path(), poll_interval_ms: "invalid")

    assert_raise ArgumentError, ~r/interval_ms/, fn ->
      Config.settings!().polling.interval_ms
    end

    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "polling.interval_ms"

    write_workflow_file!(Workflow.workflow_file_path(), poll_interval_ms: 45_000)
    assert Config.settings!().polling.interval_ms == 45_000

    write_workflow_file!(Workflow.workflow_file_path(), max_turns: 0)
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "agent.max_turns"

    write_workflow_file!(Workflow.workflow_file_path(), max_turns: 5)
    assert Config.settings!().agent.max_turns == 5

    write_workflow_file!(Workflow.workflow_file_path(), tracker_active_states: "Todo,  Review,")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "tracker.active_states"

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: "token",
      tracker_project_slug: nil
    )

    assert {:error, :missing_linear_project_slug} = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_project_slug: "project",
      codex_command: ""
    )

    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.command"
    assert message =~ "can't be blank"

    write_workflow_file!(Workflow.workflow_file_path(), codex_command: "   ")
    assert :ok = Config.validate!()
    assert Config.settings!().codex.command == "   "

    write_workflow_file!(Workflow.workflow_file_path(), codex_command: "/bin/sh app-server")
    assert :ok = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(), codex_approval_policy: "definitely-not-valid")
    assert :ok = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(), codex_thread_sandbox: "unsafe-ish")
    assert :ok = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(),
      codex_turn_sandbox_policy: %{type: "workspaceWrite", writableRoots: ["relative/path"]}
    )

    assert :ok = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(), codex_approval_policy: 123)
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.approval_policy"

    write_workflow_file!(Workflow.workflow_file_path(), codex_thread_sandbox: 123)
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.thread_sandbox"

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "123")
    assert {:error, {:unsupported_tracker_kind, "123"}} = Config.validate!()
  end

  test "orgmode config requires file, root id, and an available emacsclient command" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "orgmode",
      tracker_api_token: nil,
      tracker_project_slug: nil,
      tracker_file: nil,
      tracker_root_id: nil,
      tracker_emacsclient_command: "/definitely/missing/emacsclient"
    )

    assert {:error, :missing_org_tracker_file} = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "orgmode",
      tracker_api_token: nil,
      tracker_project_slug: nil,
      tracker_file: "/tmp/tasks.org",
      tracker_root_id: nil,
      tracker_emacsclient_command: "/definitely/missing/emacsclient"
    )

    assert {:error, :missing_org_tracker_root_id} = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "orgmode",
      tracker_api_token: nil,
      tracker_project_slug: nil,
      tracker_file: "/tmp/tasks.org",
      tracker_root_id: "ROOT-1",
      tracker_emacsclient_command: "/definitely/missing/emacsclient"
    )

    assert {:error, :missing_org_emacsclient} = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "orgmode",
      tracker_api_token: nil,
      tracker_project_slug: nil,
      tracker_file: "$SYMPHONY_TEST_ORG_FILE",
      tracker_root_id: "ROOT-1",
      tracker_emacsclient_command: "/bin/sh",
      tracker_state_map: %{"TODO" => "Todo", "IN_PROGRESS" => "In Progress"}
    )

    previous_org_file = System.get_env("SYMPHONY_TEST_ORG_FILE")
    on_exit(fn -> restore_env("SYMPHONY_TEST_ORG_FILE", previous_org_file) end)
    System.put_env("SYMPHONY_TEST_ORG_FILE", "/tmp/test-tasks.org")

    assert Config.org_file() == "/tmp/test-tasks.org"
    assert Config.org_root_id() == "ROOT-1"
    assert Config.org_emacsclient_command() == "/bin/sh"
    assert Config.org_state_map() == %{"TODO" => "Todo", "IN_PROGRESS" => "In Progress"}
    assert :ok = Config.validate!()
  end

  test "temporal_k3s config requires repository origin url and exposes remote settings" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "orgmode",
      tracker_api_token: nil,
      tracker_project_slug: nil,
      tracker_file: "/tmp/tasks.org",
      tracker_root_id: "ROOT-1",
      tracker_emacsclient_command: "/bin/sh",
      execution_kind: "temporal",
      repository_origin_url: nil
    )

    assert Config.execution_kind() == "temporal_k3s"
    assert {:error, :missing_repository_origin_url} = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "orgmode",
      tracker_api_token: nil,
      tracker_project_slug: nil,
      tracker_file: "/tmp/tasks.org",
      tracker_root_id: "ROOT-1",
      tracker_emacsclient_command: "/bin/sh",
      execution_kind: "temporal_k3s",
      temporal_helper_command: "./temporal/bin/symphony",
      repository_origin_url: "https://example.com/repo.git",
      repository_default_branch: "trunk",
      k3s_project_root: "/tmp/symphony-projects",
      k3s_shared_cache_root: "/tmp/symphony-cache"
    )

    assert Config.execution_kind() == "temporal_k3s"
    assert Config.temporal_helper_command() == "./temporal/bin/symphony"
    assert Config.temporal_workflow_mode() == "phased"
    assert Config.repository_origin_url() == "https://example.com/repo.git"
    assert Config.repository_default_branch() == "trunk"
    assert Config.k3s_project_root() == "/tmp/symphony-projects"
    assert Config.k3s_shared_cache_root() == "/tmp/symphony-cache"
    assert :ok = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "orgmode",
      tracker_api_token: nil,
      tracker_project_slug: nil,
      tracker_file: "/tmp/tasks.org",
      tracker_root_id: "ROOT-1",
      tracker_emacsclient_command: "/bin/sh",
      execution_kind: "temporal_k3s",
      temporal_helper_command: "./temporal/bin/symphony",
      temporal_workflow_mode: "vanilla",
      repository_origin_url: "https://example.com/repo.git"
    )

    assert Config.temporal_workflow_mode() == "vanilla"
    assert :ok = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "orgmode",
      tracker_api_token: nil,
      tracker_project_slug: nil,
      tracker_file: "/tmp/tasks.org",
      tracker_root_id: "ROOT-1",
      tracker_emacsclient_command: "/bin/sh",
      execution_kind: "temporal_k3s",
      temporal_helper_command: "./temporal/bin/symphony",
      temporal_workflow_mode: "not-a-mode",
      repository_origin_url: "https://example.com/repo.git"
    )

    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "workflow_mode"
  end

  test "current WORKFLOW.md file is valid and complete" do
    original_workflow_path = Workflow.workflow_file_path()
    on_exit(fn -> Workflow.set_workflow_file_path(original_workflow_path) end)
    Workflow.clear_workflow_file_path()

    assert {:ok, %{config: config, prompt: prompt}} = Workflow.load()
    assert is_map(config)

    tracker = Map.get(config, "tracker", %{})
    assert is_map(tracker)
    assert Map.get(tracker, "kind") == "orgmode"
    assert is_binary(Map.get(tracker, "file"))
    assert is_binary(Map.get(tracker, "root_id"))
    assert is_list(Map.get(tracker, "active_states"))
    assert is_list(Map.get(tracker, "terminal_states"))
    assert is_map(Map.get(tracker, "state_map"))

    execution = Map.get(config, "execution", %{})
    assert is_map(execution)
    assert Map.get(execution, "kind") == "temporal_k3s"

    temporal = Map.get(config, "temporal", %{})
    assert is_map(temporal)
    assert is_binary(Map.get(temporal, "helper_command"))
    assert Map.get(temporal, "workflow_mode") == "phased"

    repository = Map.get(config, "repository", %{})
    assert is_map(repository)
    assert is_binary(Map.get(repository, "origin_url"))
    assert is_binary(Map.get(repository, "default_branch"))

    hooks = Map.get(config, "hooks", %{})
    assert is_map(hooks)
    assert Map.get(hooks, "before_remove") =~ "cd elixir && mise exec -- mix workspace.before_remove"

    assert String.trim(prompt) != ""
    assert is_binary(Config.workflow_prompt())
    assert Config.workflow_prompt() == prompt
  end

  test "linear api token resolves from LINEAR_API_KEY env var" do
    previous_linear_api_key = System.get_env("LINEAR_API_KEY")
    env_api_key = "test-linear-api-key"

    on_exit(fn -> restore_env("LINEAR_API_KEY", previous_linear_api_key) end)
    System.put_env("LINEAR_API_KEY", env_api_key)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: nil,
      tracker_project_slug: "project",
      codex_command: "/bin/sh app-server"
    )

    assert Config.settings!().tracker.api_key == env_api_key
    assert Config.settings!().tracker.project_slug == "project"
    assert :ok = Config.validate!()
  end

  test "linear assignee resolves from LINEAR_ASSIGNEE env var" do
    previous_linear_assignee = System.get_env("LINEAR_ASSIGNEE")
    env_assignee = "dev@example.com"

    on_exit(fn -> restore_env("LINEAR_ASSIGNEE", previous_linear_assignee) end)
    System.put_env("LINEAR_ASSIGNEE", env_assignee)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_assignee: nil,
      tracker_project_slug: "project",
      codex_command: "/bin/sh app-server"
    )

    assert Config.settings!().tracker.assignee == env_assignee
  end

  test "workflow file path defaults to WORKFLOW.md in the current working directory when app env is unset" do
    original_workflow_path = Workflow.workflow_file_path()

    on_exit(fn ->
      Workflow.set_workflow_file_path(original_workflow_path)
    end)

    Workflow.clear_workflow_file_path()

    assert Workflow.workflow_file_path() == Path.join(File.cwd!(), "WORKFLOW.md")
  end

  test "workflow file path resolves from app env when set" do
    app_workflow_path = "/tmp/app/WORKFLOW.md"

    on_exit(fn ->
      Workflow.clear_workflow_file_path()
    end)

    Workflow.set_workflow_file_path(app_workflow_path)

    assert Workflow.workflow_file_path() == app_workflow_path
  end

  test "workflow load accepts prompt-only files without front matter" do
    workflow_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "PROMPT_ONLY_WORKFLOW.md")
    File.write!(workflow_path, "Prompt only\n")

    assert {:ok, %{config: %{}, prompt: "Prompt only", prompt_template: "Prompt only"}} =
             Workflow.load(workflow_path)
  end

  test "workflow load accepts unterminated front matter with an empty prompt" do
    workflow_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "UNTERMINATED_WORKFLOW.md")
    File.write!(workflow_path, "---\ntracker:\n  kind: linear\n")

    assert {:ok, %{config: %{"tracker" => %{"kind" => "linear"}}, prompt: "", prompt_template: ""}} =
             Workflow.load(workflow_path)
  end

  test "workflow load rejects non-map front matter" do
    workflow_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "INVALID_FRONT_MATTER_WORKFLOW.md")
    File.write!(workflow_path, "---\n- not-a-map\n---\nPrompt body\n")

    assert {:error, :workflow_front_matter_not_a_map} = Workflow.load(workflow_path)
  end

  test "SymphonyElixir.start_link delegates to the orchestrator" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    orchestrator_pid = Process.whereis(SymphonyElixir.Orchestrator)

    on_exit(fn ->
      if is_nil(Process.whereis(SymphonyElixir.Orchestrator)) do
        case Supervisor.restart_child(SymphonyElixir.Supervisor, SymphonyElixir.Orchestrator) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
        end
      end
    end)

    if is_pid(orchestrator_pid) do
      assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.Orchestrator)
    end

    assert {:ok, pid} = SymphonyElixir.start_link()
    assert Process.whereis(SymphonyElixir.Orchestrator) == pid

    GenServer.stop(pid)
  end

  test "linear issue state reconciliation fetch with no running issues is a no-op" do
    assert {:ok, []} = Client.fetch_issue_states_by_ids([])
  end
end

defmodule SymphonyElixir.CoreRecoveryScenarioHarnessTest do
  use SymphonyElixir.TestSupport

  import SymphonyElixir.TestSupport.RecoveryScenarioHarness

  define_scenarios(SymphonyElixir.TestSupport.RecoveryScenarioHarness.LocalAdapter)
end
