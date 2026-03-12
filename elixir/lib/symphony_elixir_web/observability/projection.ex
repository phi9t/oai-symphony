defmodule SymphonyElixirWeb.Observability.Projection do
  @moduledoc """
  Shapes operator-facing observability payloads from orchestrator snapshots.
  """

  alias SymphonyElixir.Execution
  alias SymphonyElixir.Observability.CodexMessage

  @type snapshot_result :: {:ok, map()} | :timeout | :unavailable | :error

  @spec state_payload(snapshot_result(), DateTime.t()) :: map()
  def state_payload(snapshot_result, generated_at \\ DateTime.utc_now())

  def state_payload({:ok, snapshot}, generated_at) do
    state_payload_from_snapshot(snapshot, generated_at)
  end

  def state_payload(:timeout, generated_at) do
    error_payload(generated_at, "snapshot_timeout", "Snapshot timed out")
  end

  def state_payload(:unavailable, generated_at) do
    error_payload(generated_at, "snapshot_unavailable", "Snapshot unavailable")
  end

  def state_payload(:error, generated_at) do
    error_payload(generated_at, "snapshot_unavailable", "Snapshot unavailable")
  end

  @spec state_payload_from_snapshot(map(), DateTime.t()) :: map()
  def state_payload_from_snapshot(%{} = snapshot, generated_at \\ DateTime.utc_now()) do
    %{
      generated_at: iso8601(generated_at),
      counts: %{
        running: length(snapshot.running),
        retrying: length(snapshot.retrying)
      },
      running: Enum.map(snapshot.running, &running_entry_payload/1),
      retrying: Enum.map(snapshot.retrying, &retry_entry_payload(&1, generated_at)),
      codex_totals: snapshot.codex_totals,
      rate_limits: snapshot.rate_limits
    }
    |> put_optional_field(:runtime, Map.get(snapshot, :runtime))
  end

  @spec issue_payload(String.t(), snapshot_result()) :: {:ok, map()} | {:error, :issue_not_found}
  def issue_payload(issue_identifier, snapshot_result)

  def issue_payload(issue_identifier, {:ok, snapshot}) when is_binary(issue_identifier) do
    issue_payload_from_snapshot(issue_identifier, snapshot)
  end

  def issue_payload(issue_identifier, _snapshot_result) when is_binary(issue_identifier) do
    {:error, :issue_not_found}
  end

  @spec issue_payload_from_snapshot(String.t(), map(), DateTime.t()) :: {:ok, map()} | {:error, :issue_not_found}
  def issue_payload_from_snapshot(issue_identifier, %{} = snapshot, reference_time \\ DateTime.utc_now())
      when is_binary(issue_identifier) do
    running = Enum.find(snapshot.running, &(&1.identifier == issue_identifier))
    retry = Enum.find(snapshot.retrying, &(&1.identifier == issue_identifier))

    if is_nil(running) and is_nil(retry) do
      {:error, :issue_not_found}
    else
      {:ok, issue_payload_body(issue_identifier, running, retry, reference_time)}
    end
  end

  defp error_payload(generated_at, code, message) do
    %{generated_at: iso8601(generated_at), error: %{code: code, message: message}}
  end

  defp issue_payload_body(issue_identifier, running, retry, reference_time) do
    %{
      issue_identifier: issue_identifier,
      issue_id: issue_id_from_entries(running, retry),
      status: issue_status(running, retry),
      workspace: %{
        path: Execution.workspace_path(issue_identifier, running || retry)
      },
      attempts: %{
        restart_count: restart_count(retry),
        current_retry_attempt: retry_attempt(retry)
      },
      running: running && running_issue_payload(running),
      retry: retry && retry_issue_payload(retry, reference_time),
      logs: %{
        codex_session_logs: []
      },
      recent_events: (running && recent_events_payload(running)) || [],
      last_error: retry && retry.error,
      tracked: %{}
    }
  end

  defp issue_id_from_entries(running, retry),
    do: (running && running.issue_id) || (retry && retry.issue_id)

  defp restart_count(retry), do: max(retry_attempt(retry) - 1, 0)
  defp retry_attempt(nil), do: 0
  defp retry_attempt(retry), do: retry.attempt || 0

  defp issue_status(_running, nil), do: "running"
  defp issue_status(nil, _retry), do: "retrying"
  defp issue_status(_running, _retry), do: "running"

  defp running_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      state: entry.state,
      session_id: entry.session_id,
      turn_count: Map.get(entry, :turn_count, 0),
      last_event: entry.last_codex_event,
      last_message: summarize_message(entry.last_codex_message),
      started_at: iso8601(entry.started_at),
      last_event_at: iso8601(entry.last_codex_timestamp),
      tokens: %{
        input_tokens: entry.codex_input_tokens,
        output_tokens: entry.codex_output_tokens,
        total_tokens: entry.codex_total_tokens
      }
    }
    |> put_optional_running_metadata(entry)
  end

  defp retry_entry_payload(entry, reference_time) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      attempt: entry.attempt,
      due_at: due_at_iso8601(reference_time, entry.due_in_ms),
      error: entry.error
    }
    |> put_optional_runtime_metadata(entry)
  end

  defp running_issue_payload(running) do
    %{
      session_id: running.session_id,
      turn_count: Map.get(running, :turn_count, 0),
      state: running.state,
      started_at: iso8601(running.started_at),
      last_event: running.last_codex_event,
      last_message: summarize_message(running.last_codex_message),
      last_event_at: iso8601(running.last_codex_timestamp),
      tokens: %{
        input_tokens: running.codex_input_tokens,
        output_tokens: running.codex_output_tokens,
        total_tokens: running.codex_total_tokens
      }
    }
    |> put_optional_running_metadata(running)
  end

  defp retry_issue_payload(retry, reference_time) do
    %{
      attempt: retry.attempt,
      due_at: due_at_iso8601(reference_time, retry.due_in_ms),
      error: retry.error
    }
    |> put_optional_runtime_metadata(retry)
  end

  defp recent_events_payload(running) do
    [
      %{
        at: iso8601(running.last_codex_timestamp),
        event: running.last_codex_event,
        message: summarize_message(running.last_codex_message)
      }
    ]
    |> Enum.reject(&is_nil(&1.at))
  end

  defp summarize_message(nil), do: nil
  defp summarize_message(message), do: CodexMessage.humanize(message)

  defp put_optional_running_metadata(payload, entry), do: put_optional_runtime_metadata(payload, entry)

  defp put_optional_runtime_metadata(payload, entry) do
    payload
    |> put_optional_field(:execution_backend, Map.get(entry, :execution_backend))
    |> put_optional_field(:workflow_id, Map.get(entry, :workflow_id))
    |> put_optional_field(:workflow_run_id, Map.get(entry, :workflow_run_id))
    |> put_optional_field(:workflow_mode, Map.get(entry, :workflow_mode))
    |> put_optional_field(:current_phase, Map.get(entry, :current_phase))
    |> put_optional_field(:phases, Map.get(entry, :phases))
    |> put_optional_field(:project_id, Map.get(entry, :project_id))
    |> put_optional_field(:workspace_path, Map.get(entry, :workspace_path))
    |> put_optional_field(:artifact_dir, Map.get(entry, :artifact_dir))
    |> put_optional_field(:job_name, Map.get(entry, :job_name))
    |> put_optional_field(:last_execution_status, Map.get(entry, :last_execution_status))
    |> put_optional_field(:last_successful_status_poll, iso8601(Map.get(entry, :last_successful_status_poll_at)))
    |> put_optional_field(
      :last_known_org_sync_result,
      normalized_org_sync_result(Map.get(entry, :last_known_org_sync_result))
    )
    |> put_optional_field(:failure_code, Map.get(entry, :failure_code))
  end

  defp put_optional_field(payload, _key, nil), do: payload
  defp put_optional_field(payload, key, value), do: Map.put(payload, key, value)

  defp normalized_org_sync_result(%{} = org_sync_result), do: org_sync_result
  defp normalized_org_sync_result(_org_sync_result), do: nil

  defp due_at_iso8601(%DateTime{} = reference_time, due_in_ms) when is_integer(due_in_ms) do
    reference_time
    |> DateTime.add(div(due_in_ms, 1_000), :second)
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp due_at_iso8601(_reference_time, _due_in_ms), do: nil

  defp iso8601(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp iso8601(_datetime), do: nil
end
