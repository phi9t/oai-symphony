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

  defp temp_harness(docker_script) do
    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-temporal-k3s-dev-script-#{System.unique_integer([:positive])}"
      )

    bin_dir = Path.join(root, "bin")
    docker_path = Path.join(bin_dir, "docker")
    capture_path = Path.join(root, "capture.txt")

    File.mkdir_p!(bin_dir)

    File.write!(
      docker_path,
      """
      #!/bin/sh
      set -eu
      #{docker_script}
      """
    )

    File.chmod!(docker_path, 0o755)

    on_exit(fn -> File.rm_rf(root) end)

    %{
      bin_dir: bin_dir,
      capture_path: capture_path
    }
  end
end
