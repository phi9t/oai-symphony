defmodule SymphonyElixirWeb.Presenter do
  @moduledoc """
  Backward-compatible facade for the observability boundary.
  """

  alias SymphonyElixirWeb.Observability

  @spec state_payload(GenServer.name(), timeout()) :: map()
  defdelegate state_payload(orchestrator, snapshot_timeout_ms), to: Observability

  @spec issue_payload(String.t(), GenServer.name(), timeout()) :: {:ok, map()} | {:error, :issue_not_found}
  defdelegate issue_payload(issue_identifier, orchestrator, snapshot_timeout_ms), to: Observability

  @spec refresh_payload(GenServer.name()) :: {:ok, map()} | {:error, :unavailable}
  defdelegate refresh_payload(orchestrator), to: Observability

  @spec retry_payload(GenServer.name(), String.t()) :: {:ok, map()} | {:error, :invalid_issue_identifier | :issue_not_found | :unavailable}
  defdelegate retry_payload(orchestrator, issue_identifier), to: Observability

  @spec cleanup_payload(GenServer.name(), String.t()) :: {:ok, map()} | {:error, :invalid_issue_identifier | :unavailable}
  defdelegate cleanup_payload(orchestrator, issue_identifier), to: Observability
end
