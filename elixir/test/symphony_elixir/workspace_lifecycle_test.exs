defmodule SymphonyElixir.WorkspaceLifecycleTest do
  use SymphonyElixir.TestSupport

  import SymphonyElixir.TestSupport.Scenarios,
    only: [put_app_env!: 2, workspace_fixture!: 1]

  @tag :smoke
  test "workspace bootstrap can be implemented in after_create hook" do
    %{test_root: test_root, workspace_root: workspace_root} =
      workspace_fixture!("symphony-elixir-workspace-hook-bootstrap")

    template_repo = Path.join(test_root, "source")
    File.mkdir_p!(Path.join(template_repo, "keep"))
    File.write!(Path.join([template_repo, "keep", "file.txt"]), "keep me")
    File.write!(Path.join(template_repo, "README.md"), "hook copy\n")

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      hook_after_create: "cp -R #{template_repo}/. ."
    )

    assert {:ok, workspace} = Workspace.create_for_issue("S-1")
    assert File.read!(Path.join(workspace, "README.md")) == "hook copy\n"
    assert File.read!(Path.join([workspace, "keep", "file.txt"])) == "keep me"
  end

  test "workspace path is deterministic per issue identifier" do
    %{workspace_root: workspace_root} =
      workspace_fixture!("symphony-elixir-workspace-deterministic")

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    assert {:ok, first_workspace} = Workspace.create_for_issue("MT/Det")
    assert {:ok, second_workspace} = Workspace.create_for_issue("MT/Det")

    assert first_workspace == second_workspace
    assert Path.basename(first_workspace) == "MT_Det"
  end

  test "workspace reuses existing issue directory without deleting local changes" do
    %{workspace_root: workspace_root} = workspace_fixture!("symphony-elixir-workspace-reuse")

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      hook_after_create: "echo first > README.md"
    )

    assert {:ok, first_workspace} = Workspace.create_for_issue("MT-REUSE")

    File.write!(Path.join(first_workspace, "README.md"), "changed\n")
    File.write!(Path.join(first_workspace, "local-progress.txt"), "in progress\n")
    File.mkdir_p!(Path.join(first_workspace, "deps"))
    File.mkdir_p!(Path.join(first_workspace, "_build"))
    File.mkdir_p!(Path.join(first_workspace, "tmp"))
    File.write!(Path.join([first_workspace, "deps", "cache.txt"]), "cached deps\n")
    File.write!(Path.join([first_workspace, "_build", "artifact.txt"]), "compiled artifact\n")
    File.write!(Path.join([first_workspace, "tmp", "scratch.txt"]), "remove me\n")

    assert {:ok, second_workspace} = Workspace.create_for_issue("MT-REUSE")
    assert second_workspace == first_workspace
    assert File.read!(Path.join(second_workspace, "README.md")) == "changed\n"
    assert File.read!(Path.join(second_workspace, "local-progress.txt")) == "in progress\n"
    assert File.read!(Path.join([second_workspace, "deps", "cache.txt"])) == "cached deps\n"
    assert File.read!(Path.join([second_workspace, "_build", "artifact.txt"])) == "compiled artifact\n"
    refute File.exists?(Path.join([second_workspace, "tmp", "scratch.txt"]))
  end

  test "workspace replaces stale non-directory paths" do
    %{workspace_root: workspace_root} =
      workspace_fixture!("symphony-elixir-workspace-stale-path")

    stale_workspace = Path.join(workspace_root, "MT-STALE")
    File.write!(stale_workspace, "old state\n")

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    assert {:ok, workspace} = Workspace.create_for_issue("MT-STALE")
    assert workspace == stale_workspace
    assert File.dir?(workspace)
  end

  test "workspace rejects symlink escapes under the configured root" do
    %{test_root: test_root, workspace_root: workspace_root} =
      workspace_fixture!("symphony-elixir-workspace-symlink")

    outside_root = Path.join(test_root, "outside")
    symlink_path = Path.join(workspace_root, "MT-SYM")

    File.mkdir_p!(outside_root)
    File.ln_s!(outside_root, symlink_path)

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    assert Workspace.create_for_issue("MT-SYM") in [
             {:error, {:workspace_symlink_escape, symlink_path, workspace_root}},
             {:error, {:workspace_outside_root, outside_root, workspace_root}}
           ]
  end

  test "workspace remove rejects the workspace root itself with a distinct error" do
    %{workspace_root: workspace_root} =
      workspace_fixture!("symphony-elixir-workspace-root-remove")

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    assert {:error, {:workspace_equals_root, ^workspace_root, ^workspace_root}, ""} =
             Workspace.remove(workspace_root)
  end

  test "workspace surfaces after_create hook failures" do
    %{workspace_root: workspace_root} =
      workspace_fixture!("symphony-elixir-workspace-hook-failure")

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      hook_after_create: "echo nope && exit 17"
    )

    assert {:error, {:workspace_hook_failed, "after_create", 17, _output}} =
             Workspace.create_for_issue("MT-FAIL")
  end

  test "workspace surfaces after_create hook timeouts" do
    %{workspace_root: workspace_root} =
      workspace_fixture!("symphony-elixir-workspace-hook-timeout")

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      hook_timeout_ms: 10,
      hook_after_create: "sleep 1"
    )

    assert {:error, {:workspace_hook_timeout, "after_create", 10}} =
             Workspace.create_for_issue("MT-TIMEOUT")
  end

  test "workspace creates an empty directory when no bootstrap hook is configured" do
    %{workspace_root: workspace_root} = workspace_fixture!("symphony-workspace-empty")

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    workspace = Path.join(workspace_root, "MT-608")

    assert {:ok, ^workspace} = Workspace.create_for_issue("MT-608")
    assert File.dir?(workspace)
    assert {:ok, []} = File.ls(workspace)
  end

  test "workspace removes all workspaces for a closed issue identifier" do
    %{workspace_root: workspace_root} =
      workspace_fixture!("symphony-elixir-issue-workspace-cleanup")

    target_workspace = Path.join(workspace_root, "S_1")
    untouched_workspace = Path.join(workspace_root, "OTHER-#{System.unique_integer([:positive])}")

    File.mkdir_p!(target_workspace)
    File.mkdir_p!(untouched_workspace)
    File.write!(Path.join(target_workspace, "marker.txt"), "stale")
    File.write!(Path.join(untouched_workspace, "marker.txt"), "keep")

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    assert :ok = Workspace.remove_issue_workspaces("S_1")
    refute File.exists?(target_workspace)
    assert File.exists?(untouched_workspace)
  end

  test "workspace cleanup handles missing workspace root" do
    %{workspace_root: workspace_root} =
      workspace_fixture!("symphony-elixir-missing-workspaces")

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    assert :ok = Workspace.remove_issue_workspaces("S-2")
  end

  test "workspace cleanup ignores non-binary identifier" do
    assert :ok = Workspace.remove_issue_workspaces(nil)
  end

  test "workspace remove returns error information for missing directory" do
    random_path =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-missing-#{System.unique_integer([:positive])}"
      )

    assert {:ok, []} = Workspace.remove(random_path)
  end

  test "workspace hooks support multiline YAML scripts and run at lifecycle boundaries" do
    %{test_root: test_root, workspace_root: workspace_root} =
      workspace_fixture!("symphony-elixir-workspace-hooks")

    before_remove_marker = Path.join(test_root, "before_remove.log")
    after_create_counter = Path.join(test_root, "after_create.count")

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      hook_after_create: "echo after_create > after_create.log\necho call >> \"#{after_create_counter}\"",
      hook_before_remove: "echo before_remove > \"#{before_remove_marker}\""
    )

    assert Config.workspace_hooks().after_create =~ "echo after_create > after_create.log"
    assert Config.workspace_hooks().before_remove =~ "echo before_remove >"

    assert {:ok, workspace} = Workspace.create_for_issue("MT-HOOKS")
    assert File.read!(Path.join(workspace, "after_create.log")) == "after_create\n"

    assert {:ok, _workspace} = Workspace.create_for_issue("MT-HOOKS")
    assert length(String.split(String.trim(File.read!(after_create_counter)), "\n")) == 1

    assert :ok = Workspace.remove_issue_workspaces("MT-HOOKS")
    assert File.read!(before_remove_marker) == "before_remove\n"
    refute File.exists?(workspace)
  end

  test "workspace remove continues when before_remove hook fails" do
    %{workspace_root: workspace_root} =
      workspace_fixture!("symphony-elixir-workspace-hooks-fail")

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      hook_before_remove: "echo failure && exit 17"
    )

    assert {:ok, workspace} = Workspace.create_for_issue("MT-HOOKS-FAIL")
    assert :ok = Workspace.remove_issue_workspaces("MT-HOOKS-FAIL")
    refute File.exists?(workspace)
  end

  test "workspace remove continues when before_remove hook fails with large output" do
    %{workspace_root: workspace_root} =
      workspace_fixture!("symphony-elixir-workspace-hooks-large-fail")

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      hook_before_remove: "i=0; while [ $i -lt 3000 ]; do printf a; i=$((i+1)); done; exit 17"
    )

    assert {:ok, workspace} = Workspace.create_for_issue("MT-HOOKS-LARGE-FAIL")
    assert :ok = Workspace.remove_issue_workspaces("MT-HOOKS-LARGE-FAIL")
    refute File.exists?(workspace)
  end

  test "workspace remove continues when before_remove hook times out" do
    put_app_env!(:workspace_hook_timeout_ms, 10)

    %{workspace_root: workspace_root} =
      workspace_fixture!("symphony-elixir-workspace-hooks-timeout")

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      hook_before_remove: "sleep 1"
    )

    assert {:ok, workspace} = Workspace.create_for_issue("MT-HOOKS-TIMEOUT")
    assert :ok = Workspace.remove_issue_workspaces("MT-HOOKS-TIMEOUT")
    refute File.exists?(workspace)
  end
end
