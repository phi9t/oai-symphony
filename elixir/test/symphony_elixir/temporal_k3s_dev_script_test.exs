defmodule SymphonyElixir.TemporalK3sDevScriptTest do
  use ExUnit.Case, async: true

  @repo_root Path.expand("../../..", __DIR__)
  @dev_script Path.join(@repo_root, "dev/temporal-k3s")
  @docker_kubectl Path.join(@repo_root, "k3s/bin/docker-kubectl")

  test "docker-kubectl execs kubectl directly inside the K3s container" do
    %{bin_dir: bin_dir, capture_path: capture_path} =
      temp_harness("""
      printf '%s\\n' "$*" > "$SYMPHONY_CAPTURE_PATH"
      """)

    {_, 0} =
      System.cmd(@docker_kubectl, ["get", "nodes"],
        cd: @repo_root,
        env: [
          {"PATH", "#{bin_dir}:#{System.get_env("PATH")}"},
          {"SYMPHONY_CAPTURE_PATH", capture_path},
          {"SYMPHONY_K3S_CONTAINER_NAME", "symphony-k3s-dev"}
        ],
        stderr_to_stdout: true
      )

    assert File.read!(capture_path) == "exec -i symphony-k3s-dev kubectl get nodes\n"
  end

  test "temporal-k3s env exports the running repo-managed Temporal port" do
    %{bin_dir: bin_dir} =
      temp_harness("""
      case "$1" in
        inspect)
          if [ "$2" = "-f" ] && [ "$3" = "{{.State.Running}}" ] && [ "$4" = "symphony-temporal-dev" ]; then
            echo true
            exit 0
          fi
          ;;
        port)
          if [ "$2" = "symphony-temporal-dev" ] && [ "$3" = "7233/tcp" ]; then
            echo "127.0.0.1:29733"
            exit 0
          fi
          ;;
      esac

      echo "unexpected docker args: $*" >&2
      exit 1
      """)

    {output, 0} =
      System.cmd(@dev_script, ["env"],
        cd: @repo_root,
        env: [
          {"PATH", "#{bin_dir}:#{System.get_env("PATH")}"},
          {"TEMPORAL_ADDRESS", "127.0.0.1:7233"}
        ],
        stderr_to_stdout: true
      )

    assert output =~ "export TEMPORAL_ADDRESS=127.0.0.1:29733"
    assert output =~ "export TEMPORAL_NAMESPACE=default"
  end

  test "temporal-k3s status reports the repo-managed stack details explicitly" do
    %{bin_dir: bin_dir} =
      temp_harness("""
      case "$1" in
        inspect)
          if [ "$2" = "-f" ] && [ "$3" = "{{.State.Running}}" ]; then
            case "$4" in
              symphony-temporal-dev|symphony-k3s-dev)
                echo true
                exit 0
                ;;
            esac
          fi
          ;;
        port)
          if [ "$2" = "symphony-temporal-dev" ] && [ "$3" = "7233/tcp" ]; then
            echo "127.0.0.1:29733"
            exit 0
          fi
          ;;
        exec)
          if [ "$2" = "-i" ] && [ "$3" = "symphony-k3s-dev" ] && [ "$4" = "kubectl" ]; then
            if [ "$#" -ge 8 ] && [ "$5" = "get" ] && [ "$6" = "nodes" ] && [ "$7" = "-o" ] && [ "$8" = "name" ]; then
              echo "node/dev-control-plane"
              exit 0
            fi

            if [ "$5" = "get" ] && [ "$6" = "nodes" ]; then
              echo "NAME STATUS ROLES AGE VERSION"
              echo "dev-control-plane Ready control-plane 1h v1.34.1+k3s1"
              exit 0
            fi

            if [ "$5" = "get" ] && [ "$6" = "namespace" ] && [ "$7" = "symphony" ]; then
              echo "apiVersion: v1"
              echo "kind: Namespace"
              echo "metadata:"
              echo "  name: symphony"
              exit 0
            fi
          fi
          ;;
      esac

      echo "unexpected docker args: $*" >&2
      exit 1
      """)

    {output, 1} =
      System.cmd(@dev_script, ["status"],
        cd: @repo_root,
        env: [
          {"PATH", "#{bin_dir}:#{System.get_env("PATH")}"},
          {"TEMPORAL_ADDRESS", "127.0.0.1:7233"}
        ],
        stderr_to_stdout: true
      )

    assert output =~ "temporal: blocked (container symphony-temporal-dev is running but 127.0.0.1:29733 is unreachable)"
    assert output =~ "k3s: ready (nodes=1)"
    assert output =~ "worker: "
    assert output =~ "namespace: ready (symphony)"
  end

  test "temporal-k3s smoke parser normalizes workflow mode and expected phase" do
    for {workflow_mode, expected_phase} <- [{"phased", "execute"}, {"vanilla", "run"}] do
      {output, 0} =
        System.cmd("bash", ["-lc", "source ./dev/temporal-k3s; parse_smoke_args --workflow-mode \"$WORKFLOW_MODE\"; printf '%s %s' \"$SMOKE_WORKFLOW_MODE\" \"$SMOKE_EXPECTED_PHASE\""],
          cd: @repo_root,
          env: [{"WORKFLOW_MODE", workflow_mode}],
          stderr_to_stdout: true
        )

      assert output == "#{workflow_mode} #{expected_phase}"
    end
  end

  test "temporal-k3s stages a self-contained smoke source repo under the shared cache" do
    %{bin_dir: bin_dir, capture_path: capture_path} =
      temp_harness(
        """
        printf '%s\\n' "$*" >> "$SYMPHONY_CAPTURE_PATH"

        if [ "$1" = "clone" ] && [ "$2" = "--mirror" ] && [ "$3" = "--no-hardlinks" ]; then
          mkdir -p "$5"
          exit 0
        fi

        echo "unexpected git args: $*" >&2
        exit 1
        """,
        "git"
      )

    shared_cache_root = Path.join(System.tmp_dir!(), "symphony-smoke-cache-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf(shared_cache_root) end)

    {output, 0} =
      System.cmd(
        "bash",
        [
          "-lc",
          "source ./dev/temporal-k3s; SMOKE_ID=smoke-fixture; prepare_smoke_source_repo; printf '%s\\n%s' \"$SMOKE_SOURCE_REPO_HOST_PATH\" \"$SMOKE_SOURCE_REPO_CONTAINER_PATH\""
        ],
        cd: @repo_root,
        env: [
          {"PATH", "#{bin_dir}:#{System.get_env("PATH")}"},
          {"SYMPHONY_CAPTURE_PATH", capture_path},
          {"SYMPHONY_K3S_SHARED_CACHE_ROOT", shared_cache_root}
        ],
        stderr_to_stdout: true
      )

    assert output == "#{shared_cache_root}/smoke-fixture-source.git\n/cache/smoke-fixture-source.git"
    assert File.read!(capture_path) == "clone --mirror --no-hardlinks #{@repo_root} #{shared_cache_root}/smoke-fixture-source.git\n"
  end

  test "temporal-k3s recreates K3s when the running container belongs to another checkout" do
    %{bin_dir: bin_dir, capture_path: capture_path, state_path: state_path} =
      temp_harness("""
      state_path="$SYMPHONY_DOCKER_STATE_PATH"
      state="$(cat "$state_path" 2>/dev/null || echo running)"
      printf '%s\\n' "$*" >> "$SYMPHONY_CAPTURE_PATH"

      case "$1" in
        inspect)
          if [ "$2" = "-f" ] && [ "$4" = "symphony-k3s-dev" ]; then
            case "$3" in
              "{{.State.Running}}")
                if [ "$state" = "running" ]; then
                  echo true
                  exit 0
                fi
                exit 1
                ;;
              "{{range .Mounts}}{{printf \\"%s|%s\\\\n\\" .Source .Destination}}{{end}}")
                echo "/tmp/other-checkout|/tmp/other-checkout"
                echo "/tmp/other-checkout/.symphony/dev/projects|/tmp/other-checkout/.symphony/dev/projects"
                echo "/tmp/other-checkout/.symphony/dev/shared-cache|/tmp/other-checkout/.symphony/dev/shared-cache"
                exit 0
                ;;
            esac
          fi

          if [ "$2" = "symphony-k3s-dev" ] && [ "$state" = "running" ]; then
            echo "{}"
            exit 0
          fi
          ;;
        rm)
          if [ "$2" = "-f" ] && [ "$3" = "symphony-k3s-dev" ]; then
            echo absent > "$state_path"
            exit 0
          fi
          ;;
        run)
          echo running > "$state_path"
          echo "new-k3s-container"
          exit 0
          ;;
      esac

      echo "unexpected docker args: $*" >&2
      exit 1
      """)

    {output, 0} =
      System.cmd(
        "bash",
        [
          "-lc",
          "source ./dev/temporal-k3s; wait_for_k3s() { return 0; }; with_dev_kubectl() { printf 'kubectl %s\\n' \"$*\" >> \"$SYMPHONY_CAPTURE_PATH\"; }; start_k3s_container"
        ],
        cd: @repo_root,
        env: [
          {"PATH", "#{bin_dir}:#{System.get_env("PATH")}"},
          {"SYMPHONY_CAPTURE_PATH", capture_path},
          {"SYMPHONY_DOCKER_STATE_PATH", state_path}
        ],
        stderr_to_stdout: true
      )

    capture = File.read!(capture_path)

    assert output =~ "Recreating K3s container symphony-k3s-dev because mounted workspace paths do not match #{@repo_root}"
    assert capture =~ "inspect -f {{.State.Running}} symphony-k3s-dev"
    assert capture =~ "inspect -f {{range .Mounts}}{{printf \"%s|%s\\n\" .Source .Destination}}{{end}} symphony-k3s-dev"
    assert capture =~ "rm -f symphony-k3s-dev"
    assert capture =~ "run -d --name symphony-k3s-dev"
    assert capture =~ "kubectl apply -f #{@repo_root}/k3s/manifests/namespace.yaml"
  end

  test "temporal-k3s smoke evidence validation accepts phased and vanilla contracts" do
    for {workflow_mode, expected_phase} <- [{"phased", "execute"}, {"vanilla", "run"}] do
      fixture_root = smoke_contract_fixture!(workflow_mode, expected_phase)

      {_, 0} =
        System.cmd(
          "bash",
          [
            "-lc",
            "source ./dev/temporal-k3s; validate_smoke_artifacts \"$RESULT_PATH\" \"$WORKPAD_PATH\" \"$RUN_RESPONSE_PATH\" \"$STATUS_HISTORY_PATH\" \"$WORKFLOW_MODE\" \"$EXPECTED_PHASE\""
          ],
          cd: @repo_root,
          env: [
            {"RESULT_PATH", Path.join(fixture_root, "run-result.json")},
            {"WORKPAD_PATH", Path.join(fixture_root, "workpad.md")},
            {"RUN_RESPONSE_PATH", Path.join(fixture_root, "run-response.json")},
            {"STATUS_HISTORY_PATH", Path.join(fixture_root, "status-history.jsonl")},
            {"WORKFLOW_MODE", workflow_mode},
            {"EXPECTED_PHASE", expected_phase}
          ],
          stderr_to_stdout: true
        )
    end
  end

  defp temp_harness(command_script, command_name \\ "docker") do
    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-temporal-k3s-dev-script-#{System.unique_integer([:positive])}"
      )

    bin_dir = Path.join(root, "bin")
    command_path = Path.join(bin_dir, command_name)
    capture_path = Path.join(root, "capture.txt")

    File.mkdir_p!(bin_dir)

    File.write!(
      command_path,
      """
      #!/bin/sh
      set -eu
      #{command_script}
      """
    )

    File.chmod!(command_path, 0o755)

    on_exit(fn -> File.rm_rf(root) end)

    %{
      bin_dir: bin_dir,
      capture_path: capture_path,
      state_path: Path.join(root, "state.txt")
    }
  end

  defp smoke_contract_fixture!(workflow_mode, expected_phase) do
    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-temporal-k3s-smoke-contract-#{workflow_mode}-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(root) end)
    File.mkdir_p!(root)

    run_response_path = Path.join(root, "run-response.json")
    status_history_path = Path.join(root, "status-history.jsonl")
    result_path = Path.join(root, "run-result.json")
    workpad_path = Path.join(root, "workpad.md")

    run_response =
      %{
        "workflowId" => "smoke/example",
        "runId" => "run-001",
        "status" => "queued",
        "projectId" => "smoke-example",
        "workspacePath" => "/tmp/smoke-example/workspace",
        "artifactDir" => "/tmp/smoke-example/outputs/run-001"
      }
      |> Map.merge(phase_payload(workflow_mode, expected_phase, "queued"))

    status_history =
      [
        %{
          "workflowId" => "smoke/example",
          "runId" => "run-001",
          "status" => "running"
        }
        |> Map.merge(phase_payload(workflow_mode, expected_phase, "running")),
        %{
          "workflowId" => "smoke/example",
          "runId" => "run-001",
          "status" => "succeeded"
        }
        |> Map.merge(phase_payload(workflow_mode, expected_phase, "succeeded"))
      ]

    File.write!(run_response_path, Jason.encode!(run_response))

    File.write!(
      status_history_path,
      status_history
      |> Enum.map_join("\n", &Jason.encode!/1)
      |> Kernel.<>("\n")
    )

    File.write!(
      result_path,
      Jason.encode!(%{
        "status" => "succeeded",
        "targetState" => "Human Review",
        "summary" => "Smoke workflow completed successfully.",
        "validation" => ["./dev/temporal-k3s smoke"],
        "blockedReason" => nil,
        "needsContinuation" => false
      })
    )

    File.write!(workpad_path, "Smoke workflow completed for fixture validation.\n")
    root
  end

  defp phase_payload(workflow_mode, expected_phase, status) do
    %{
      "workflow_mode" => workflow_mode,
      "current_phase" => expected_phase,
      "phases" => [
        %{
          "name" => expected_phase,
          "status" => status,
          "jobName" => "symphony-job-smoke-example",
          "artifactDir" => "/tmp/smoke-example/outputs/run-001",
          "workspacePath" => "/tmp/smoke-example/workspace"
        }
      ]
    }
  end
end
