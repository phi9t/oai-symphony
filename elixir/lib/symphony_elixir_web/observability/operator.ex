defmodule SymphonyElixirWeb.Observability.Operator do
  @moduledoc """
  Server-side operator actions shared by the dashboard and API wiring.
  """

  alias SymphonyElixir.Orchestrator

  @spec refresh_payload(GenServer.name()) :: {:ok, map()} | {:error, :unavailable}
  def refresh_payload(orchestrator) do
    case Orchestrator.request_refresh(orchestrator) do
      :unavailable -> {:error, :unavailable}
      payload -> {:ok, normalize_timestamps(payload)}
    end
  end

  @spec retry_payload(GenServer.name(), String.t()) :: {:ok, map()} | {:error, :invalid_issue_identifier | :issue_not_found | :unavailable}
  def retry_payload(orchestrator, issue_identifier) do
    case Orchestrator.request_retry(orchestrator, issue_identifier) do
      :unavailable -> {:error, :unavailable}
      :invalid_issue_identifier -> {:error, :invalid_issue_identifier}
      :issue_not_found -> {:error, :issue_not_found}
      payload -> {:ok, normalize_timestamps(payload)}
    end
  end

  @spec cleanup_payload(GenServer.name(), String.t()) :: {:ok, map()} | {:error, :invalid_issue_identifier | :unavailable}
  def cleanup_payload(orchestrator, issue_identifier) do
    case Orchestrator.request_cleanup(orchestrator, issue_identifier) do
      :unavailable -> {:error, :unavailable}
      :invalid_issue_identifier -> {:error, :invalid_issue_identifier}
      payload -> {:ok, normalize_timestamps(payload)}
    end
  end

  defp normalize_timestamps(payload) when is_map(payload) do
    payload
    |> normalize_timestamp(:requested_at)
    |> normalize_timestamp(:completed_at)
  end

  defp normalize_timestamp(payload, key) do
    Map.update(payload, key, nil, fn
      %DateTime{} = datetime ->
        datetime
        |> DateTime.truncate(:second)
        |> DateTime.to_iso8601()

      value ->
        value
    end)
  end
end
