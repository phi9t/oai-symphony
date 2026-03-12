defmodule SymphonyElixir.Orchestrator do
  @moduledoc """
  Polls the configured tracker and dispatches repository copies to Codex-backed workers.
  """

  use GenServer
  require Logger
  import Bitwise, only: [<<<: 2]

  alias SymphonyElixir.{
    AgentRunner,
    Config,
    Execution,
    Orchestrator.Dispatch,
    Orchestrator.Reconcile,
    StatusDashboard,
    Tracker
  }

  alias SymphonyElixir.Tracker.Issue

  @continuation_retry_delay_ms 1_000
  @failure_retry_base_ms 10_000
  # Slightly above the dashboard render interval so "checking now…" can render.
  @poll_transition_render_delay_ms 20
  @retry_health_metadata_fields [
    :execution_backend,
    :workflow_id,
    :workflow_run_id,
    :project_id,
    :workspace_path,
    :artifact_dir,
    :job_name,
    :last_execution_status,
    :last_successful_status_poll_at,
    :last_known_org_sync_result,
    :failure_code
  ]
  @empty_codex_totals %{
    input_tokens: 0,
    output_tokens: 0,
    total_tokens: 0,
    seconds_running: 0
  }

  defmodule State do
    @moduledoc """
    Runtime state for the orchestrator polling loop.
    """

    defstruct [
      :poll_interval_ms,
      :max_concurrent_agents,
      :next_poll_due_at_ms,
      :poll_check_in_progress,
      :tick_timer_ref,
      :tick_token,
      :runtime_status,
      running: %{},
      completed: MapSet.new(),
      claimed: MapSet.new(),
      retry_attempts: %{},
      codex_totals: nil,
      codex_rate_limits: nil
    ]
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(_opts) do
    now_ms = System.monotonic_time(:millisecond)

    state = %State{
      poll_interval_ms: Config.poll_interval_ms(),
      max_concurrent_agents: Config.max_concurrent_agents(),
      next_poll_due_at_ms: now_ms,
      poll_check_in_progress: false,
      tick_timer_ref: nil,
      tick_token: nil,
      runtime_status: nil,
      codex_totals: @empty_codex_totals,
      codex_rate_limits: nil
    }

    run_terminal_workspace_cleanup()
    state = schedule_tick(state, 0)

    {:ok, state}
  end

  @impl true
  def handle_info({:tick, tick_token}, %{tick_token: tick_token} = state)
      when is_reference(tick_token) do
    state = refresh_runtime_config(state)

    state = %{
      state
      | poll_check_in_progress: true,
        next_poll_due_at_ms: nil,
        tick_timer_ref: nil,
        tick_token: nil
    }

    notify_dashboard()
    :ok = schedule_poll_cycle_start()
    {:noreply, state}
  end

  def handle_info({:tick, _tick_token}, state), do: {:noreply, state}

  def handle_info(:tick, state) do
    state = refresh_runtime_config(state)

    state = %{
      state
      | poll_check_in_progress: true,
        next_poll_due_at_ms: nil,
        tick_timer_ref: nil,
        tick_token: nil
    }

    notify_dashboard()
    :ok = schedule_poll_cycle_start()
    {:noreply, state}
  end

  def handle_info(:run_poll_cycle, state) do
    state = refresh_runtime_config(state)
    state = maybe_dispatch(state)
    state = schedule_tick(state, state.poll_interval_ms)
    state = %{state | poll_check_in_progress: false}

    notify_dashboard()
    {:noreply, state}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{running: running} = state
      ) do
    case find_issue_id_for_ref(running, ref) do
      nil ->
        {:noreply, state}

      issue_id ->
        {running_entry, state} = pop_running_entry(state, issue_id)
        state = record_session_completion_totals(state, running_entry)
        session_id = running_entry_session_id(running_entry)

        state =
          case reason do
            :normal ->
              Logger.info("Agent task completed for issue_id=#{issue_id} session_id=#{session_id}; scheduling active-state continuation check")

              state
              |> complete_issue(issue_id)
              |> schedule_issue_retry(issue_id, 1, %{
                identifier: running_entry.identifier,
                delay_type: :continuation
              })

            _ ->
              Logger.warning("Agent task exited for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason)}; scheduling retry")

              next_attempt = next_retry_attempt_from_running(running_entry)

              retry_metadata =
                %{identifier: running_entry.identifier, error: "agent exited: #{inspect(reason)}"}
                |> merge_retry_health_metadata(running_entry)
                |> maybe_put_failure_code(Map.get(running_entry, :failure_code) || failure_code_from_reason(reason))
                |> maybe_put_last_known_org_sync_result(Map.get(running_entry, :last_known_org_sync_result) || org_sync_result_from_reason(reason))

              schedule_issue_retry(state, issue_id, next_attempt, retry_metadata)
          end

        Logger.info("Agent task finished for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason)}")

        notify_dashboard()
        {:noreply, state}
    end
  end

  def handle_info(
        {:codex_worker_update, issue_id, %{event: _, timestamp: _} = update},
        %{running: running} = state
      ) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        {updated_running_entry, token_delta} = integrate_codex_update(running_entry, update)

        state =
          state
          |> apply_codex_token_delta(token_delta)
          |> apply_codex_rate_limits(update)

        notify_dashboard()
        {:noreply, %{state | running: Map.put(running, issue_id, updated_running_entry)}}
    end
  end

  def handle_info({:codex_worker_update, _issue_id, _update}, state), do: {:noreply, state}

  def handle_info({:retry_issue, issue_id, retry_token}, state) do
    result =
      case pop_retry_attempt_state(state, issue_id, retry_token) do
        {:ok, attempt, metadata, state} -> handle_retry_issue(state, issue_id, attempt, metadata)
        :missing -> {:noreply, state}
      end

    notify_dashboard()
    result
  end

  def handle_info({:retry_issue, _issue_id}, state), do: {:noreply, state}

  def handle_info(msg, state) do
    Logger.debug("Orchestrator ignored message: #{inspect(msg)}")
    {:noreply, state}
  end

  defp maybe_dispatch(%State{} = state) do
    state = reconcile_running_issues(state)

    case Config.validate!() do
      {:error, reason} ->
        log_dispatch_config_error(reason)
        state

      :ok ->
        state
        |> refresh_execution_runtime_status()
        |> maybe_dispatch_ready_runtime()
    end
  end

  defp maybe_dispatch_ready_runtime(%State{} = state) do
    if runtime_ready?(state.runtime_status) do
      maybe_dispatch_available_slots(state)
    else
      state
    end
  end

  defp maybe_dispatch_available_slots(%State{} = state) do
    if available_slots(state) > 0 do
      maybe_choose_issues_from_tracker(state)
    else
      state
    end
  end

  defp maybe_choose_issues_from_tracker(%State{} = state) do
    case Tracker.fetch_candidate_issues() do
      {:ok, issues} ->
        choose_issues(issues, state)

      {:error, reason} ->
        Logger.error("Failed to fetch from tracker: #{inspect(reason)}")
        state
    end
  end

  defp log_dispatch_config_error(:missing_linear_api_token),
    do: Logger.error("Linear API token missing in WORKFLOW.md")

  defp log_dispatch_config_error(:missing_linear_project_slug),
    do: Logger.error("Linear project slug missing in WORKFLOW.md")

  defp log_dispatch_config_error(:missing_org_tracker_file),
    do: Logger.error("Org tracker file missing in WORKFLOW.md")

  defp log_dispatch_config_error(:missing_org_tracker_root_id),
    do: Logger.error("Org tracker root_id missing in WORKFLOW.md")

  defp log_dispatch_config_error(:missing_org_emacsclient),
    do: Logger.error("Org tracker emacsclient command is unavailable")

  defp log_dispatch_config_error(:missing_tracker_kind),
    do: Logger.error("Tracker kind missing in WORKFLOW.md")

  defp log_dispatch_config_error({:unsupported_execution_kind, kind}),
    do: Logger.error("Unsupported execution kind in WORKFLOW.md: #{inspect(kind)}")

  defp log_dispatch_config_error(:missing_temporal_helper_command),
    do: Logger.error("Temporal helper command missing in WORKFLOW.md")

  defp log_dispatch_config_error(:missing_repository_origin_url),
    do: Logger.error("Repository origin URL missing in WORKFLOW.md for temporal_k3s execution")

  defp log_dispatch_config_error({:unsupported_tracker_kind, kind}),
    do: Logger.error("Unsupported tracker kind in WORKFLOW.md: #{inspect(kind)}")

  defp log_dispatch_config_error(:missing_codex_command),
    do: Logger.error("Codex command missing in WORKFLOW.md")

  defp log_dispatch_config_error({:invalid_codex_approval_policy, value}),
    do: Logger.error("Invalid codex.approval_policy in WORKFLOW.md: #{inspect(value)}")

  defp log_dispatch_config_error({:invalid_codex_thread_sandbox, value}),
    do: Logger.error("Invalid codex.thread_sandbox in WORKFLOW.md: #{inspect(value)}")

  defp log_dispatch_config_error({:invalid_codex_turn_sandbox_policy, reason}),
    do: Logger.error("Invalid codex.turn_sandbox_policy in WORKFLOW.md: #{inspect(reason)}")

  defp log_dispatch_config_error({:missing_workflow_file, path, reason}),
    do: Logger.error("Missing WORKFLOW.md at #{path}: #{inspect(reason)}")

  defp log_dispatch_config_error(:workflow_front_matter_not_a_map),
    do: Logger.error("Failed to parse WORKFLOW.md: workflow front matter must decode to a map")

  defp log_dispatch_config_error({:workflow_parse_error, reason}),
    do: Logger.error("Failed to parse WORKFLOW.md: #{inspect(reason)}")

  defp log_dispatch_config_error(reason),
    do: Logger.error("Failed to fetch from tracker: #{inspect(reason)}")

  defp reconcile_running_issues(%State{} = state) do
    state = reconcile_stalled_running_issues(state)
    running_ids = Map.keys(state.running)

    if running_ids == [] do
      state
    else
      case Tracker.fetch_issue_states_by_ids(running_ids) do
        {:ok, issues} ->
          issues
          |> reconcile_running_issue_states(
            state,
            active_state_set(),
            terminal_state_set()
          )
          |> reconcile_missing_running_issue_ids(running_ids, issues)

        {:error, reason} ->
          Logger.debug("Failed to refresh running issue states: #{inspect(reason)}; keeping active workers")

          state
      end
    end
  end

  @doc false
  @spec reconcile_issue_states_for_test([Issue.t()], term()) :: term()
  def reconcile_issue_states_for_test(issues, %State{} = state) when is_list(issues) do
    reconcile_running_issue_states(issues, state, active_state_set(), terminal_state_set())
  end

  def reconcile_issue_states_for_test(issues, state) when is_list(issues) do
    reconcile_running_issue_states(issues, state, active_state_set(), terminal_state_set())
  end

  @doc false
  @spec should_dispatch_issue_for_test(Issue.t(), term()) :: boolean()
  def should_dispatch_issue_for_test(%Issue{} = issue, %State{} = state) do
    should_dispatch_issue?(issue, state, active_state_set(), terminal_state_set())
  end

  @doc false
  @spec revalidate_issue_for_dispatch_for_test(Issue.t(), ([String.t()] -> term())) ::
          {:ok, Issue.t()} | {:skip, Issue.t() | :missing} | {:error, term()}
  def revalidate_issue_for_dispatch_for_test(%Issue{} = issue, issue_fetcher)
      when is_function(issue_fetcher, 1) do
    revalidate_issue_for_dispatch(issue, issue_fetcher, active_state_set(), terminal_state_set())
  end

  @doc false
  @spec sort_issues_for_dispatch_for_test([Issue.t()]) :: [Issue.t()]
  def sort_issues_for_dispatch_for_test(issues) when is_list(issues) do
    sort_issues_for_dispatch(issues)
  end

  defp reconcile_running_issue_states([], state, _active_states, _terminal_states), do: state

  defp reconcile_running_issue_states([issue | rest], state, active_states, terminal_states) do
    reconcile_running_issue_states(
      rest,
      reconcile_issue_state(issue, state, active_states, terminal_states),
      active_states,
      terminal_states
    )
  end

  defp reconcile_issue_state(%Issue{} = issue, state, active_states, terminal_states) do
    case Reconcile.issue_action(issue, active_states, terminal_states) do
      {:terminate, true, :terminal_state} ->
        Logger.info("Issue moved to terminal state: #{issue_context(issue)} state=#{issue.state}; stopping active agent")
        terminate_running_issue(state, issue.id, true)

      {:terminate, false, :unroutable} ->
        Logger.info("Issue no longer routed to this worker: #{issue_context(issue)} assignee=#{inspect(issue.assignee_id)}; stopping active agent")
        terminate_running_issue(state, issue.id, false)

      :refresh ->
        refresh_running_issue_state(state, issue)

      {:terminate, false, :inactive_state} ->
        Logger.info("Issue moved to non-active state: #{issue_context(issue)} state=#{issue.state}; stopping active agent")
        terminate_running_issue(state, issue.id, false)

      :ignore ->
        state
    end
  end

  defp reconcile_issue_state(_issue, state, _active_states, _terminal_states), do: state

  defp reconcile_missing_running_issue_ids(%State{} = state, requested_issue_ids, issues)
       when is_list(requested_issue_ids) and is_list(issues) do
    Enum.reduce(Reconcile.missing_issue_ids(requested_issue_ids, issues), state, fn issue_id, state_acc ->
      log_missing_running_issue(state_acc, issue_id)
      terminate_running_issue(state_acc, issue_id, false)
    end)
  end

  defp reconcile_missing_running_issue_ids(state, _requested_issue_ids, _issues), do: state

  defp log_missing_running_issue(%State{} = state, issue_id) when is_binary(issue_id) do
    case Map.get(state.running, issue_id) do
      %{identifier: identifier} ->
        Logger.info("Issue no longer visible during running-state refresh: issue_id=#{issue_id} issue_identifier=#{identifier}; stopping active agent")

      _ ->
        Logger.info("Issue no longer visible during running-state refresh: issue_id=#{issue_id}; stopping active agent")
    end
  end

  defp log_missing_running_issue(_state, _issue_id), do: :ok

  defp refresh_running_issue_state(%State{} = state, %Issue{} = issue) do
    case Map.get(state.running, issue.id) do
      %{issue: _} = running_entry ->
        %{state | running: Map.put(state.running, issue.id, %{running_entry | issue: issue})}

      _ ->
        state
    end
  end

  defp terminate_running_issue(%State{} = state, issue_id, cleanup_workspace) do
    case Map.get(state.running, issue_id) do
      nil ->
        release_issue_claim(state, issue_id)

      %{pid: pid, ref: ref, identifier: identifier} = running_entry ->
        state = record_session_completion_totals(state, running_entry)
        _ = Execution.cancel(running_entry)

        if is_pid(pid) do
          terminate_task(pid)
        end

        if is_reference(ref) do
          Process.demonitor(ref, [:flush])
        end

        if cleanup_workspace do
          cleanup_issue_workspace(identifier, running_entry)
        end

        %{
          state
          | running: Map.delete(state.running, issue_id),
            claimed: MapSet.delete(state.claimed, issue_id),
            retry_attempts: Map.delete(state.retry_attempts, issue_id)
        }

      _ ->
        release_issue_claim(state, issue_id)
    end
  end

  defp reconcile_stalled_running_issues(%State{} = state) do
    timeout_ms = Config.codex_stall_timeout_ms()

    cond do
      timeout_ms <= 0 ->
        state

      map_size(state.running) == 0 ->
        state

      true ->
        now = DateTime.utc_now()

        Enum.reduce(state.running, state, fn {issue_id, running_entry}, state_acc ->
          reconcile_stalled_running_issue(state_acc, issue_id, running_entry, now, timeout_ms)
        end)
    end
  end

  defp reconcile_stalled_running_issue(state, issue_id, running_entry, now, timeout_ms) do
    case Execution.skip_stall_detection?(running_entry) do
      true -> state
      false -> restart_stalled_issue(state, issue_id, running_entry, now, timeout_ms)
    end
  end

  defp restart_stalled_issue(state, issue_id, running_entry, now, timeout_ms) do
    elapsed_ms = Reconcile.stall_elapsed_ms(running_entry, now)

    if is_integer(elapsed_ms) and elapsed_ms > timeout_ms do
      identifier = Map.get(running_entry, :identifier, issue_id)
      session_id = running_entry_session_id(running_entry)

      Logger.warning("Issue stalled: issue_id=#{issue_id} issue_identifier=#{identifier} session_id=#{session_id} elapsed_ms=#{elapsed_ms}; restarting with backoff")

      next_attempt = next_retry_attempt_from_running(running_entry)

      retry_metadata =
        %{
          identifier: identifier,
          error: "stalled for #{elapsed_ms}ms without codex activity"
        }
        |> merge_retry_health_metadata(running_entry)
        |> maybe_put_failure_code("worker_stalled")

      state
      |> terminate_running_issue(issue_id, false)
      |> schedule_issue_retry(issue_id, next_attempt, retry_metadata)
    else
      state
    end
  end

  defp terminate_task(pid) when is_pid(pid) do
    case Task.Supervisor.terminate_child(SymphonyElixir.TaskSupervisor, pid) do
      :ok ->
        :ok

      {:error, :not_found} ->
        Process.exit(pid, :shutdown)
    end
  end

  defp terminate_task(_pid), do: :ok

  defp choose_issues(issues, state) do
    active_states = active_state_set()
    terminal_states = terminal_state_set()

    issues
    |> sort_issues_for_dispatch()
    |> Enum.reduce(state, fn issue, state_acc ->
      if should_dispatch_issue?(issue, state_acc, active_states, terminal_states) do
        dispatch_issue(state_acc, issue)
      else
        state_acc
      end
    end)
  end

  defp sort_issues_for_dispatch(issues) when is_list(issues), do: Dispatch.sort_issues(issues)

  defp should_dispatch_issue?(%Issue{} = issue, %State{} = state, active_states, terminal_states) do
    Dispatch.should_dispatch?(issue, state, active_states, terminal_states,
      available_slots: available_slots(state),
      state_limit_fun: &Config.max_concurrent_agents_for_state/1
    )
  end

  defp should_dispatch_issue?(_issue, _state, _active_states, _terminal_states), do: false

  defp terminal_issue_state?(state_name, terminal_states),
    do: Dispatch.terminal_issue_state?(state_name, terminal_states)

  defp terminal_state_set, do: Dispatch.terminal_state_set(Config.tracker_terminal_states())

  defp active_state_set, do: Dispatch.active_state_set(Config.tracker_active_states())

  defp dispatch_issue(%State{} = state, issue, attempt \\ nil) do
    case revalidate_issue_for_dispatch(
           issue,
           &Tracker.fetch_issue_states_by_ids/1,
           active_state_set(),
           terminal_state_set()
         ) do
      {:ok, %Issue{} = refreshed_issue} ->
        do_dispatch_issue(state, refreshed_issue, attempt)

      {:skip, :missing} ->
        Logger.info("Skipping dispatch; issue no longer active or visible: #{issue_context(issue)}")
        state

      {:skip, %Issue{} = refreshed_issue} ->
        Logger.info("Skipping stale dispatch after issue refresh: #{issue_context(refreshed_issue)} state=#{inspect(refreshed_issue.state)} blocked_by=#{length(refreshed_issue.blocked_by)}")

        state

      {:error, reason} ->
        Logger.warning("Skipping dispatch; issue refresh failed for #{issue_context(issue)}: #{inspect(reason)}")
        state
    end
  end

  defp do_dispatch_issue(%State{} = state, issue, attempt) do
    recipient = self()

    case Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
           AgentRunner.run(issue, recipient, attempt: attempt)
         end) do
      {:ok, pid} ->
        ref = Process.monitor(pid)

        Logger.info("Dispatching issue to agent: #{issue_context(issue)} pid=#{inspect(pid)} attempt=#{inspect(attempt)}")

        running =
          Map.put(state.running, issue.id, %{
            pid: pid,
            ref: ref,
            identifier: issue.identifier,
            issue: issue,
            session_id: nil,
            execution_backend: Config.execution_kind(),
            workflow_id: nil,
            workflow_run_id: nil,
            workflow_mode: nil,
            current_phase: nil,
            phases: nil,
            project_id: nil,
            workspace_path: Execution.workspace_path(issue.identifier || issue.id || "issue"),
            artifact_dir: nil,
            job_name: nil,
            last_execution_status: nil,
            last_successful_status_poll_at: nil,
            last_known_org_sync_result: nil,
            failure_code: nil,
            last_codex_message: nil,
            last_codex_timestamp: nil,
            last_codex_event: nil,
            codex_app_server_pid: nil,
            codex_input_tokens: 0,
            codex_output_tokens: 0,
            codex_total_tokens: 0,
            codex_last_reported_input_tokens: 0,
            codex_last_reported_output_tokens: 0,
            codex_last_reported_total_tokens: 0,
            turn_count: 0,
            retry_attempt: normalize_retry_attempt(attempt),
            started_at: DateTime.utc_now()
          })

        %{
          state
          | running: running,
            claimed: MapSet.put(state.claimed, issue.id),
            retry_attempts: Map.delete(state.retry_attempts, issue.id)
        }

      {:error, reason} ->
        Logger.error("Unable to spawn agent for #{issue_context(issue)}: #{inspect(reason)}")
        next_attempt = if is_integer(attempt), do: attempt + 1, else: nil

        schedule_issue_retry(state, issue.id, next_attempt, %{
          identifier: issue.identifier,
          error: "failed to spawn agent: #{inspect(reason)}"
        })
    end
  end

  defp revalidate_issue_for_dispatch(issue, issue_fetcher, active_states, terminal_states),
    do: Dispatch.revalidate_issue_for_dispatch(issue, issue_fetcher, active_states, terminal_states)

  defp complete_issue(%State{} = state, issue_id) do
    %{
      state
      | completed: MapSet.put(state.completed, issue_id),
        retry_attempts: Map.delete(state.retry_attempts, issue_id)
    }
  end

  defp schedule_issue_retry(%State{} = state, issue_id, attempt, metadata)
       when is_binary(issue_id) and is_map(metadata) do
    previous_retry = Map.get(state.retry_attempts, issue_id, %{attempt: 0})
    next_attempt = if is_integer(attempt), do: attempt, else: previous_retry.attempt + 1
    delay_ms = retry_delay(next_attempt, metadata)
    old_timer = Map.get(previous_retry, :timer_ref)
    retry_token = make_ref()
    due_at_ms = System.monotonic_time(:millisecond) + delay_ms
    identifier = pick_retry_identifier(issue_id, previous_retry, metadata)
    error = pick_retry_error(previous_retry, metadata)

    if is_reference(old_timer) do
      Process.cancel_timer(old_timer)
    end

    timer_ref = Process.send_after(self(), {:retry_issue, issue_id, retry_token}, delay_ms)

    error_suffix = if is_binary(error), do: " error=#{error}", else: ""

    Logger.warning("Retrying issue_id=#{issue_id} issue_identifier=#{identifier} in #{delay_ms}ms (attempt #{next_attempt})#{error_suffix}")

    retry_entry =
      metadata
      |> Map.drop([:attempt, :timer_ref, :retry_token, :due_at_ms])
      |> Map.put(:identifier, identifier)
      |> Map.put(:error, error)
      |> Map.merge(%{
        attempt: next_attempt,
        timer_ref: timer_ref,
        retry_token: retry_token,
        due_at_ms: due_at_ms
      })

    %{
      state
      | retry_attempts: Map.put(state.retry_attempts, issue_id, retry_entry)
    }
  end

  defp pop_retry_attempt_state(%State{} = state, issue_id, retry_token) when is_reference(retry_token) do
    case Map.get(state.retry_attempts, issue_id) do
      %{attempt: attempt, retry_token: ^retry_token} = retry_entry ->
        metadata = Map.drop(retry_entry, [:attempt, :timer_ref, :retry_token, :due_at_ms])

        {:ok, attempt, metadata, %{state | retry_attempts: Map.delete(state.retry_attempts, issue_id)}}

      _ ->
        :missing
    end
  end

  defp handle_retry_issue(%State{} = state, issue_id, attempt, metadata) do
    case Tracker.fetch_candidate_issues() do
      {:ok, issues} ->
        issues
        |> find_issue_by_id(issue_id)
        |> handle_retry_issue_lookup(state, issue_id, attempt, metadata)

      {:error, reason} ->
        Logger.warning("Retry poll failed for issue_id=#{issue_id} issue_identifier=#{metadata[:identifier] || issue_id}: #{inspect(reason)}")

        {:noreply,
         schedule_issue_retry(
           state,
           issue_id,
           attempt + 1,
           Map.merge(metadata, %{error: "retry poll failed: #{inspect(reason)}"})
         )}
    end
  end

  defp handle_retry_issue_lookup(%Issue{} = issue, state, issue_id, attempt, metadata) do
    terminal_states = terminal_state_set()

    cond do
      terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Issue state is terminal: issue_id=#{issue_id} issue_identifier=#{issue.identifier} state=#{issue.state}; removing associated workspace")

        cleanup_issue_workspace(issue.identifier, nil)
        {:noreply, release_issue_claim(state, issue_id)}

      retry_candidate_issue?(issue, terminal_states) ->
        handle_active_retry(state, issue, attempt, metadata)

      true ->
        Logger.debug("Issue left active states, removing claim issue_id=#{issue_id} issue_identifier=#{issue.identifier}")

        {:noreply, release_issue_claim(state, issue_id)}
    end
  end

  defp handle_retry_issue_lookup(nil, state, issue_id, _attempt, _metadata) do
    Logger.debug("Issue no longer visible, removing claim issue_id=#{issue_id}")
    {:noreply, release_issue_claim(state, issue_id)}
  end

  defp cleanup_issue_workspace(identifier, running_entry)

  defp cleanup_issue_workspace(identifier, running_entry) when is_binary(identifier) do
    Execution.cleanup_issue_workspace(identifier, running_entry)
  end

  defp cleanup_issue_workspace(_identifier, _running_entry), do: :ok

  defp run_terminal_workspace_cleanup do
    case Tracker.fetch_issues_by_states(Config.tracker_terminal_states()) do
      {:ok, issues} ->
        issues
        |> Enum.each(fn
          %Issue{identifier: identifier} when is_binary(identifier) ->
            cleanup_issue_workspace(identifier, nil)

          _ ->
            :ok
        end)

      {:error, reason} ->
        Logger.warning("Skipping startup terminal workspace cleanup; failed to fetch terminal issues: #{inspect(reason)}")
    end
  end

  defp notify_dashboard do
    StatusDashboard.notify_update()
  end

  defp handle_active_retry(state, issue, attempt, metadata) do
    if retry_candidate_issue?(issue, terminal_state_set()) and
         dispatch_slots_available?(issue, state) do
      {:noreply, dispatch_issue(state, issue, attempt)}
    else
      Logger.debug("No available slots for retrying #{issue_context(issue)}; retrying again")

      {:noreply,
       schedule_issue_retry(
         state,
         issue.id,
         attempt + 1,
         Map.merge(metadata, %{
           identifier: issue.identifier,
           error: "no available orchestrator slots"
         })
       )}
    end
  end

  defp release_issue_claim(%State{} = state, issue_id) do
    %{state | claimed: MapSet.delete(state.claimed, issue_id)}
  end

  defp retry_delay(attempt, metadata) when is_integer(attempt) and attempt > 0 and is_map(metadata) do
    if metadata[:delay_type] == :continuation and attempt == 1 do
      @continuation_retry_delay_ms
    else
      failure_retry_delay(attempt)
    end
  end

  defp failure_retry_delay(attempt) do
    max_delay_power = min(attempt - 1, 10)
    min(@failure_retry_base_ms * (1 <<< max_delay_power), Config.max_retry_backoff_ms())
  end

  defp normalize_retry_attempt(attempt) when is_integer(attempt) and attempt > 0, do: attempt
  defp normalize_retry_attempt(_attempt), do: 0

  defp next_retry_attempt_from_running(running_entry) do
    case Map.get(running_entry, :retry_attempt) do
      attempt when is_integer(attempt) and attempt > 0 -> attempt + 1
      _ -> 1
    end
  end

  defp pick_retry_identifier(issue_id, previous_retry, metadata) do
    metadata[:identifier] || Map.get(previous_retry, :identifier) || issue_id
  end

  defp pick_retry_error(previous_retry, metadata) do
    metadata[:error] || Map.get(previous_retry, :error)
  end

  defp find_issue_by_id(issues, issue_id) when is_binary(issue_id) do
    Enum.find(issues, fn
      %Issue{id: ^issue_id} ->
        true

      _ ->
        false
    end)
  end

  defp find_issue_id_for_ref(running, ref) do
    running
    |> Enum.find_value(fn {issue_id, %{ref: running_ref}} ->
      if running_ref == ref, do: issue_id
    end)
  end

  defp running_entry_session_id(%{session_id: session_id}) when is_binary(session_id),
    do: session_id

  defp running_entry_session_id(_running_entry), do: "n/a"

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp available_slots(%State{} = state) do
    max(
      (state.max_concurrent_agents || Config.max_concurrent_agents()) - map_size(state.running),
      0
    )
  end

  @spec request_refresh() :: map() | :unavailable
  def request_refresh do
    request_refresh(__MODULE__)
  end

  @spec request_refresh(GenServer.server()) :: map() | :unavailable
  def request_refresh(server) do
    if Process.whereis(server) do
      GenServer.call(server, :request_refresh)
    else
      :unavailable
    end
  end

  @spec snapshot() :: map() | :timeout | :unavailable
  def snapshot, do: snapshot(__MODULE__, 15_000)

  @spec snapshot(GenServer.server(), timeout()) :: map() | :timeout | :unavailable
  def snapshot(server, timeout) do
    if Process.whereis(server) do
      try do
        GenServer.call(server, :snapshot, timeout)
      catch
        :exit, {:timeout, _} -> :timeout
        :exit, _ -> :unavailable
      end
    else
      :unavailable
    end
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    state = refresh_runtime_config(state)
    now = DateTime.utc_now()
    now_ms = System.monotonic_time(:millisecond)

    running =
      state.running
      |> Enum.map(fn {issue_id, metadata} ->
        %{
          issue_id: issue_id,
          identifier: metadata.identifier,
          state: metadata.issue.state,
          session_id: metadata.session_id,
          execution_backend: Map.get(metadata, :execution_backend),
          workflow_id: Map.get(metadata, :workflow_id),
          workflow_run_id: Map.get(metadata, :workflow_run_id),
          workflow_mode: Map.get(metadata, :workflow_mode),
          current_phase: Map.get(metadata, :current_phase),
          phases: Map.get(metadata, :phases),
          project_id: Map.get(metadata, :project_id),
          workspace_path: Map.get(metadata, :workspace_path),
          artifact_dir: Map.get(metadata, :artifact_dir),
          job_name: Map.get(metadata, :job_name),
          last_execution_status: Map.get(metadata, :last_execution_status),
          last_successful_status_poll_at: Map.get(metadata, :last_successful_status_poll_at),
          last_known_org_sync_result: Map.get(metadata, :last_known_org_sync_result),
          failure_code: Map.get(metadata, :failure_code),
          codex_app_server_pid: metadata.codex_app_server_pid,
          codex_input_tokens: metadata.codex_input_tokens,
          codex_output_tokens: metadata.codex_output_tokens,
          codex_total_tokens: metadata.codex_total_tokens,
          turn_count: Map.get(metadata, :turn_count, 0),
          started_at: metadata.started_at,
          last_codex_timestamp: metadata.last_codex_timestamp,
          last_codex_message: metadata.last_codex_message,
          last_codex_event: metadata.last_codex_event,
          runtime_seconds: running_seconds(metadata.started_at, now)
        }
      end)

    retrying =
      state.retry_attempts
      |> Enum.map(fn {issue_id, %{attempt: attempt, due_at_ms: due_at_ms} = retry} ->
        %{
          issue_id: issue_id,
          attempt: attempt,
          due_in_ms: max(0, due_at_ms - now_ms),
          identifier: Map.get(retry, :identifier),
          error: Map.get(retry, :error),
          execution_backend: Map.get(retry, :execution_backend),
          workflow_id: Map.get(retry, :workflow_id),
          workflow_run_id: Map.get(retry, :workflow_run_id),
          project_id: Map.get(retry, :project_id),
          workspace_path: Map.get(retry, :workspace_path),
          artifact_dir: Map.get(retry, :artifact_dir),
          job_name: Map.get(retry, :job_name),
          last_execution_status: Map.get(retry, :last_execution_status),
          last_successful_status_poll_at: Map.get(retry, :last_successful_status_poll_at),
          last_known_org_sync_result: Map.get(retry, :last_known_org_sync_result),
          failure_code: Map.get(retry, :failure_code)
        }
      end)

    {:reply,
     %{
       running: running,
       retrying: retrying,
       codex_totals: state.codex_totals,
       runtime: state.runtime_status,
       rate_limits: Map.get(state, :codex_rate_limits),
       polling: %{
         checking?: state.poll_check_in_progress == true,
         next_poll_in_ms: next_poll_in_ms(state.next_poll_due_at_ms, now_ms),
         poll_interval_ms: state.poll_interval_ms
       }
     }, state}
  end

  def handle_call(:request_refresh, _from, state) do
    now_ms = System.monotonic_time(:millisecond)
    already_due? = is_integer(state.next_poll_due_at_ms) and state.next_poll_due_at_ms <= now_ms
    coalesced = state.poll_check_in_progress == true or already_due?
    state = if coalesced, do: state, else: schedule_tick(state, 0)

    {:reply,
     %{
       queued: true,
       coalesced: coalesced,
       requested_at: DateTime.utc_now(),
       operations: ["poll", "reconcile"]
     }, state}
  end

  defp integrate_codex_update(running_entry, %{event: event, timestamp: timestamp} = update) do
    token_delta = extract_token_delta(running_entry, update)
    codex_input_tokens = Map.get(running_entry, :codex_input_tokens, 0)
    codex_output_tokens = Map.get(running_entry, :codex_output_tokens, 0)
    codex_total_tokens = Map.get(running_entry, :codex_total_tokens, 0)
    codex_app_server_pid = Map.get(running_entry, :codex_app_server_pid)
    last_reported_input = Map.get(running_entry, :codex_last_reported_input_tokens, 0)
    last_reported_output = Map.get(running_entry, :codex_last_reported_output_tokens, 0)
    last_reported_total = Map.get(running_entry, :codex_last_reported_total_tokens, 0)
    turn_count = Map.get(running_entry, :turn_count, 0)

    {
      Map.merge(running_entry, %{
        last_codex_timestamp: timestamp,
        last_codex_message: summarize_codex_update(update),
        session_id: session_id_for_update(running_entry.session_id, update),
        last_codex_event: event,
        execution_backend: execution_backend_for_update(Map.get(running_entry, :execution_backend), update),
        workflow_id: workflow_id_for_update(Map.get(running_entry, :workflow_id), update),
        workflow_run_id: workflow_run_id_for_update(Map.get(running_entry, :workflow_run_id), update),
        workflow_mode: workflow_mode_for_update(Map.get(running_entry, :workflow_mode), update),
        current_phase: current_phase_for_update(Map.get(running_entry, :current_phase), update),
        phases: phases_for_update(Map.get(running_entry, :phases), update),
        project_id: project_id_for_update(Map.get(running_entry, :project_id), update),
        workspace_path: workspace_path_for_update(Map.get(running_entry, :workspace_path), update),
        artifact_dir: artifact_dir_for_update(Map.get(running_entry, :artifact_dir), update),
        job_name: job_name_for_update(Map.get(running_entry, :job_name), update),
        last_execution_status: execution_status_for_update(Map.get(running_entry, :last_execution_status), update),
        last_successful_status_poll_at:
          last_successful_status_poll_at_for_update(
            Map.get(running_entry, :last_successful_status_poll_at),
            update
          ),
        last_known_org_sync_result:
          last_known_org_sync_result_for_update(
            Map.get(running_entry, :last_known_org_sync_result),
            update
          ),
        failure_code: failure_code_for_update(Map.get(running_entry, :failure_code), update),
        codex_app_server_pid: codex_app_server_pid_for_update(codex_app_server_pid, update),
        codex_input_tokens: codex_input_tokens + token_delta.input_tokens,
        codex_output_tokens: codex_output_tokens + token_delta.output_tokens,
        codex_total_tokens: codex_total_tokens + token_delta.total_tokens,
        codex_last_reported_input_tokens: max(last_reported_input, token_delta.input_reported),
        codex_last_reported_output_tokens: max(last_reported_output, token_delta.output_reported),
        codex_last_reported_total_tokens: max(last_reported_total, token_delta.total_reported),
        turn_count: turn_count_for_update(turn_count, running_entry.session_id, update)
      }),
      token_delta
    }
  end

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid})
       when is_binary(pid),
       do: pid

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid})
       when is_integer(pid),
       do: Integer.to_string(pid)

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid}) when is_list(pid),
    do: to_string(pid)

  defp codex_app_server_pid_for_update(existing, _update), do: existing

  defp execution_backend_for_update(_existing, %{execution_backend: backend}) when is_binary(backend),
    do: backend

  defp execution_backend_for_update(existing, _update), do: existing

  defp workflow_id_for_update(_existing, %{workflow_id: workflow_id}) when is_binary(workflow_id),
    do: workflow_id

  defp workflow_id_for_update(existing, _update), do: existing

  defp workflow_run_id_for_update(_existing, %{workflow_run_id: workflow_run_id})
       when is_binary(workflow_run_id),
       do: workflow_run_id

  defp workflow_run_id_for_update(existing, _update), do: existing

  defp workflow_mode_for_update(_existing, %{workflow_mode: workflow_mode})
       when is_binary(workflow_mode),
       do: workflow_mode

  defp workflow_mode_for_update(existing, %{payload: %{params: params}}) when is_map(params) do
    case Map.get(params, "workflow_mode") || Map.get(params, "workflowMode") do
      workflow_mode when is_binary(workflow_mode) -> workflow_mode
      _ -> existing
    end
  end

  defp workflow_mode_for_update(existing, _update), do: existing

  defp current_phase_for_update(_existing, %{current_phase: current_phase})
       when is_binary(current_phase),
       do: current_phase

  defp current_phase_for_update(existing, %{payload: %{params: params}}) when is_map(params) do
    case Map.get(params, "current_phase") || Map.get(params, "currentPhase") do
      current_phase when is_binary(current_phase) -> current_phase
      _ -> existing
    end
  end

  defp current_phase_for_update(existing, _update), do: existing

  defp phases_for_update(_existing, %{phases: phases}) when is_list(phases), do: phases

  defp phases_for_update(existing, %{payload: %{params: params}}) when is_map(params) do
    case Map.get(params, "phases") do
      phases when is_list(phases) -> phases
      _ -> existing
    end
  end

  defp phases_for_update(existing, _update), do: existing

  defp project_id_for_update(_existing, %{project_id: project_id}) when is_binary(project_id),
    do: project_id

  defp project_id_for_update(existing, _update), do: existing

  defp workspace_path_for_update(_existing, %{workspace_path: workspace_path})
       when is_binary(workspace_path),
       do: workspace_path

  defp workspace_path_for_update(existing, _update), do: existing

  defp artifact_dir_for_update(_existing, %{artifact_dir: artifact_dir}) when is_binary(artifact_dir),
    do: artifact_dir

  defp artifact_dir_for_update(existing, _update), do: existing

  defp job_name_for_update(_existing, %{job_name: job_name}) when is_binary(job_name), do: job_name
  defp job_name_for_update(existing, _update), do: existing

  defp execution_status_for_update(_existing, %{payload: %{params: %{"status" => status}}})
       when is_binary(status),
       do: status

  defp execution_status_for_update(existing, _update), do: existing

  defp last_successful_status_poll_at_for_update(
         existing,
         %{timestamp: %DateTime{} = timestamp} = update
       ) do
    if payload_method(update) == "temporal/status", do: timestamp, else: existing
  end

  defp last_successful_status_poll_at_for_update(existing, _update), do: existing

  defp last_known_org_sync_result_for_update(
         _existing,
         %{last_known_org_sync_result: %{} = org_sync_result}
       ),
       do: org_sync_result

  defp last_known_org_sync_result_for_update(existing, _update), do: existing

  defp failure_code_for_update(_existing, %{failure_code: failure_code})
       when is_binary(failure_code),
       do: failure_code

  defp failure_code_for_update(existing, _update), do: existing

  defp session_id_for_update(_existing, %{session_id: session_id}) when is_binary(session_id),
    do: session_id

  defp session_id_for_update(existing, _update), do: existing

  defp turn_count_for_update(existing_count, existing_session_id, %{
         event: :session_started,
         session_id: session_id
       })
       when is_integer(existing_count) and is_binary(session_id) do
    if session_id == existing_session_id do
      existing_count
    else
      existing_count + 1
    end
  end

  defp turn_count_for_update(existing_count, _existing_session_id, _update)
       when is_integer(existing_count),
       do: existing_count

  defp turn_count_for_update(_existing_count, _existing_session_id, _update), do: 0

  defp summarize_codex_update(update) do
    %{
      event: update[:event],
      message: update[:payload] || update[:raw],
      timestamp: update[:timestamp]
    }
  end

  defp payload_method(%{payload: %{method: method}}) when is_binary(method), do: method
  defp payload_method(%{payload: %{"method" => method}}) when is_binary(method), do: method
  defp payload_method(_update), do: nil

  defp merge_retry_health_metadata(metadata, running_entry)
       when is_map(metadata) and is_map(running_entry) do
    Enum.reduce(@retry_health_metadata_fields, metadata, fn key, acc ->
      case Map.get(running_entry, key) do
        nil -> acc
        value -> Map.put(acc, key, value)
      end
    end)
  end

  defp merge_retry_health_metadata(metadata, _running_entry), do: metadata

  defp maybe_put_failure_code(metadata, nil), do: metadata
  defp maybe_put_failure_code(metadata, failure_code), do: Map.put(metadata, :failure_code, failure_code)

  defp maybe_put_last_known_org_sync_result(metadata, nil), do: metadata

  defp maybe_put_last_known_org_sync_result(metadata, org_sync_result),
    do: Map.put(metadata, :last_known_org_sync_result, org_sync_result)

  defp failure_code_from_reason(reason) do
    reason
    |> failure_message_from_reason()
    |> failure_code_from_failure_message()
  end

  defp org_sync_result_from_reason(reason) do
    reason
    |> failure_message_from_reason()
    |> org_sync_result_from_failure_message()
  end

  defp failure_message_from_reason({{%RuntimeError{message: message}, _stacktrace}, _})
       when is_binary(message),
       do: message

  defp failure_message_from_reason({%RuntimeError{message: message}, _stacktrace})
       when is_binary(message),
       do: message

  defp failure_message_from_reason(%RuntimeError{message: message}) when is_binary(message),
    do: message

  defp failure_message_from_reason(message) when is_binary(message), do: message
  defp failure_message_from_reason(reason), do: inspect(reason)

  defp failure_code_from_failure_message(message) when is_binary(message) do
    [
      {"Temporal/K3s status checks stalled", "temporal_status_timeout"},
      {"Temporal/K3s failed to sync Org workpad", "org_workpad_sync_failed"},
      {"Temporal/K3s failed to sync Org state=", "org_state_sync_failed"},
      {"Temporal/K3s run ended without a valid target state", "invalid_run_result_target_state"},
      {"Temporal/K3s workflow ended with status=failed", "temporal_workflow_failed"},
      {"Temporal/K3s workflow ended with status=cancelled", "temporal_workflow_cancelled"},
      {"Temporal/K3s run failed", "temporal_run_failed"},
      {"stalled for ", "worker_stalled"}
    ]
    |> Enum.find_value(fn {pattern, failure_code} ->
      if String.contains?(message, pattern), do: failure_code
    end)
  end

  defp org_sync_result_from_failure_message(message) when is_binary(message) do
    if String.contains?(message, "Temporal/K3s failed to sync Org workpad") do
      %{step: "workpad", status: "error"}
    else
      case Regex.named_captures(
             ~r/Temporal\/K3s failed to sync Org state=(?<target_state>[^ ]+) for /,
             message
           ) do
        %{"target_state" => target_state} ->
          %{step: "state", status: "error", target_state: target_state}

        _ ->
          nil
      end
    end
  end

  defp schedule_tick(%State{} = state, delay_ms) when is_integer(delay_ms) and delay_ms >= 0 do
    if is_reference(state.tick_timer_ref) do
      Process.cancel_timer(state.tick_timer_ref)
    end

    tick_token = make_ref()
    timer_ref = Process.send_after(self(), {:tick, tick_token}, delay_ms)

    %{
      state
      | tick_timer_ref: timer_ref,
        tick_token: tick_token,
        next_poll_due_at_ms: System.monotonic_time(:millisecond) + delay_ms
    }
  end

  defp schedule_poll_cycle_start do
    :timer.send_after(@poll_transition_render_delay_ms, self(), :run_poll_cycle)
    :ok
  end

  defp next_poll_in_ms(nil, _now_ms), do: nil

  defp next_poll_in_ms(next_poll_due_at_ms, now_ms) when is_integer(next_poll_due_at_ms) do
    max(0, next_poll_due_at_ms - now_ms)
  end

  defp pop_running_entry(state, issue_id) do
    {Map.get(state.running, issue_id), %{state | running: Map.delete(state.running, issue_id)}}
  end

  defp record_session_completion_totals(state, running_entry) when is_map(running_entry) do
    runtime_seconds = running_seconds(running_entry.started_at, DateTime.utc_now())

    codex_totals =
      apply_token_delta(
        state.codex_totals,
        %{
          input_tokens: 0,
          output_tokens: 0,
          total_tokens: 0,
          seconds_running: runtime_seconds
        }
      )

    %{state | codex_totals: codex_totals}
  end

  defp record_session_completion_totals(state, _running_entry), do: state

  defp refresh_runtime_config(%State{} = state) do
    %{
      state
      | poll_interval_ms: Config.poll_interval_ms(),
        max_concurrent_agents: Config.max_concurrent_agents()
    }
  end

  defp refresh_execution_runtime_status(%State{} = state) do
    runtime_status = Execution.runtime_status()
    log_runtime_status_transition(Map.get(state, :runtime_status), runtime_status)
    %{state | runtime_status: runtime_status}
  end

  defp runtime_ready?(%{ready: true}), do: true
  defp runtime_ready?(_runtime_status), do: false

  defp log_runtime_status_transition(previous, %{execution_backend: "temporal_k3s", ready: true} = current) do
    if runtime_status_signature(previous) != runtime_status_signature(current) do
      Logger.info("Temporal/K3s runtime ready for dispatch")
    end
  end

  defp log_runtime_status_transition(previous, %{execution_backend: "temporal_k3s", ready: false, blockers: blockers} = current) do
    if runtime_status_signature(previous) != runtime_status_signature(current) do
      Enum.each(blockers, fn blocker ->
        Logger.error("Temporal/K3s runtime blocker #{runtime_blocker_code(blocker)}: #{runtime_blocker_message(blocker)}")
      end)
    end
  end

  defp log_runtime_status_transition(_previous, _current), do: :ok

  defp runtime_status_signature(%{execution_backend: backend, ready: ready, blockers: blockers}) do
    {backend, ready, Enum.map(blockers || [], &{runtime_blocker_code(&1), runtime_blocker_message(&1)})}
  end

  defp runtime_status_signature(_runtime_status), do: nil

  defp runtime_blocker_code(%{"code" => code}) when is_binary(code), do: code
  defp runtime_blocker_code(%{code: code}) when is_binary(code), do: code
  defp runtime_blocker_code(_blocker), do: "unknown"

  defp runtime_blocker_message(%{"message" => message}) when is_binary(message), do: message
  defp runtime_blocker_message(%{message: message}) when is_binary(message), do: message
  defp runtime_blocker_message(blocker), do: inspect(blocker)

  defp retry_candidate_issue?(%Issue{} = issue, terminal_states),
    do: Dispatch.retry_candidate_issue?(issue, active_state_set(), terminal_states)

  defp dispatch_slots_available?(%Issue{} = issue, %State{} = state),
    do:
      Dispatch.dispatch_slots_available?(issue, state,
        available_slots: available_slots(state),
        state_limit_fun: &Config.max_concurrent_agents_for_state/1
      )

  defp apply_codex_token_delta(
         %{codex_totals: codex_totals} = state,
         %{input_tokens: input, output_tokens: output, total_tokens: total} = token_delta
       )
       when is_integer(input) and is_integer(output) and is_integer(total) do
    %{state | codex_totals: apply_token_delta(codex_totals, token_delta)}
  end

  defp apply_codex_token_delta(state, _token_delta), do: state

  defp apply_codex_rate_limits(%State{} = state, update) when is_map(update) do
    case extract_rate_limits(update) do
      %{} = rate_limits ->
        %{state | codex_rate_limits: rate_limits}

      _ ->
        state
    end
  end

  defp apply_codex_rate_limits(state, _update), do: state

  defp apply_token_delta(codex_totals, token_delta) do
    input_tokens = Map.get(codex_totals, :input_tokens, 0) + token_delta.input_tokens
    output_tokens = Map.get(codex_totals, :output_tokens, 0) + token_delta.output_tokens
    total_tokens = Map.get(codex_totals, :total_tokens, 0) + token_delta.total_tokens

    seconds_running =
      Map.get(codex_totals, :seconds_running, 0) + Map.get(token_delta, :seconds_running, 0)

    %{
      input_tokens: max(0, input_tokens),
      output_tokens: max(0, output_tokens),
      total_tokens: max(0, total_tokens),
      seconds_running: max(0, seconds_running)
    }
  end

  defp extract_token_delta(running_entry, %{event: _, timestamp: _} = update) do
    running_entry = running_entry || %{}
    usage = extract_token_usage(update)

    {
      compute_token_delta(
        running_entry,
        :input,
        usage,
        :codex_last_reported_input_tokens
      ),
      compute_token_delta(
        running_entry,
        :output,
        usage,
        :codex_last_reported_output_tokens
      ),
      compute_token_delta(
        running_entry,
        :total,
        usage,
        :codex_last_reported_total_tokens
      )
    }
    |> Tuple.to_list()
    |> then(fn [input, output, total] ->
      %{
        input_tokens: input.delta,
        output_tokens: output.delta,
        total_tokens: total.delta,
        input_reported: input.reported,
        output_reported: output.reported,
        total_reported: total.reported
      }
    end)
  end

  defp compute_token_delta(running_entry, token_key, usage, reported_key) do
    next_total = get_token_usage(usage, token_key)
    prev_reported = Map.get(running_entry, reported_key, 0)

    delta =
      if is_integer(next_total) and next_total >= prev_reported do
        next_total - prev_reported
      else
        0
      end

    %{
      delta: max(delta, 0),
      reported: if(is_integer(next_total), do: next_total, else: prev_reported)
    }
  end

  defp extract_token_usage(update) do
    payloads = [
      update[:usage],
      Map.get(update, "usage"),
      Map.get(update, :usage),
      update[:payload],
      Map.get(update, "payload"),
      update
    ]

    Enum.find_value(payloads, &absolute_token_usage_from_payload/1) ||
      Enum.find_value(payloads, &turn_completed_usage_from_payload/1) ||
      %{}
  end

  defp extract_rate_limits(update) do
    rate_limits_from_payload(update[:rate_limits]) ||
      rate_limits_from_payload(Map.get(update, "rate_limits")) ||
      rate_limits_from_payload(Map.get(update, :rate_limits)) ||
      rate_limits_from_payload(update[:payload]) ||
      rate_limits_from_payload(Map.get(update, "payload")) ||
      rate_limits_from_payload(update)
  end

  defp absolute_token_usage_from_payload(payload) when is_map(payload) do
    absolute_paths = [
      ["params", "msg", "payload", "info", "total_token_usage"],
      [:params, :msg, :payload, :info, :total_token_usage],
      ["params", "msg", "info", "total_token_usage"],
      [:params, :msg, :info, :total_token_usage],
      ["params", "tokenUsage", "total"],
      [:params, :tokenUsage, :total],
      ["tokenUsage", "total"],
      [:tokenUsage, :total]
    ]

    explicit_map_at_paths(payload, absolute_paths)
  end

  defp absolute_token_usage_from_payload(_payload), do: nil

  defp turn_completed_usage_from_payload(payload) when is_map(payload) do
    method = Map.get(payload, "method") || Map.get(payload, :method)

    if method in ["turn/completed", :turn_completed] do
      direct =
        Map.get(payload, "usage") ||
          Map.get(payload, :usage) ||
          map_at_path(payload, ["params", "usage"]) ||
          map_at_path(payload, [:params, :usage])

      if is_map(direct) and integer_token_map?(direct), do: direct
    end
  end

  defp turn_completed_usage_from_payload(_payload), do: nil

  defp rate_limits_from_payload(payload) when is_map(payload) do
    direct = Map.get(payload, "rate_limits") || Map.get(payload, :rate_limits)

    cond do
      rate_limits_map?(direct) ->
        direct

      rate_limits_map?(payload) ->
        payload

      true ->
        rate_limit_payloads(payload)
    end
  end

  defp rate_limits_from_payload(payload) when is_list(payload) do
    rate_limit_payloads(payload)
  end

  defp rate_limits_from_payload(_payload), do: nil

  defp rate_limit_payloads(payload) when is_map(payload) do
    Map.values(payload)
    |> Enum.reduce_while(nil, fn
      value, nil ->
        case rate_limits_from_payload(value) do
          nil -> {:cont, nil}
          rate_limits -> {:halt, rate_limits}
        end

      _value, result ->
        {:halt, result}
    end)
  end

  defp rate_limit_payloads(payload) when is_list(payload) do
    payload
    |> Enum.reduce_while(nil, fn
      value, nil ->
        case rate_limits_from_payload(value) do
          nil -> {:cont, nil}
          rate_limits -> {:halt, rate_limits}
        end

      _value, result ->
        {:halt, result}
    end)
  end

  defp rate_limits_map?(payload) when is_map(payload) do
    limit_id =
      Map.get(payload, "limit_id") ||
        Map.get(payload, :limit_id) ||
        Map.get(payload, "limit_name") ||
        Map.get(payload, :limit_name)

    has_buckets =
      Enum.any?(
        ["primary", :primary, "secondary", :secondary, "credits", :credits],
        &Map.has_key?(payload, &1)
      )

    !is_nil(limit_id) and has_buckets
  end

  defp rate_limits_map?(_payload), do: false

  defp explicit_map_at_paths(payload, paths) when is_map(payload) and is_list(paths) do
    Enum.find_value(paths, fn path ->
      value = map_at_path(payload, path)

      if is_map(value) and integer_token_map?(value), do: value
    end)
  end

  defp explicit_map_at_paths(_payload, _paths), do: nil

  defp map_at_path(payload, path) when is_map(payload) and is_list(path) do
    Enum.reduce_while(path, payload, fn key, acc ->
      if is_map(acc) and Map.has_key?(acc, key) do
        {:cont, Map.get(acc, key)}
      else
        {:halt, nil}
      end
    end)
  end

  defp map_at_path(_payload, _path), do: nil

  defp integer_token_map?(payload) do
    token_fields = [
      :input_tokens,
      :output_tokens,
      :total_tokens,
      :prompt_tokens,
      :completion_tokens,
      :inputTokens,
      :outputTokens,
      :totalTokens,
      :promptTokens,
      :completionTokens,
      "input_tokens",
      "output_tokens",
      "total_tokens",
      "prompt_tokens",
      "completion_tokens",
      "inputTokens",
      "outputTokens",
      "totalTokens",
      "promptTokens",
      "completionTokens"
    ]

    token_fields
    |> Enum.any?(fn field ->
      value = payload_get(payload, field)
      !is_nil(integer_like(value))
    end)
  end

  defp get_token_usage(usage, :input),
    do:
      payload_get(usage, [
        "input_tokens",
        "prompt_tokens",
        :input_tokens,
        :prompt_tokens,
        :input,
        "promptTokens",
        :promptTokens,
        "inputTokens",
        :inputTokens
      ])

  defp get_token_usage(usage, :output),
    do:
      payload_get(usage, [
        "output_tokens",
        "completion_tokens",
        :output_tokens,
        :completion_tokens,
        :output,
        :completion,
        "outputTokens",
        :outputTokens,
        "completionTokens",
        :completionTokens
      ])

  defp get_token_usage(usage, :total),
    do:
      payload_get(usage, [
        "total_tokens",
        "total",
        :total_tokens,
        :total,
        "totalTokens",
        :totalTokens
      ])

  defp payload_get(payload, fields) when is_list(fields) do
    Enum.find_value(fields, fn field -> map_integer_value(payload, field) end)
  end

  defp payload_get(payload, field), do: map_integer_value(payload, field)

  defp map_integer_value(payload, field) do
    if is_map(payload) do
      value = Map.get(payload, field)
      integer_like(value)
    else
      nil
    end
  end

  defp running_seconds(%DateTime{} = started_at, %DateTime{} = now) do
    max(0, DateTime.diff(now, started_at, :second))
  end

  defp running_seconds(_started_at, _now), do: 0

  defp integer_like(value) when is_integer(value) and value >= 0, do: value

  defp integer_like(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {num, _} when num >= 0 -> num
      _ -> nil
    end
  end

  defp integer_like(_value), do: nil
end
