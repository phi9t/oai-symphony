defmodule SymphonyElixir.Orchestrator.Reconcile do
  @moduledoc false

  alias SymphonyElixir.Orchestrator.Dispatch
  alias SymphonyElixir.Tracker.Issue

  @type issue_action_reason :: :terminal_state | :unroutable | :inactive_state

  @spec issue_action(Issue.t(), term(), term()) ::
          :refresh | {:terminate, boolean(), issue_action_reason()} | :ignore
  def issue_action(%Issue{} = issue, active_states, terminal_states) do
    cond do
      Dispatch.terminal_issue_state?(issue.state, terminal_states) ->
        {:terminate, true, :terminal_state}

      !Dispatch.issue_routable_to_worker?(issue) ->
        {:terminate, false, :unroutable}

      Dispatch.active_issue_state?(issue.state, active_states) ->
        :refresh

      true ->
        {:terminate, false, :inactive_state}
    end
  end

  def issue_action(_issue, _active_states, _terminal_states), do: :ignore

  @spec missing_issue_ids([String.t()], [Issue.t()]) :: [String.t()]
  def missing_issue_ids(requested_issue_ids, issues) when is_list(requested_issue_ids) and is_list(issues) do
    visible_issue_ids =
      issues
      |> Enum.flat_map(fn
        %Issue{id: issue_id} when is_binary(issue_id) -> [issue_id]
        _ -> []
      end)
      |> MapSet.new()

    Enum.reject(requested_issue_ids, &MapSet.member?(visible_issue_ids, &1))
  end

  def missing_issue_ids(_requested_issue_ids, _issues), do: []

  @spec stall_elapsed_ms(map(), DateTime.t()) :: non_neg_integer() | nil
  def stall_elapsed_ms(running_entry, now) when is_map(running_entry) and is_struct(now, DateTime) do
    case last_activity_timestamp(running_entry) do
      %DateTime{} = timestamp ->
        max(0, DateTime.diff(now, timestamp, :millisecond))

      _ ->
        nil
    end
  end

  def stall_elapsed_ms(_running_entry, _now), do: nil

  @spec stalled?(map(), DateTime.t(), integer()) :: boolean()
  def stalled?(running_entry, now, timeout_ms) when is_integer(timeout_ms) and timeout_ms > 0 do
    case stall_elapsed_ms(running_entry, now) do
      elapsed_ms when is_integer(elapsed_ms) -> elapsed_ms > timeout_ms
      _ -> false
    end
  end

  def stalled?(_running_entry, _now, _timeout_ms), do: false

  @doc false
  @spec last_activity_timestamp(map()) :: DateTime.t() | nil
  def last_activity_timestamp(running_entry) when is_map(running_entry) do
    Map.get(running_entry, :last_codex_timestamp) || Map.get(running_entry, :started_at)
  end

  def last_activity_timestamp(_running_entry), do: nil
end
