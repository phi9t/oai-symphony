defmodule SymphonyElixir.StatusDashboard.Projection do
  @moduledoc false

  alias SymphonyElixir.Orchestrator

  @spec snapshot_payload(GenServer.server()) :: {:ok, map()} | :error
  def snapshot_payload(orchestrator \\ Orchestrator) do
    if Process.whereis(orchestrator) do
      case Orchestrator.snapshot(orchestrator, 15_000) do
        %{running: running, retrying: retrying, codex_totals: codex_totals} = snapshot
        when is_list(running) and is_list(retrying) ->
          {:ok,
           %{
             running: running,
             retrying: retrying,
             codex_totals: codex_totals,
             runtime: Map.get(snapshot, :runtime),
             rate_limits: Map.get(snapshot, :rate_limits),
             polling: Map.get(snapshot, :polling)
           }}

        _ ->
          :error
      end
    else
      :error
    end
  end

  @spec compact_session_id(String.t() | term()) :: String.t()
  def compact_session_id(nil), do: "n/a"
  def compact_session_id(session_id) when not is_binary(session_id), do: "n/a"

  def compact_session_id(session_id) do
    if String.length(session_id) > 10 do
      String.slice(session_id, 0, 4) <> "..." <> String.slice(session_id, -6, 6)
    else
      session_id
    end
  end
end
