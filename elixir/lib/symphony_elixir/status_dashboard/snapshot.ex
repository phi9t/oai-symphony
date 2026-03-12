defmodule SymphonyElixir.StatusDashboard.Snapshot do
  @moduledoc """
  Shared snapshot projection for operator-facing status surfaces.
  """

  alias SymphonyElixir.Orchestrator

  @type t :: %{
          required(:running) => list(),
          required(:retrying) => list(),
          required(:codex_totals) => map(),
          optional(:rate_limits) => term(),
          optional(:polling) => term()
        }

  @type result :: {:ok, t()} | :timeout | :unavailable | :error

  @spec fetch(GenServer.server(), timeout()) :: result()
  def fetch(orchestrator \\ Orchestrator, timeout \\ 15_000) do
    case Orchestrator.snapshot(orchestrator, timeout) do
      %{running: running, retrying: retrying, codex_totals: codex_totals} = snapshot
      when is_list(running) and is_list(retrying) ->
        {:ok,
         %{
           running: running,
           retrying: retrying,
           codex_totals: codex_totals,
           rate_limits: Map.get(snapshot, :rate_limits),
           polling: Map.get(snapshot, :polling)
         }}

      :timeout ->
        :timeout

      :unavailable ->
        :unavailable

      _ ->
        :error
    end
  end
end
