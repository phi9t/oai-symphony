defmodule SymphonyElixir.RunAgentJobTest do
  use ExUnit.Case, async: true

  @repo_root Path.expand("../../..", __DIR__)
  @run_agent_job Path.join(@repo_root, "k3s/bin/run-agent-job")

  test "run-agent-job preserves prompt and workpad artifacts across repo checkout" do
    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-run-agent-job-#{System.unique_integer([:positive])}"
      )

    origin = Path.join(root, "origin")
    workspace = Path.join(root, "workspace")
    symphony_dir = Path.join(workspace, ".symphony")
    prompt_path = Path.join(symphony_dir, "prompt.md")
    workpad_path = Path.join(symphony_dir, "workpad.md")
    result_path = Path.join(symphony_dir, "run-result.json")
    issue_path = Path.join(symphony_dir, "issue.json")

    on_exit(fn -> File.rm_rf(root) end)

    File.mkdir_p!(Path.join(origin, ".symphony"))
    File.mkdir_p!(symphony_dir)

    File.write!(Path.join(origin, "README.md"), "origin\n")
    File.write!(Path.join([origin, ".symphony", "tracked.txt"]), "tracked\n")

    assert {_, 0} = System.cmd("git", ["-C", origin, "init", "-b", "main"])
    assert {_, 0} = System.cmd("git", ["-C", origin, "config", "user.name", "Test User"])
    assert {_, 0} = System.cmd("git", ["-C", origin, "config", "user.email", "test@example.com"])
    assert {_, 0} = System.cmd("git", ["-C", origin, "add", "README.md", ".symphony/tracked.txt"])
    assert {_, 0} = System.cmd("git", ["-C", origin, "commit", "-m", "initial"])

    File.write!(prompt_path, "prompt from controller\n")
    File.write!(workpad_path, "workpad from controller\n")
    File.write!(issue_path, ~s({"id":"smoke"}))

    code_command =
      ~S|python3 -c 'import json, os, pathlib, sys; pathlib.Path(".symphony").mkdir(exist_ok=True); pathlib.Path(".symphony/prompt-capture.txt").write_text(sys.argv[1], encoding="utf-8"); pathlib.Path(os.environ["RESULT_PATH"]).write_text(json.dumps({"status":"succeeded","targetState":"Human Review","summary":"ok","validation":[],"blockedReason":None,"needsContinuation":False}), encoding="utf-8")'|

    {output, 0} =
      System.cmd(@run_agent_job, [],
        cd: @repo_root,
        env: [
          {"HOME", root},
          {"PROMPT_PATH", prompt_path},
          {"WORKPAD_PATH", workpad_path},
          {"RESULT_PATH", result_path},
          {"ISSUE_PATH", issue_path},
          {"REPOSITORY_ORIGIN_URL", origin},
          {"REPOSITORY_DEFAULT_BRANCH", "main"},
          {"WORKSPACE_PATH", workspace},
          {"CODEX_COMMAND", code_command}
        ],
        stderr_to_stdout: true
      )

    assert output =~ "origin/main"

    assert String.trim_trailing(File.read!(Path.join([workspace, ".symphony", "prompt-capture.txt"]))) ==
             "prompt from controller"

    assert String.trim_trailing(File.read!(prompt_path)) == "prompt from controller"
    assert String.trim_trailing(File.read!(workpad_path)) == "workpad from controller"
    assert File.read!(issue_path) == ~s({"id":"smoke"})
    assert File.read!(result_path) =~ ~r/"status":\s*"succeeded"/
  end
end
