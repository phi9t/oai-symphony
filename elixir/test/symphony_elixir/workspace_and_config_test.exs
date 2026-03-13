defmodule SymphonyElixir.WorkspaceAndConfigTest do
  use SymphonyElixir.TestSupport
  alias Ecto.Changeset
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Config.Schema.{Codex, StringOrMap}

  test "config reads defaults for optional settings" do
    previous_linear_api_key = System.get_env("LINEAR_API_KEY")
    on_exit(fn -> restore_env("LINEAR_API_KEY", previous_linear_api_key) end)
    System.delete_env("LINEAR_API_KEY")

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: nil,
      max_concurrent_agents: nil,
      codex_approval_policy: nil,
      codex_thread_sandbox: nil,
      codex_turn_sandbox_policy: nil,
      codex_turn_timeout_ms: nil,
      codex_read_timeout_ms: nil,
      codex_stall_timeout_ms: nil,
      tracker_api_token: nil,
      tracker_project_slug: nil
    )

    assert Config.linear_endpoint() == "https://api.linear.app/graphql"
    assert Config.linear_api_token() == nil
    assert Config.linear_project_slug() == nil
    assert Config.workspace_root() == config_default_workspace_root()
    assert Config.max_concurrent_agents() == 10
    assert Config.codex_command() == "codex app-server"

    assert Config.codex_approval_policy() == %{
             "reject" => %{
               "sandbox_approval" => true,
               "rules" => true,
               "mcp_elicitations" => true
             }
           }

    assert Config.codex_thread_sandbox() == "workspace-write"

    assert Config.codex_turn_sandbox_policy() == %{
             "type" => "workspaceWrite",
             "writableRoots" => [Path.expand(config_default_workspace_root())],
             "readOnlyAccess" => %{"type" => "fullAccess"},
             "networkAccess" => false,
             "excludeTmpdirEnvVar" => false,
             "excludeSlashTmp" => false
           }

    assert Config.codex_turn_timeout_ms() == 3_600_000
    assert Config.codex_read_timeout_ms() == 5_000
    assert Config.codex_stall_timeout_ms() == 300_000

    write_workflow_file!(Workflow.workflow_file_path(), codex_command: "codex app-server --model gpt-5.3-codex")
    assert Config.codex_command() == "codex app-server --model gpt-5.3-codex"

    write_workflow_file!(Workflow.workflow_file_path(),
      codex_approval_policy: "on-request",
      codex_thread_sandbox: "workspace-write",
      codex_turn_sandbox_policy: %{type: "workspaceWrite", writableRoots: ["/tmp/workspace", "/tmp/cache"]}
    )

    assert Config.codex_approval_policy() == "on-request"
    assert Config.codex_thread_sandbox() == "workspace-write"

    assert Config.codex_turn_sandbox_policy() == %{
             "type" => "workspaceWrite",
             "writableRoots" => ["/tmp/workspace", "/tmp/cache"]
           }

    write_workflow_file!(Workflow.workflow_file_path(), tracker_active_states: ",")
    assert Config.linear_active_states() == ["Todo", "In Progress"]

    write_workflow_file!(Workflow.workflow_file_path(), max_concurrent_agents: "bad")
    assert Config.max_concurrent_agents() == 10

    write_workflow_file!(Workflow.workflow_file_path(), codex_turn_timeout_ms: "bad")
    assert Config.codex_turn_timeout_ms() == 3_600_000

    write_workflow_file!(Workflow.workflow_file_path(), codex_read_timeout_ms: "bad")
    assert Config.codex_read_timeout_ms() == 5_000

    write_workflow_file!(Workflow.workflow_file_path(), codex_stall_timeout_ms: "bad")
    assert Config.codex_stall_timeout_ms() == 300_000

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_active_states: %{todo: true},
      tracker_terminal_states: %{done: true},
      poll_interval_ms: %{bad: true},
      workspace_root: 123,
      max_retry_backoff_ms: 0,
      max_concurrent_agents_by_state: %{"Todo" => "1", "Review" => 0, "Done" => "bad"},
      hook_timeout_ms: 0,
      observability_enabled: "maybe",
      observability_refresh_ms: %{bad: true},
      observability_render_interval_ms: %{bad: true},
      server_port: -1,
      server_host: 123
    )

    assert Config.linear_active_states() == ["Todo", "In Progress"]
    assert Config.linear_terminal_states() == ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"]
    assert Config.poll_interval_ms() == 30_000
    assert Config.workspace_root() == config_default_workspace_root()
    assert Config.max_retry_backoff_ms() == 300_000
    assert Config.max_concurrent_agents_for_state("Todo") == 1
    assert Config.max_concurrent_agents_for_state("Review") == 10
    assert Config.hook_timeout_ms() == 60_000
    assert Config.observability_enabled?()
    assert Config.observability_refresh_ms() == 1_000
    assert Config.observability_render_interval_ms() == 16
    assert Config.server_port() == nil
    assert Config.server_host() == "123"

    write_workflow_file!(Workflow.workflow_file_path(), codex_approval_policy: "")

    assert Config.codex_approval_policy() == %{
             "reject" => %{
               "sandbox_approval" => true,
               "rules" => true,
               "mcp_elicitations" => true
             }
           }

    assert {:error, {:invalid_codex_approval_policy, ""}} = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(), codex_thread_sandbox: "")
    assert Config.codex_thread_sandbox() == "workspace-write"
    assert {:error, {:invalid_codex_thread_sandbox, ""}} = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(), codex_turn_sandbox_policy: "bad")

    assert Config.codex_turn_sandbox_policy() == %{
             "type" => "workspaceWrite",
             "writableRoots" => [runtime_default_workspace_root()],
             "readOnlyAccess" => %{"type" => "fullAccess"},
             "networkAccess" => false,
             "excludeTmpdirEnvVar" => false,
             "excludeSlashTmp" => false
           }

    assert {:error, {:invalid_codex_turn_sandbox_policy, {:unsupported_value, "bad"}}} =
             Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(),
      codex_approval_policy: "future-policy",
      codex_thread_sandbox: "future-sandbox",
      codex_turn_sandbox_policy: %{
        type: "futureSandbox",
        nested: %{flag: true}
      }
    )

    assert Config.codex_approval_policy() == "future-policy"
    assert Config.codex_thread_sandbox() == "future-sandbox"

    assert Config.codex_turn_sandbox_policy() == %{
             "type" => "futureSandbox",
             "nested" => %{"flag" => true}
           }

    assert :ok = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(), codex_command: "codex app-server")
    assert Config.codex_command() == "codex app-server"
  end

  test "config resolves $VAR references for env-backed secret and path values" do
    workspace_env_var = "SYMP_WORKSPACE_ROOT_#{System.unique_integer([:positive])}"
    api_key_env_var = "SYMP_LINEAR_API_KEY_#{System.unique_integer([:positive])}"
    workspace_root = Path.join("/tmp", "symphony-workspace-root")
    api_key = "resolved-secret"
    codex_bin = Path.join(["~", "bin", "codex"])

    previous_workspace_root = System.get_env(workspace_env_var)
    previous_api_key = System.get_env(api_key_env_var)

    System.put_env(workspace_env_var, workspace_root)
    System.put_env(api_key_env_var, api_key)

    on_exit(fn ->
      restore_env(workspace_env_var, previous_workspace_root)
      restore_env(api_key_env_var, previous_api_key)
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: "$#{api_key_env_var}",
      workspace_root: "$#{workspace_env_var}",
      codex_command: "#{codex_bin} app-server"
    )

    assert Config.linear_api_token() == api_key
    assert Config.workspace_root() == Path.expand(workspace_root)
    assert Config.codex_command() == "#{codex_bin} app-server"
  end

  test "config no longer resolves legacy env: references" do
    workspace_env_var = "SYMP_WORKSPACE_ROOT_#{System.unique_integer([:positive])}"
    api_key_env_var = "SYMP_LINEAR_API_KEY_#{System.unique_integer([:positive])}"
    workspace_root = Path.join("/tmp", "symphony-workspace-root")
    api_key = "resolved-secret"

    previous_workspace_root = System.get_env(workspace_env_var)
    previous_api_key = System.get_env(api_key_env_var)

    System.put_env(workspace_env_var, workspace_root)
    System.put_env(api_key_env_var, api_key)

    on_exit(fn ->
      restore_env(workspace_env_var, previous_workspace_root)
      restore_env(api_key_env_var, previous_api_key)
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: "env:#{api_key_env_var}",
      workspace_root: "env:#{workspace_env_var}"
    )

    assert Config.linear_api_token() == "env:#{api_key_env_var}"
    assert Config.workspace_root() == "env:#{workspace_env_var}"
  end

  test "config supports per-state max concurrent agent overrides" do
    workflow = """
    ---
    agent:
      max_concurrent_agents: 10
      max_concurrent_agents_by_state:
        todo: 1
        "In Progress": 4
        "In Review": 2
    ---
    """

    File.write!(Workflow.workflow_file_path(), workflow)

    assert Config.max_concurrent_agents() == 10
    assert Config.max_concurrent_agents_for_state("Todo") == 1
    assert Config.max_concurrent_agents_for_state("In Progress") == 4
    assert Config.max_concurrent_agents_for_state("In Review") == 2
    assert Config.max_concurrent_agents_for_state("Closed") == 10
    assert Config.max_concurrent_agents_for_state(:not_a_string) == 10
  end

  test "schema helpers cover custom type and state limit validation" do
    assert StringOrMap.type() == :map
    assert StringOrMap.embed_as(:json) == :self
    assert StringOrMap.equal?(%{"a" => 1}, %{"a" => 1})
    refute StringOrMap.equal?(%{"a" => 1}, %{"a" => 2})

    assert {:ok, "value"} = StringOrMap.cast("value")
    assert {:ok, %{"a" => 1}} = StringOrMap.cast(%{"a" => 1})
    assert :error = StringOrMap.cast(123)

    assert {:ok, "value"} = StringOrMap.load("value")
    assert :error = StringOrMap.load(123)

    assert {:ok, %{"a" => 1}} = StringOrMap.dump(%{"a" => 1})
    assert :error = StringOrMap.dump(123)

    assert Schema.normalize_state_limits(nil) == %{}

    assert Schema.normalize_state_limits(%{"In Progress" => 2, todo: 1}) == %{
             "todo" => 1,
             "in progress" => 2
           }

    changeset =
      {%{}, %{limits: :map}}
      |> Changeset.cast(%{limits: %{"" => 1, "todo" => 0}}, [:limits])
      |> Schema.validate_state_limits(:limits)

    assert changeset.errors == [
             limits: {"state names must not be blank", []},
             limits: {"limits must be positive integers", []}
           ]
  end

  test "schema parse normalizes policy keys and env-backed fallbacks" do
    missing_workspace_env = "SYMP_MISSING_WORKSPACE_#{System.unique_integer([:positive])}"
    empty_secret_env = "SYMP_EMPTY_SECRET_#{System.unique_integer([:positive])}"
    missing_secret_env = "SYMP_MISSING_SECRET_#{System.unique_integer([:positive])}"

    previous_missing_workspace_env = System.get_env(missing_workspace_env)
    previous_empty_secret_env = System.get_env(empty_secret_env)
    previous_missing_secret_env = System.get_env(missing_secret_env)
    previous_linear_api_key = System.get_env("LINEAR_API_KEY")

    System.delete_env(missing_workspace_env)
    System.put_env(empty_secret_env, "")
    System.delete_env(missing_secret_env)
    System.put_env("LINEAR_API_KEY", "fallback-linear-token")

    on_exit(fn ->
      restore_env(missing_workspace_env, previous_missing_workspace_env)
      restore_env(empty_secret_env, previous_empty_secret_env)
      restore_env(missing_secret_env, previous_missing_secret_env)
      restore_env("LINEAR_API_KEY", previous_linear_api_key)
    end)

    assert {:ok, settings} =
             Schema.parse(%{
               tracker: %{api_key: "$#{empty_secret_env}"},
               workspace: %{root: "$#{missing_workspace_env}"},
               codex: %{approval_policy: %{reject: %{sandbox_approval: true}}}
             })

    assert settings.tracker.api_key == nil
    assert settings.workspace.root == runtime_default_workspace_root()

    assert settings.codex.approval_policy == %{
             "reject" => %{"sandbox_approval" => true}
           }

    assert {:ok, settings} =
             Schema.parse(%{
               tracker: %{api_key: "$#{missing_secret_env}"},
               workspace: %{root: ""}
             })

    assert settings.tracker.api_key == "fallback-linear-token"
    assert settings.workspace.root == runtime_default_workspace_root()
  end

  test "schema resolves sandbox policies from explicit and default workspaces" do
    explicit_policy = %{"type" => "workspaceWrite", "writableRoots" => ["/tmp/explicit"]}

    assert Schema.resolve_turn_sandbox_policy(%Schema{
             codex: %Codex{turn_sandbox_policy: explicit_policy},
             workspace: %Schema.Workspace{root: "/tmp/ignored"}
           }) == explicit_policy

    assert Schema.resolve_turn_sandbox_policy(%Schema{
             codex: %Codex{turn_sandbox_policy: nil},
             workspace: %Schema.Workspace{root: ""}
           }) == %{
             "type" => "workspaceWrite",
             "writableRoots" => [runtime_default_workspace_root()],
             "readOnlyAccess" => %{"type" => "fullAccess"},
             "networkAccess" => false,
             "excludeTmpdirEnvVar" => false,
             "excludeSlashTmp" => false
           }

    assert Schema.resolve_turn_sandbox_policy(
             %Schema{
               codex: %Codex{turn_sandbox_policy: nil},
               workspace: %Schema.Workspace{root: "/tmp/ignored"}
             },
             "/tmp/workspace"
           ) == %{
             "type" => "workspaceWrite",
             "writableRoots" => [Path.expand("/tmp/workspace")],
             "readOnlyAccess" => %{"type" => "fullAccess"},
             "networkAccess" => false,
             "excludeTmpdirEnvVar" => false,
             "excludeSlashTmp" => false
           }
  end

  test "repo fork self-landing workflow pins the fork landing contract" do
    workflow_path = repo_workflow_path!("fork-self-land-workflow.md")

    assert {:ok, %{config: config, prompt_template: prompt}} = Workflow.load(workflow_path)

    after_create = get_in(config, ["hooks", "after_create"])
    before_remove = get_in(config, ["hooks", "before_remove"])
    approval_policy = get_in(config, ["codex", "approval_policy"])
    thread_sandbox = get_in(config, ["codex", "thread_sandbox"])
    turn_sandbox_policy = get_in(config, ["codex", "turn_sandbox_policy"])

    assert after_create =~ "git remote set-url origin git@github.com:phi9t/oai-symphony.git"
    assert after_create =~ "git fetch origin main"
    assert after_create =~ ~S|git checkout -B "symphony/$(basename "$PWD")" origin/main|
    assert before_remove =~ "mix workspace.before_remove --repo phi9t/oai-symphony"
    assert approval_policy == "never"
    assert thread_sandbox == "workspace-write"
    assert turn_sandbox_policy["type"] == "workspaceWrite"
    assert turn_sandbox_policy["writableRoots"] == ["/mnt/data_infra/workspace/symphony/.symphony/workspaces"]
    assert turn_sandbox_policy["networkAccess"] == true

    assert prompt =~ "Use the repo-local `commit`, `push`, and `land` skills before ending a successful task."
    assert prompt =~ "Successful tasks must be committed, pushed, landed, and then moved to `Done`."

    assert prompt =~
             "Once the merge is complete, record the PR URL and merge commit in the workpad and set the task state to `Done`."
  end

  test "repo fork self-landing workflow bootstrap rewrites remotes in a new workspace" do
    test_root =
      Path.join([
        File.cwd!(),
        ".tmp-tests",
        "symphony-elixir-fork-self-land-bootstrap-#{System.unique_integer([:positive])}"
      ])

    previous_path = System.get_env("PATH")
    previous_git_log = System.get_env("GIT_LOG")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      restore_env("GIT_LOG", previous_git_log)
    end)

    try do
      workspace_root = Path.join(test_root, "workspaces")
      fake_bin = Path.join(test_root, "bin")
      fake_git = Path.join(fake_bin, "git")
      git_log = Path.join(test_root, "git.log")
      workflow_path = Path.join(test_root, "WORKFLOW.md")

      File.mkdir_p!(workspace_root)
      File.mkdir_p!(fake_bin)
      write_fake_git!(fake_git)

      workflow =
        repo_workflow_path!("fork-self-land-workflow.md")
        |> File.read!()
        |> String.replace(
          ~s(root: "/mnt/data_infra/workspace/symphony/.symphony/workspaces"),
          ~s(root: "#{workspace_root}")
        )
        |> String.replace("git ", "#{fake_git} ")

      File.write!(workflow_path, workflow)
      Workflow.set_workflow_file_path(workflow_path)
      if Process.whereis(SymphonyElixir.WorkflowStore), do: SymphonyElixir.WorkflowStore.force_reload()

      System.put_env("PATH", fake_bin <> ":" <> (previous_path || ""))
      System.put_env("GIT_LOG", git_log)

      assert {:ok, workspace} = Workspace.create_for_issue("REV-6")
      assert File.exists?(Path.join(workspace, "README.md"))

      log = File.read!(git_log)

      assert log =~ "remote set-url origin git@github.com:phi9t/oai-symphony.git"
      assert log =~ "remote get-url upstream"
      assert log =~ "remote add upstream https://github.com/openai/symphony.git"
      assert log =~ "fetch origin main"
      assert log =~ "checkout -B symphony/REV-6 origin/main"
    after
      File.rm_rf(test_root)
    end
  end

  test "repo fork self-landing workflow enables unattended networked codex turns" do
    original_workflow_path = Workflow.workflow_file_path()
    workflow_path = repo_workflow_path!("fork-self-land-workflow.md")
    workspace = Path.join("/tmp", "rev-6-networked-codex-workspace")

    on_exit(fn -> Workflow.set_workflow_file_path(original_workflow_path) end)

    :ok = Workflow.set_workflow_file_path(workflow_path)
    if Process.whereis(SymphonyElixir.WorkflowStore), do: SymphonyElixir.WorkflowStore.force_reload()

    assert {:ok, settings} = Config.codex_runtime_settings(workspace)
    assert settings.approval_policy == "never"
    assert settings.thread_sandbox == "workspace-write"

    assert settings.turn_sandbox_policy == %{
             "type" => "workspaceWrite",
             "writableRoots" => ["/mnt/data_infra/workspace/symphony/.symphony/workspaces"],
             "readOnlyAccess" => %{"type" => "fullAccess"},
             "networkAccess" => true,
             "excludeTmpdirEnvVar" => false,
             "excludeSlashTmp" => false
           }
  end

  test "runtime sandbox policy resolution passes explicit policies through unchanged" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-runtime-sandbox-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      issue_workspace = Path.join(workspace_root, "MT-100")
      File.mkdir_p!(issue_workspace)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_turn_sandbox_policy: %{
          type: "workspaceWrite",
          writableRoots: ["relative/path"],
          networkAccess: true
        }
      )

      assert {:ok, runtime_settings} = Config.codex_runtime_settings(issue_workspace)

      assert runtime_settings.turn_sandbox_policy == %{
               "type" => "workspaceWrite",
               "writableRoots" => ["relative/path"],
               "networkAccess" => true
             }

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_turn_sandbox_policy: %{
          type: "futureSandbox",
          nested: %{flag: true}
        }
      )

      assert {:ok, runtime_settings} = Config.codex_runtime_settings(issue_workspace)

      assert runtime_settings.turn_sandbox_policy == %{
               "type" => "futureSandbox",
               "nested" => %{"flag" => true}
             }
    after
      File.rm_rf(test_root)
    end
  end

  test "path safety returns errors for invalid path segments" do
    invalid_segment = String.duplicate("a", 300)
    path = Path.join(System.tmp_dir!(), invalid_segment)
    expanded_path = Path.expand(path)

    assert {:error, {:path_canonicalize_failed, ^expanded_path, :enametoolong}} =
             SymphonyElixir.PathSafety.canonicalize(path)
  end

  test "runtime sandbox policy resolution defaults when omitted and ignores workspace for explicit policies" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-runtime-sandbox-branches-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      issue_workspace = Path.join(workspace_root, "MT-101")

      File.mkdir_p!(issue_workspace)

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      settings = Config.settings!()

      assert {:ok, canonical_workspace_root} =
               SymphonyElixir.PathSafety.canonicalize(workspace_root)

      assert {:ok, default_policy} = Schema.resolve_runtime_turn_sandbox_policy(settings)
      assert default_policy["type"] == "workspaceWrite"
      assert default_policy["writableRoots"] == [canonical_workspace_root]

      read_only_settings = %{
        settings
        | codex: %{settings.codex | turn_sandbox_policy: %{"type" => "readOnly", "networkAccess" => true}}
      }

      assert {:ok, %{"type" => "readOnly", "networkAccess" => true}} =
               Schema.resolve_runtime_turn_sandbox_policy(read_only_settings, 123)

      future_settings = %{
        settings
        | codex: %{settings.codex | turn_sandbox_policy: %{"type" => "futureSandbox", "nested" => %{"flag" => true}}}
      }

      assert {:ok, %{"type" => "futureSandbox", "nested" => %{"flag" => true}}} =
               Schema.resolve_runtime_turn_sandbox_policy(future_settings, 123)

      assert {:error, {:unsafe_turn_sandbox_policy, {:invalid_workspace_root, 123}}} =
               Schema.resolve_runtime_turn_sandbox_policy(settings, 123)
    after
      File.rm_rf(test_root)
    end
  end

  test "workflow prompt is used when building base prompt" do
    workflow_prompt = "Workflow prompt body used as codex instruction."

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)
    assert Config.workflow_prompt() == workflow_prompt
  end

  defp repo_workflow_path!(name) do
    path =
      Path.join([
        Path.expand("../../..", __DIR__),
        ".symphony",
        name
      ])

    if File.regular?(path) do
      path
    else
      raise "expected repo workflow file at #{path}"
    end
  end

  defp write_fake_git!(path) do
    File.write!(
      path,
      """
      #!/bin/sh
      printf '%s\n' "$*" >> "$GIT_LOG"

      if [ "$1" = "remote" ] && [ "$2" = "get-url" ] && [ "$3" = "upstream" ]; then
        exit 1
      fi

      exit 0
      """
    )

    File.chmod!(path, 0o755)
  end

  defp config_default_workspace_root do
    Path.join("/tmp", "symphony_workspaces")
  end

  defp runtime_default_workspace_root do
    Path.expand(Path.join(System.tmp_dir!(), "symphony_workspaces"))
  end
end
