defmodule SymphonyElixirWeb.Observability do
  @moduledoc """
  Operator-facing observability surface shared by Phoenix wiring.
  """

  alias SymphonyElixir.StatusDashboard.Snapshot
  alias SymphonyElixirWeb.Observability.{Operator, Projection}

  @spec state_payload(GenServer.name(), timeout()) :: map()
  def state_payload(orchestrator, snapshot_timeout_ms) do
    orchestrator
    |> Snapshot.fetch(snapshot_timeout_ms)
    |> Projection.state_payload()
  end

  @spec issue_payload(String.t(), GenServer.name(), timeout()) :: {:ok, map()} | {:error, :issue_not_found}
  def issue_payload(issue_identifier, orchestrator, snapshot_timeout_ms) when is_binary(issue_identifier) do
    Projection.issue_payload(issue_identifier, Snapshot.fetch(orchestrator, snapshot_timeout_ms))
  end

  @spec refresh_payload(GenServer.name()) :: {:ok, map()} | {:error, :unavailable}
  def refresh_payload(orchestrator), do: Operator.refresh_payload(orchestrator)

  @spec retry_payload(GenServer.name(), String.t()) :: {:ok, map()} | {:error, :invalid_issue_identifier | :issue_not_found | :unavailable}
  def retry_payload(orchestrator, issue_identifier), do: Operator.retry_payload(orchestrator, issue_identifier)

  @spec cleanup_payload(GenServer.name(), String.t()) ::
          {:ok, map()} | {:error, :invalid_issue_identifier | :unavailable}
  def cleanup_payload(orchestrator, issue_identifier), do: Operator.cleanup_payload(orchestrator, issue_identifier)
end
