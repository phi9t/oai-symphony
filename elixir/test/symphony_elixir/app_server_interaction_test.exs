defmodule SymphonyElixir.AppServerInteractionTest do
  use SymphonyElixir.TestSupport

  import SymphonyElixir.TestSupport.Scenarios,
    only: [codex_transport_fixture!: 3, issue_fixture: 1]

  test "app server marks request-for-input events as a hard failure" do
    %{workspace_root: workspace_root, workspace: workspace, codex_binary: codex_binary} =
      codex_transport_fixture!(
        "symphony-elixir-app-server-input",
        """
        #!/bin/sh
        count=0
        while IFS= read -r _line; do
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
              printf '%s\\n' '{"method":"turn/input_required","id":"resp-1","params":{"requiresInput":true,"reason":"blocked"}}'
              ;;
            *)
              exit 0
              ;;
          esac
        done
        """,
        workspace_name: "MT-88"
      )

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      codex_command: "#{codex_binary} app-server"
    )

    issue =
      issue_fixture(
        id: "issue-input",
        identifier: "MT-88",
        title: "Input needed",
        description: "Cannot satisfy codex input",
        state: "In Progress",
        labels: ["backend"]
      )

    assert {:error, {:turn_input_required, payload}} =
             AppServer.run(workspace, "Needs input", issue)

    assert payload["method"] == "turn/input_required"
  end

  test "app server fails when command execution approval is required under safer defaults" do
    %{workspace_root: workspace_root, workspace: workspace, codex_binary: codex_binary} =
      codex_transport_fixture!(
        "symphony-elixir-app-server-approval-required",
        """
        #!/bin/sh
        count=0
        while IFS= read -r _line; do
          count=$((count + 1))

          case "$count" in
            1)
              printf '%s\\n' '{"id":1,"result":{}}'
              ;;
            2)
              printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-89"}}}'
              ;;
            3)
              printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-89"}}}'
              printf '%s\\n' '{"id":99,"method":"item/commandExecution/requestApproval","params":{"command":"gh pr view","cwd":"/tmp","reason":"need approval"}}'
              ;;
            *)
              sleep 1
              ;;
          esac
        done
        """,
        workspace_name: "MT-89"
      )

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      codex_command: "#{codex_binary} app-server"
    )

    issue =
      issue_fixture(
        id: "issue-approval-required",
        identifier: "MT-89",
        title: "Approval required",
        description: "Ensure safer defaults do not auto approve requests",
        state: "In Progress",
        labels: ["backend"]
      )

    assert {:error, {:approval_required, payload}} =
             AppServer.run(workspace, "Handle approval request", issue)

    assert payload["method"] == "item/commandExecution/requestApproval"
  end

  test "app server auto-approves command execution approval requests when approval policy is never" do
    %{workspace_root: workspace_root, workspace: workspace, codex_binary: codex_binary, trace_file: trace_file} =
      codex_transport_fixture!(
        "symphony-elixir-app-server-auto-approve",
        """
        #!/bin/sh
        trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex-auto-approve.trace}"
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
              printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-89"}}}'
              ;;
            4)
              printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-89"}}}'
              printf '%s\\n' '{"id":99,"method":"item/commandExecution/requestApproval","params":{"command":"gh pr view","cwd":"/tmp","reason":"need approval"}}'
              ;;
            5)
              printf '%s\\n' '{"method":"turn/completed"}'
              exit 0
              ;;
            *)
              exit 0
              ;;
          esac
        done
        """,
        workspace_name: "MT-89",
        trace_env: "SYMP_TEST_CODEx_TRACE",
        trace_name: "codex-auto-approve.trace"
      )

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      codex_command: "#{codex_binary} app-server",
      codex_approval_policy: "never"
    )

    issue =
      issue_fixture(
        id: "issue-auto-approve",
        identifier: "MT-89",
        title: "Auto approve request",
        description: "Ensure app-server approval requests are handled automatically",
        state: "In Progress",
        labels: ["backend"]
      )

    assert {:ok, _result} = AppServer.run(workspace, "Handle approval request", issue)

    lines = File.read!(trace_file) |> String.split("\n", trim: true)

    assert Enum.any?(lines, fn line ->
             if String.starts_with?(line, "JSON:") do
               payload = line |> String.trim_leading("JSON:") |> Jason.decode!()

               payload["id"] == 1 and
                 get_in(payload, ["params", "capabilities", "experimentalApi"]) == true
             else
               false
             end
           end)

    assert Enum.any?(lines, fn line ->
             if String.starts_with?(line, "JSON:") do
               payload = line |> String.trim_leading("JSON:") |> Jason.decode!()

               payload["id"] == 2 and
                 case get_in(payload, ["params", "dynamicTools"]) do
                   [
                     %{
                       "description" => description,
                       "inputSchema" => %{"required" => ["query"]},
                       "name" => "linear_graphql"
                     }
                   ] ->
                     description =~ "Linear"

                   _ ->
                     false
                 end
             else
               false
             end
           end)

    assert Enum.any?(lines, fn line ->
             if String.starts_with?(line, "JSON:") do
               payload = line |> String.trim_leading("JSON:") |> Jason.decode!()
               payload["id"] == 99 and get_in(payload, ["result", "decision"]) == "acceptForSession"
             else
               false
             end
           end)
  end

  test "app server auto-approves MCP tool approval prompts when approval policy is never" do
    %{workspace_root: workspace_root, workspace: workspace, codex_binary: codex_binary, trace_file: trace_file} =
      codex_transport_fixture!(
        "symphony-elixir-app-server-tool-user-input-auto-approve",
        """
        #!/bin/sh
        trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex-tool-user-input-auto-approve.trace}"
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
              printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-717"}}}'
              ;;
            4)
              printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-717"}}}'
              printf '%s\\n' '{"id":110,"method":"item/tool/requestUserInput","params":{"itemId":"call-717","questions":[{"header":"Approve app tool call?","id":"mcp_tool_call_approval_call-717","isOther":false,"isSecret":false,"options":[{"description":"Run the tool and continue.","label":"Approve Once"},{"description":"Run the tool and remember this choice for this session.","label":"Approve this Session"},{"description":"Decline this tool call and continue.","label":"Deny"},{"description":"Cancel this tool call","label":"Cancel"}],"question":"The linear MCP server wants to run the tool \\\"Save issue\\\", which may modify or delete data. Allow this action?"}],"threadId":"thread-717","turnId":"turn-717"}}'
              ;;
            5)
              printf '%s\\n' '{"method":"turn/completed"}'
              exit 0
              ;;
            *)
              exit 0
              ;;
          esac
        done
        """,
        workspace_name: "MT-717",
        trace_env: "SYMP_TEST_CODEx_TRACE",
        trace_name: "codex-tool-user-input-auto-approve.trace"
      )

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      codex_command: "#{codex_binary} app-server",
      codex_approval_policy: "never"
    )

    issue =
      issue_fixture(
        id: "issue-tool-user-input-auto-approve",
        identifier: "MT-717",
        title: "Auto approve MCP tool request user input",
        description: "Ensure app tool approval prompts continue automatically",
        state: "In Progress",
        labels: ["backend"]
      )

    assert {:ok, _result} = AppServer.run(workspace, "Handle tool approval prompt", issue)

    lines = File.read!(trace_file) |> String.split("\n", trim: true)

    assert Enum.any?(lines, fn line ->
             if String.starts_with?(line, "JSON:") do
               payload = line |> String.trim_leading("JSON:") |> Jason.decode!()

               payload["id"] == 110 and
                 get_in(payload, ["result", "answers", "mcp_tool_call_approval_call-717", "answers"]) ==
                   ["Approve this Session"]
             else
               false
             end
           end)
  end

  test "app server sends a generic non-interactive answer for freeform tool input prompts" do
    %{workspace_root: workspace_root, workspace: workspace, codex_binary: codex_binary} =
      codex_transport_fixture!(
        "symphony-elixir-app-server-tool-user-input-required",
        """
        #!/bin/sh
        count=0
        while IFS= read -r _line; do
          count=$((count + 1))

          case "$count" in
            1)
              printf '%s\\n' '{"id":1,"result":{}}'
              ;;
            2)
              ;;
            3)
              printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-718"}}}'
              ;;
            4)
              printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-718"}}}'
              printf '%s\\n' '{"id":111,"method":"item/tool/requestUserInput","params":{"itemId":"call-718","questions":[{"header":"Provide context","id":"freeform-718","isOther":false,"isSecret":false,"options":null,"question":"What comment should I post back to the issue?"}],"threadId":"thread-718","turnId":"turn-718"}}'
              ;;
            5)
              printf '%s\\n' '{"method":"turn/completed"}'
              exit 0
              ;;
            *)
              exit 0
              ;;
          esac
        done
        """,
        workspace_name: "MT-718"
      )

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      codex_command: "#{codex_binary} app-server",
      codex_approval_policy: "never"
    )

    issue =
      issue_fixture(
        id: "issue-tool-user-input-required",
        identifier: "MT-718",
        title: "Non interactive tool input answer",
        description: "Ensure arbitrary tool prompts receive a generic answer",
        state: "In Progress",
        labels: ["backend"]
      )

    on_message = fn message -> send(self(), {:app_server_message, message}) end

    assert {:ok, _result} =
             AppServer.run(workspace, "Handle generic tool input", issue, on_message: on_message)

    assert_received {:app_server_message,
                     %{
                       event: :tool_input_auto_answered,
                       answer: "This is a non-interactive session. Operator input is unavailable."
                     }}
  end

  test "app server sends a generic non-interactive answer for option-based tool input prompts" do
    %{workspace_root: workspace_root, workspace: workspace, codex_binary: codex_binary, trace_file: trace_file} =
      codex_transport_fixture!(
        "symphony-elixir-app-server-tool-user-input-options",
        """
        #!/bin/sh
        trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex-tool-user-input-options.trace}"
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
              printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-719"}}}'
              ;;
            4)
              printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-719"}}}'
              printf '%s\\n' '{"id":112,"method":"item/tool/requestUserInput","params":{"itemId":"call-719","questions":[{"header":"Choose an action","id":"options-719","isOther":false,"isSecret":false,"options":[{"description":"Use the default behavior.","label":"Use default"},{"description":"Skip this step.","label":"Skip"}],"question":"How should I proceed?"}],"threadId":"thread-719","turnId":"turn-719"}}'
              ;;
            5)
              printf '%s\\n' '{"method":"turn/completed"}'
              exit 0
              ;;
            *)
              exit 0
              ;;
          esac
        done
        """,
        workspace_name: "MT-719",
        trace_env: "SYMP_TEST_CODEx_TRACE",
        trace_name: "codex-tool-user-input-options.trace"
      )

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      codex_command: "#{codex_binary} app-server"
    )

    issue =
      issue_fixture(
        id: "issue-tool-user-input-options",
        identifier: "MT-719",
        title: "Option based tool input answer",
        description: "Ensure option prompts receive a generic non-interactive answer",
        state: "In Progress",
        labels: ["backend"]
      )

    assert {:ok, _result} =
             AppServer.run(workspace, "Handle option based tool input", issue)

    lines = File.read!(trace_file) |> String.split("\n", trim: true)

    assert Enum.any?(lines, fn line ->
             if String.starts_with?(line, "JSON:") do
               payload = line |> String.trim_leading("JSON:") |> Jason.decode!()

               payload["id"] == 112 and
                 get_in(payload, ["result", "answers", "options-719", "answers"]) == [
                   "This is a non-interactive session. Operator input is unavailable."
                 ]
             else
               false
             end
           end)
  end

  test "app server rejects unsupported dynamic tool calls without stalling" do
    %{workspace_root: workspace_root, workspace: workspace, codex_binary: codex_binary, trace_file: trace_file} =
      codex_transport_fixture!(
        "symphony-elixir-app-server-tool-call",
        """
        #!/bin/sh
        trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex-tool-call.trace}"
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
              printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-90"}}}'
              ;;
            4)
              printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-90"}}}'
              printf '%s\\n' '{"id":101,"method":"item/tool/call","params":{"tool":"some_tool","callId":"call-90","threadId":"thread-90","turnId":"turn-90","arguments":{}}}'
              ;;
            5)
              printf '%s\\n' '{"method":"turn/completed"}'
              exit 0
              ;;
            *)
              exit 0
              ;;
          esac
        done
        """,
        workspace_name: "MT-90",
        trace_env: "SYMP_TEST_CODEx_TRACE",
        trace_name: "codex-tool-call.trace"
      )

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      codex_command: "#{codex_binary} app-server"
    )

    issue =
      issue_fixture(
        id: "issue-tool-call",
        identifier: "MT-90",
        title: "Unsupported tool call",
        description: "Ensure unsupported tool calls do not stall a turn",
        state: "In Progress",
        labels: ["backend"]
      )

    assert {:ok, _result} = AppServer.run(workspace, "Reject unsupported tool calls", issue)

    lines = File.read!(trace_file) |> String.split("\n", trim: true)

    assert Enum.any?(lines, fn line ->
             if String.starts_with?(line, "JSON:") do
               payload = line |> String.trim_leading("JSON:") |> Jason.decode!()

               payload["id"] == 101 and
                 get_in(payload, ["result", "success"]) == false and
                 get_in(payload, ["result", "contentItems", Access.at(0), "type"]) == "inputText" and
                 String.contains?(
                   get_in(payload, ["result", "contentItems", Access.at(0), "text"]),
                   "Unsupported dynamic tool"
                 )
             else
               false
             end
           end)
  end

  test "app server executes supported dynamic tool calls and returns the tool result" do
    %{workspace_root: workspace_root, workspace: workspace, codex_binary: codex_binary, trace_file: trace_file} =
      codex_transport_fixture!(
        "symphony-elixir-app-server-supported-tool-call",
        """
        #!/bin/sh
        trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex-supported-tool-call.trace}"
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
              printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-90a"}}}'
              ;;
            4)
              printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-90a"}}}'
              printf '%s\\n' '{"id":102,"method":"item/tool/call","params":{"name":"linear_graphql","callId":"call-90a","threadId":"thread-90a","turnId":"turn-90a","arguments":{"query":"query Viewer { viewer { id } }","variables":{"includeTeams":false}}}}'
              ;;
            5)
              printf '%s\\n' '{"method":"turn/completed"}'
              exit 0
              ;;
            *)
              exit 0
              ;;
          esac
        done
        """,
        workspace_name: "MT-90A",
        trace_env: "SYMP_TEST_CODEx_TRACE",
        trace_name: "codex-supported-tool-call.trace"
      )

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      codex_command: "#{codex_binary} app-server"
    )

    issue =
      issue_fixture(
        id: "issue-supported-tool-call",
        identifier: "MT-90A",
        title: "Supported tool call",
        description: "Ensure supported tool calls return tool output",
        state: "In Progress",
        labels: ["backend"]
      )

    test_pid = self()

    tool_executor = fn tool, arguments ->
      send(test_pid, {:tool_called, tool, arguments})

      %{
        "success" => true,
        "contentItems" => [
          %{
            "type" => "inputText",
            "text" => ~s({"data":{"viewer":{"id":"usr_123"}}})
          }
        ]
      }
    end

    assert {:ok, _result} =
             AppServer.run(workspace, "Handle supported tool calls", issue, tool_executor: tool_executor)

    assert_received {:tool_called, "linear_graphql",
                     %{
                       "query" => "query Viewer { viewer { id } }",
                       "variables" => %{"includeTeams" => false}
                     }}

    lines = File.read!(trace_file) |> String.split("\n", trim: true)

    assert Enum.any?(lines, fn line ->
             if String.starts_with?(line, "JSON:") do
               payload = line |> String.trim_leading("JSON:") |> Jason.decode!()

               payload["id"] == 102 and
                 get_in(payload, ["result", "success"]) == true and
                 get_in(payload, ["result", "contentItems", Access.at(0), "text"]) ==
                   ~s({"data":{"viewer":{"id":"usr_123"}}})
             else
               false
             end
           end)
  end

  test "app server emits tool_call_failed for supported tool failures" do
    %{workspace_root: workspace_root, workspace: workspace, codex_binary: codex_binary, trace_file: _trace_file} =
      codex_transport_fixture!(
        "symphony-elixir-app-server-tool-call-failed",
        """
        #!/bin/sh
        trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex-tool-call-failed.trace}"
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
              printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-90b"}}}'
              ;;
            4)
              printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-90b"}}}'
              printf '%s\\n' '{"id":103,"method":"item/tool/call","params":{"tool":"linear_graphql","callId":"call-90b","threadId":"thread-90b","turnId":"turn-90b","arguments":{"query":"query Viewer { viewer { id } }"}}}'
              ;;
            5)
              printf '%s\\n' '{"method":"turn/completed"}'
              exit 0
              ;;
            *)
              exit 0
              ;;
          esac
        done
        """,
        workspace_name: "MT-90B",
        trace_env: "SYMP_TEST_CODEx_TRACE",
        trace_name: "codex-tool-call-failed.trace"
      )

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      codex_command: "#{codex_binary} app-server"
    )

    issue =
      issue_fixture(
        id: "issue-tool-call-failed",
        identifier: "MT-90B",
        title: "Tool call failed",
        description: "Ensure supported tool failures emit a distinct event",
        state: "In Progress",
        labels: ["backend"]
      )

    test_pid = self()

    tool_executor = fn tool, arguments ->
      send(test_pid, {:tool_called, tool, arguments})

      %{
        "success" => false,
        "contentItems" => [
          %{
            "type" => "inputText",
            "text" => ~s({"error":{"message":"boom"}})
          }
        ]
      }
    end

    on_message = fn message -> send(test_pid, {:app_server_message, message}) end

    assert {:ok, _result} =
             AppServer.run(workspace, "Handle failed tool calls", issue,
               on_message: on_message,
               tool_executor: tool_executor
             )

    assert_received {:tool_called, "linear_graphql", %{"query" => "query Viewer { viewer { id } }"}}

    assert_received {:app_server_message, %{event: :tool_call_failed, payload: %{"params" => %{"tool" => "linear_graphql"}}}}
  end

  test "app server buffers partial JSON lines until newline terminator" do
    %{workspace_root: workspace_root, workspace: workspace, codex_binary: codex_binary} =
      codex_transport_fixture!(
        "symphony-elixir-app-server-partial-line",
        """
        #!/bin/sh
        count=0
        while IFS= read -r line; do
          count=$((count + 1))

          case "$count" in
            1)
              padding=$(printf '%*s' 1100000 '' | tr ' ' a)
              printf '{"id":1,"result":{},"padding":"%s"}\\n' "$padding"
              ;;
            2)
              printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-91"}}}'
              ;;
            3)
              printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-91"}}}'
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
        workspace_name: "MT-91"
      )

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      codex_command: "#{codex_binary} app-server"
    )

    issue =
      issue_fixture(
        id: "issue-partial-line",
        identifier: "MT-91",
        title: "Partial line decode",
        description: "Ensure JSON parsing waits for newline-delimited messages",
        state: "In Progress",
        labels: ["backend"]
      )

    assert {:ok, _result} = AppServer.run(workspace, "Validate newline-delimited buffering", issue)
  end

  test "app server captures codex side output and logs it through Logger" do
    %{workspace_root: workspace_root, workspace: workspace, codex_binary: codex_binary} =
      codex_transport_fixture!(
        "symphony-elixir-app-server-stderr",
        """
        #!/bin/sh
        count=0
        while IFS= read -r line; do
          count=$((count + 1))

          case "$count" in
            1)
              printf '%s\\n' '{"id":1,"result":{}}'
              ;;
            2)
              printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-92"}}}'
              ;;
            3)
              printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-92"}}}'
              ;;
            4)
              printf '%s\\n' 'warning: this is stderr noise' >&2
              printf '%s\\n' '{"method":"turn/completed"}'
              exit 0
              ;;
            *)
              exit 0
              ;;
          esac
        done
        """,
        workspace_name: "MT-92"
      )

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      codex_command: "#{codex_binary} app-server"
    )

    issue =
      issue_fixture(
        id: "issue-stderr",
        identifier: "MT-92",
        title: "Capture stderr",
        description: "Ensure codex stderr is captured and logged",
        state: "In Progress",
        labels: ["backend"]
      )

    log =
      capture_log(fn ->
        assert {:ok, _result} = AppServer.run(workspace, "Capture stderr log", issue)
      end)

    assert log =~ "Codex turn stream output: warning: this is stderr noise"
  end
end
