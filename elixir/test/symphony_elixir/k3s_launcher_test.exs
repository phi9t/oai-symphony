defmodule SymphonyElixir.K3sLauncherTest do
  use ExUnit.Case, async: true

  @repo_root Path.expand("../../..", __DIR__)
  @sjob_path Path.join(@repo_root, "k3s/bin/sjob")

  test "sjob renders runtime class and GPU resources when configured" do
    %{
      capture_path: capture_path,
      project_root: project_root,
      shared_cache_root: shared_cache_root,
      wrapper_path: wrapper_path
    } =
      temp_launcher_paths()

    {output, 0} =
      System.cmd(
        @sjob_path,
        [
          "run",
          "--project-id",
          "proj-1",
          "--job",
          "job-1",
          "--project-root",
          project_root,
          "--shared-cache-root",
          shared_cache_root,
          "--gpu-count",
          "2",
          "--runtime-class",
          "nvidia",
          "--",
          "echo hi"
        ],
        cd: @repo_root,
        env: [{"SYMPHONY_KUBECTL_WRAPPER", wrapper_path}, {"SYMPHONY_CAPTURED_MANIFEST", capture_path}],
        stderr_to_stdout: true
      )

    assert output =~ "submitted symphony-job-proj-1-job-1"

    manifest = File.read!(capture_path)

    assert manifest =~ ~s(runtimeClassName: "nvidia")
    assert manifest =~ ~s(nvidia.com/gpu: "2")
    assert manifest =~ ~s(cpu: "2")
    assert manifest =~ ~s(memory: "8Gi")
  end

  test "cpu-only sjob manifests omit runtime class and GPU resources" do
    %{
      capture_path: capture_path,
      project_root: project_root,
      shared_cache_root: shared_cache_root,
      wrapper_path: wrapper_path
    } =
      temp_launcher_paths()

    {output, 0} =
      System.cmd(
        @sjob_path,
        [
          "run",
          "--project-id",
          "proj-2",
          "--job",
          "job-2",
          "--project-root",
          project_root,
          "--shared-cache-root",
          shared_cache_root,
          "--",
          "echo hi"
        ],
        cd: @repo_root,
        env: [{"SYMPHONY_KUBECTL_WRAPPER", wrapper_path}, {"SYMPHONY_CAPTURED_MANIFEST", capture_path}],
        stderr_to_stdout: true
      )

    assert output =~ "submitted symphony-job-proj-2-job-2"

    manifest = File.read!(capture_path)

    refute manifest =~ "runtimeClassName:"
    refute manifest =~ "nvidia.com/gpu:"
    assert manifest =~ ~s(requests:\n              cpu: "2"\n              memory: "8Gi")
    assert manifest =~ ~s(limits:\n              cpu: "2"\n              memory: "8Gi")
  end

  test "sjob shortens long Kubernetes names and labels deterministically" do
    %{
      capture_path: capture_path,
      project_root: project_root,
      shared_cache_root: shared_cache_root,
      wrapper_path: wrapper_path
    } =
      temp_launcher_paths()

    long_project_id = "REV-20-operator-run-temporal-k3s-proof-project-id-that-keeps-growing"
    long_job_name = "smoke-smoke-20260312100223-019ce17f-extra-job-context-for-kubernetes"

    {output, 0} =
      System.cmd(
        @sjob_path,
        [
          "run",
          "--project-id",
          long_project_id,
          "--job",
          long_job_name,
          "--project-root",
          project_root,
          "--shared-cache-root",
          shared_cache_root,
          "--",
          "echo hi"
        ],
        cd: @repo_root,
        env: [{"SYMPHONY_KUBECTL_WRAPPER", wrapper_path}, {"SYMPHONY_CAPTURED_MANIFEST", capture_path}],
        stderr_to_stdout: true
      )

    assert output =~ "submitted"

    manifest = File.read!(capture_path)

    [job_name] =
      Regex.run(~r/name: ([^\n]+)/, manifest, capture: :all_but_first)

    [project_label] =
      Regex.run(~r/symphony\/project-id: "([^"]+)"/, manifest, capture: :all_but_first)

    [job_label] =
      Regex.run(~r/symphony\/job-name: "([^"]+)"/, manifest, capture: :all_but_first)

    assert String.length(job_name) <= 63
    assert String.length(project_label) <= 63
    assert String.length(job_label) <= 63
    assert job_name =~ ~r/-\d+$/
    assert project_label =~ ~r/-\d+$/
    assert job_label =~ ~r/-\d+$/
  end

  defp temp_launcher_paths do
    root = Path.join(System.tmp_dir!(), "symphony-k3s-launcher-#{System.unique_integer([:positive])}")
    capture_path = Path.join(root, "manifest.yaml")
    project_root = Path.join(root, "project")
    shared_cache_root = Path.join(root, "cache")
    wrapper_path = Path.join(root, "kubectl-wrapper.sh")

    File.mkdir_p!(project_root)
    File.mkdir_p!(shared_cache_root)

    File.write!(
      wrapper_path,
      """
      #!/bin/sh
      cat > "${SYMPHONY_CAPTURED_MANIFEST}"
      """
    )

    File.chmod!(wrapper_path, 0o755)

    on_exit(fn -> File.rm_rf(root) end)

    %{
      capture_path: capture_path,
      project_root: project_root,
      shared_cache_root: shared_cache_root,
      wrapper_path: wrapper_path
    }
  end
end
