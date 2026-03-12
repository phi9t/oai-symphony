defmodule SymphonyElixir.Orchestrator.Dispatch do
  @moduledoc false

  alias SymphonyElixir.Tracker.Issue

  @spec sort_issues([Issue.t()]) :: [Issue.t()]
  def sort_issues(issues) when is_list(issues) do
    Enum.sort_by(issues, fn
      %Issue{} = issue ->
        {priority_rank(issue.priority), issue_created_at_sort_key(issue), issue.identifier || issue.id || ""}

      _ ->
        {priority_rank(nil), issue_created_at_sort_key(nil), ""}
    end)
  end

  @spec should_dispatch?(Issue.t(), map(), term(), term()) :: boolean()
  def should_dispatch?(issue, state, active_states, terminal_states),
    do: should_dispatch?(issue, state, active_states, terminal_states, [])

  @spec should_dispatch?(Issue.t(), map(), term(), term(), keyword()) :: boolean()
  def should_dispatch?(%Issue{} = issue, state, active_states, terminal_states, opts) do
    running = Map.get(state, :running, %{})
    claimed = Map.get(state, :claimed, MapSet.new())
    available_slots = Keyword.get(opts, :available_slots, 0)
    state_limit_fun = Keyword.get(opts, :state_limit_fun, fn _state_name -> 0 end)

    candidate_issue?(issue, active_states, terminal_states) and
      !todo_issue_blocked_by_non_terminal?(issue, terminal_states) and
      !MapSet.member?(claimed, issue.id) and
      !Map.has_key?(running, issue.id) and
      available_slots > 0 and
      state_slots_available?(issue, running, state_limit_fun)
  end

  def should_dispatch?(_issue, _state, _active_states, _terminal_states, _opts), do: false

  @spec revalidate_issue_for_dispatch(Issue.t(), ([String.t()] -> term()), term(), term()) ::
          {:ok, Issue.t()} | {:skip, Issue.t() | :missing} | {:error, term()}
  def revalidate_issue_for_dispatch(%Issue{id: issue_id}, issue_fetcher, active_states, terminal_states)
      when is_binary(issue_id) and is_function(issue_fetcher, 1) do
    case issue_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if retry_candidate_issue?(refreshed_issue, active_states, terminal_states) do
          {:ok, refreshed_issue}
        else
          {:skip, refreshed_issue}
        end

      {:ok, []} ->
        {:skip, :missing}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def revalidate_issue_for_dispatch(issue, _issue_fetcher, _active_states, _terminal_states), do: {:ok, issue}

  @spec retry_candidate_issue?(Issue.t(), term(), term()) :: boolean()
  def retry_candidate_issue?(%Issue{} = issue, active_states, terminal_states) do
    candidate_issue?(issue, active_states, terminal_states) and
      !todo_issue_blocked_by_non_terminal?(issue, terminal_states)
  end

  def retry_candidate_issue?(_issue, _active_states, _terminal_states), do: false

  @spec dispatch_slots_available?(Issue.t(), map()) :: boolean()
  def dispatch_slots_available?(issue, state), do: dispatch_slots_available?(issue, state, [])

  @spec dispatch_slots_available?(Issue.t(), map(), keyword()) :: boolean()
  def dispatch_slots_available?(%Issue{} = issue, state, opts) do
    available_slots = Keyword.get(opts, :available_slots, 0)
    running = Map.get(state, :running, %{})
    state_limit_fun = Keyword.get(opts, :state_limit_fun, fn _state_name -> 0 end)

    available_slots > 0 and state_slots_available?(issue, running, state_limit_fun)
  end

  def dispatch_slots_available?(_issue, _state, _opts), do: false

  @spec active_state_set([String.t()]) :: term()
  def active_state_set(states) when is_list(states) do
    states
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  def active_state_set(_states), do: MapSet.new()

  @spec terminal_state_set([String.t()]) :: term()
  def terminal_state_set(states) when is_list(states) do
    states
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  def terminal_state_set(_states), do: MapSet.new()

  @doc false
  @spec candidate_issue?(Issue.t(), term(), term()) :: boolean()
  def candidate_issue?(
        %Issue{id: id, identifier: identifier, title: title, state: state_name} = issue,
        active_states,
        terminal_states
      )
      when is_binary(id) and is_binary(identifier) and is_binary(title) and is_binary(state_name) do
    issue_routable_to_worker?(issue) and
      active_issue_state?(state_name, active_states) and
      !terminal_issue_state?(state_name, terminal_states)
  end

  def candidate_issue?(_issue, _active_states, _terminal_states), do: false

  @doc false
  @spec issue_routable_to_worker?(Issue.t()) :: boolean()
  def issue_routable_to_worker?(%Issue{assigned_to_worker: assigned_to_worker})
      when is_boolean(assigned_to_worker),
      do: assigned_to_worker

  def issue_routable_to_worker?(_issue), do: true

  @doc false
  @spec todo_issue_blocked_by_non_terminal?(Issue.t(), term()) :: boolean()
  def todo_issue_blocked_by_non_terminal?(%Issue{state: issue_state, blocked_by: blockers}, terminal_states)
      when is_binary(issue_state) and is_list(blockers) do
    normalize_issue_state(issue_state) == "todo" and
      Enum.any?(blockers, fn
        %{state: blocker_state} when is_binary(blocker_state) ->
          !terminal_issue_state?(blocker_state, terminal_states)

        _ ->
          true
      end)
  end

  def todo_issue_blocked_by_non_terminal?(_issue, _terminal_states), do: false

  @doc false
  @spec terminal_issue_state?(String.t() | term(), term()) :: boolean()
  def terminal_issue_state?(state_name, terminal_states) when is_binary(state_name) do
    MapSet.member?(terminal_states, normalize_issue_state(state_name))
  end

  def terminal_issue_state?(_state_name, _terminal_states), do: false

  @doc false
  @spec active_issue_state?(String.t() | term(), term()) :: boolean()
  def active_issue_state?(state_name, active_states) when is_binary(state_name) do
    MapSet.member?(active_states, normalize_issue_state(state_name))
  end

  def active_issue_state?(_state_name, _active_states), do: false

  @doc false
  @spec normalize_issue_state(String.t() | term()) :: String.t()
  def normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.downcase()
    |> String.trim()
  end

  def normalize_issue_state(_state_name), do: ""

  defp state_slots_available?(%Issue{state: issue_state}, running, state_limit_fun)
       when is_map(running) and is_function(state_limit_fun, 1) do
    limit = state_limit_fun.(issue_state)
    used = running_issue_count_for_state(running, issue_state)
    limit > used
  end

  defp state_slots_available?(_issue, _running, _state_limit_fun), do: false

  defp running_issue_count_for_state(running, issue_state) when is_map(running) do
    normalized_state = normalize_issue_state(issue_state)

    Enum.count(running, fn
      {_id, %{issue: %Issue{state: state_name}}} ->
        normalize_issue_state(state_name) == normalized_state

      _ ->
        false
    end)
  end

  defp priority_rank(priority) when is_integer(priority) and priority in 1..4, do: priority
  defp priority_rank(_priority), do: 5

  defp issue_created_at_sort_key(%Issue{created_at: %DateTime{} = created_at}) do
    DateTime.to_unix(created_at, :microsecond)
  end

  defp issue_created_at_sort_key(%Issue{}), do: 9_223_372_036_854_775_807
  defp issue_created_at_sort_key(_issue), do: 9_223_372_036_854_775_807
end
