defmodule SymphonyElixir.AppServerCommandTest do
  use SymphonyElixir.TestSupport

  import SymphonyElixir.TestSupport.Scenarios,
    only: [codex_transport_fixture!: 3, issue_fixture: 1]

  test "app server starts with workspace cwd and expected startup command" do
    %{workspace_root: workspace_root, workspace: workspace, codex_binary: codex_binary, trace_file: trace_file} =
      codex_transport_fixture!(
        "symphony-elixir-app-server-args",
        """
        #!/bin/sh
        trace_file="${SYMP_TEST_CODex_TRACE:-/tmp/codex-args.trace}"
        count=0
        printf 'ARGV:%s\\n' "$*" >> "$trace_file"
        printf 'CWD:%s\\n' "$PWD" >> "$trace_file"

        while IFS= read -r line; do
          count=$((count + 1))
          printf 'JSON:%s\\n' "$line" >> "$trace_file"
          case "$count" in
            1)
              printf '%s\\n' '{"id":1,"result":{}}'
              ;;
            2)
              printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-77"}}}'
              ;;
            3)
              printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-77"}}}'
              ;;
            4)
              printf '%s\\n' '{"method":"turn/completed"}'
              exit 0
              ;;
            *)
              exit 0
              ;;
          esac
        done
        """,
        workspace_name: "MT-77",
        trace_env: "SYMP_TEST_CODex_TRACE",
        trace_name: "codex-args.trace"
      )

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      codex_command: "#{codex_binary} app-server"
    )

    issue =
      issue_fixture(
        id: "issue-args",
        identifier: "MT-77",
        title: "Validate codex args",
        description: "Check startup args and cwd",
        state: "In Progress",
        labels: ["backend"]
      )

    assert {:ok, _result} = AppServer.run(workspace, "Fix workspace start args", issue)
    assert {:ok, canonical_workspace} = SymphonyElixir.PathSafety.canonicalize(workspace)

    lines = File.read!(trace_file) |> String.split("\n", trim: true)

    assert argv_line = Enum.find(lines, &String.starts_with?(&1, "ARGV:"))
    assert String.contains?(argv_line, "app-server")
    refute Enum.any?(lines, &String.contains?(&1, "--yolo"))
    assert cwd_line = Enum.find(lines, &String.starts_with?(&1, "CWD:"))
    assert String.ends_with?(cwd_line, Path.basename(workspace))

    assert Enum.any?(lines, fn line ->
             if String.starts_with?(line, "JSON:") do
               line
               |> String.trim_leading("JSON:")
               |> Jason.decode!()
               |> then(fn payload ->
                 expected_approval_policy = %{
                   "reject" => %{
                     "sandbox_approval" => true,
                     "rules" => true,
                     "mcp_elicitations" => true
                   }
                 }

                 payload["method"] == "thread/start" &&
                   get_in(payload, ["params", "approvalPolicy"]) == expected_approval_policy &&
                   get_in(payload, ["params", "sandbox"]) == "workspace-write" &&
                   get_in(payload, ["params", "cwd"]) == canonical_workspace
               end)
             else
               false
             end
           end)

    expected_turn_sandbox_policy = %{
      "type" => "workspaceWrite",
      "writableRoots" => [canonical_workspace],
      "readOnlyAccess" => %{"type" => "fullAccess"},
      "networkAccess" => false,
      "excludeTmpdirEnvVar" => false,
      "excludeSlashTmp" => false
    }

    assert Enum.any?(lines, fn line ->
             if String.starts_with?(line, "JSON:") do
               line
               |> String.trim_leading("JSON:")
               |> Jason.decode!()
               |> then(fn payload ->
                 expected_approval_policy = %{
                   "reject" => %{
                     "sandbox_approval" => true,
                     "rules" => true,
                     "mcp_elicitations" => true
                   }
                 }

                 payload["method"] == "turn/start" &&
                   get_in(payload, ["params", "cwd"]) == canonical_workspace &&
                   get_in(payload, ["params", "approvalPolicy"]) == expected_approval_policy &&
                   get_in(payload, ["params", "sandboxPolicy"]) == expected_turn_sandbox_policy
               end)
             else
               false
             end
           end)
  end

  test "app server startup command supports codex args override from workflow config" do
    %{workspace_root: workspace_root, workspace: workspace, codex_binary: codex_binary, trace_file: trace_file} =
      codex_transport_fixture!(
        "symphony-elixir-app-server-custom-args",
        """
        #!/bin/sh
        trace_file="${SYMP_TEST_CODex_TRACE:-/tmp/codex-custom-args.trace}"
        count=0
        printf 'ARGV:%s\\n' "$*" >> "$trace_file"

        while IFS= read -r line; do
          count=$((count + 1))
          case "$count" in
            1)
              printf '%s\\n' '{"id":1,"result":{}}'
              ;;
            2)
              printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-88"}}}'
              ;;
            3)
              printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-88"}}}'
              ;;
            4)
              printf '%s\\n' '{"method":"turn/completed"}'
              exit 0
              ;;
            *)
              exit 0
              ;;
          esac
        done
        """,
        workspace_name: "MT-88",
        trace_env: "SYMP_TEST_CODex_TRACE",
        trace_name: "codex-custom-args.trace"
      )

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      codex_command: "#{codex_binary} --model gpt-5.3-codex app-server"
    )

    issue =
      issue_fixture(
        id: "issue-custom-args",
        identifier: "MT-88",
        title: "Validate custom codex args",
        description: "Check startup args override",
        state: "In Progress",
        labels: ["backend"]
      )

    assert {:ok, _result} = AppServer.run(workspace, "Fix workspace start args", issue)

    lines = File.read!(trace_file) |> String.split("\n", trim: true)

    assert argv_line = Enum.find(lines, &String.starts_with?(&1, "ARGV:"))
    assert String.contains?(argv_line, "--model gpt-5.3-codex app-server")
    refute String.contains?(argv_line, "--ask-for-approval never")
    refute String.contains?(argv_line, "--sandbox danger-full-access")
  end

  test "app server startup payload uses configurable approval and sandbox settings from workflow config" do
    %{workspace_root: workspace_root, workspace: workspace, codex_binary: codex_binary, trace_file: trace_file} =
      codex_transport_fixture!(
        "symphony-elixir-app-server-policy-overrides",
        """
        #!/bin/sh
        trace_file="${SYMP_TEST_CODex_TRACE:-/tmp/codex-policy-overrides.trace}"
        count=0

        while IFS= read -r line; do
          count=$((count + 1))
          printf 'JSON:%s\\n' "$line" >> "$trace_file"

          case "$count" in
            1)
              printf '%s\\n' '{"id":1,"result":{}}'
              ;;
            2)
              printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-99"}}}'
              ;;
            3)
              printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-99"}}}'
              ;;
            4)
              printf '%s\\n' '{"method":"turn/completed"}'
              exit 0
              ;;
            *)
              exit 0
              ;;
          esac
        done
        """,
        workspace_name: "MT-99",
        trace_env: "SYMP_TEST_CODex_TRACE",
        trace_name: "codex-policy-overrides.trace"
      )

    workspace_cache = Path.join(Path.expand(workspace), ".cache")
    File.mkdir_p!(workspace_cache)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      codex_command: "#{codex_binary} app-server",
      codex_approval_policy: "on-request",
      codex_thread_sandbox: "workspace-write",
      codex_turn_sandbox_policy: %{
        type: "workspaceWrite",
        writableRoots: [Path.expand(workspace), workspace_cache]
      }
    )

    issue =
      issue_fixture(
        id: "issue-policy-overrides",
        identifier: "MT-99",
        title: "Validate codex policy overrides",
        description: "Check startup policy payload overrides",
        state: "In Progress",
        labels: ["backend"]
      )

    assert {:ok, _result} = AppServer.run(workspace, "Fix workspace start args", issue)

    lines = File.read!(trace_file) |> String.split("\n", trim: true)

    assert Enum.any?(lines, fn line ->
             if String.starts_with?(line, "JSON:") do
               line
               |> String.trim_leading("JSON:")
               |> Jason.decode!()
               |> then(fn payload ->
                 payload["method"] == "thread/start" &&
                   get_in(payload, ["params", "approvalPolicy"]) == "on-request" &&
                   get_in(payload, ["params", "sandbox"]) == "workspace-write"
               end)
             else
               false
             end
           end)

    expected_turn_policy = %{
      "type" => "workspaceWrite",
      "writableRoots" => [Path.expand(workspace), workspace_cache]
    }

    assert Enum.any?(lines, fn line ->
             if String.starts_with?(line, "JSON:") do
               line
               |> String.trim_leading("JSON:")
               |> Jason.decode!()
               |> then(fn payload ->
                 payload["method"] == "turn/start" &&
                   get_in(payload, ["params", "approvalPolicy"]) == "on-request" &&
                   get_in(payload, ["params", "sandboxPolicy"]) == expected_turn_policy
               end)
             else
               false
             end
           end)
  end
end
