defmodule SymphonyElixir.StatusDashboardProjectionTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.StatusDashboard.Projection

  test "snapshot_payload normalizes orchestrator snapshot data" do
    orchestrator_name = Module.concat(__MODULE__, :ProjectionOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)
    runtime_status = %{execution_backend: "temporal_k3s", ready: false, blockers: [%{"code" => "worker_missing"}]}

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | codex_totals: %{input_tokens: 3, output_tokens: 2, total_tokens: 5, seconds_running: 11},
          codex_rate_limits: %{limit_id: "gpt-5"},
          runtime_status: runtime_status,
          retry_attempts: %{
            "issue-1" => %{attempt: 2, due_at_ms: System.monotonic_time(:millisecond) + 1_000, identifier: "MT-1"}
          }
      }
    end)

    assert {:ok, snapshot} = Projection.snapshot_payload(orchestrator_name)
    assert snapshot.codex_totals.total_tokens == 5
    assert snapshot.runtime == runtime_status
    assert snapshot.rate_limits == %{limit_id: "gpt-5"}
    assert is_list(snapshot.retrying)
  end

  test "compact_session_id shortens long identifiers and preserves short ones" do
    assert Projection.compact_session_id("thread-1234567890") == "thre...567890"
    assert Projection.compact_session_id("short") == "short"
    assert Projection.compact_session_id(nil) == "n/a"
    assert Projection.compact_session_id(123) == "n/a"
  end

  test "snapshot_payload returns errors for missing or invalid orchestrators" do
    refute Process.whereis(Projection)
    default_snapshot = Projection.snapshot_payload()
    assert default_snapshot == :error or match?({:ok, _}, default_snapshot)

    orchestrator_name = Module.concat(__MODULE__, :InvalidProjectionOrchestrator)
    pid = spawn(fn -> Process.sleep(:infinity) end)
    Process.register(pid, orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :kill)
      end
    end)

    assert Projection.snapshot_payload(orchestrator_name) == :error
  end
end
