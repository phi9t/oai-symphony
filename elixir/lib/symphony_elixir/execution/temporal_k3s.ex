defmodule SymphonyElixir.Execution.TemporalK3s do
  @moduledoc """
  Remote execution backend that runs agent work through Temporal and K3s.
  """

  require Logger

  alias SymphonyElixir.{Config, PromptBuilder, TemporalCli, Tracker, Workspace}
  alias SymphonyElixir.Org.Adapter
  alias SymphonyElixir.Tracker.Issue

  @symphony_dir ".symphony"
  @workpad_file "workpad.md"
  @prompt_file "prompt.md"
  @result_file "run-result.json"
  @issue_file "issue.json"
  @default_phased_phase "execute"
  @default_vanilla_phase "run"
  @default_workpad """
  ### Environment
  `<host>:<abs-workdir>@<unknown-sha>`

  ### Plan
  - [ ] Update this plan before making changes

  ### Acceptance Criteria
  - [ ] Record acceptance criteria here

  ### Validation
  - [ ] Record validation here

  ### Notes
  - Sync this file back to the Org `Codex Workpad`
  """

  @spec run(Issue.t(), pid() | nil, keyword()) :: :ok | no_return()
  def run(%Issue{} = issue, codex_update_recipient \\ nil, opts \\ []) do
    project = prepare_project!(issue, opts)
    workpad = fetch_workpad(issue)
    prompt = PromptBuilder.build_prompt(issue, Keyword.put(opts, :workpad, workpad))
    input = write_input_bundle!(issue, project, prompt, workpad)
    cli_opts = cli_opts(opts)
    run_payload = temporal_run_payload(issue, project, input)

    log_remote_event(
      :info,
      "remote_workflow_submission_start",
      issue,
      workflow_id: Map.get(run_payload, "workflowId"),
      project_id: Map.get(run_payload, "projectId"),
      workflow_mode: Map.get(run_payload, "workflowMode"),
      workspace_path: get_in(run_payload, ["paths", "workspacePath"]),
      artifact_dir: get_in(run_payload, ["paths", "outputsPath"])
    )

    case TemporalCli.run(run_payload, cli_opts) do
      {:ok, run} ->
        run_state = seed_run_state(project, run)
        log_remote_event(:info, "remote_workflow_submission_complete", issue, run_state_log_fields(run_state))
        log_phase_started(issue, run_state)
        emit_session_started(codex_update_recipient, issue, project, run)
        await_remote_completion(issue, run_state, cli_opts, codex_update_recipient)

      {:error, reason} ->
        log_remote_event(
          :error,
          "remote_workflow_submission_failed",
          issue,
          workflow_id: Map.get(run_payload, "workflowId"),
          project_id: Map.get(run_payload, "projectId"),
          workflow_mode: Map.get(run_payload, "workflowMode"),
          workspace_path: get_in(run_payload, ["paths", "workspacePath"]),
          artifact_dir: get_in(run_payload, ["paths", "outputsPath"]),
          reason: inspect(reason)
        )

        Logger.error("Temporal/K3s run failed for #{issue_context(issue)}: #{inspect(reason)}")

        raise RuntimeError,
              "Temporal/K3s run failed for #{issue_context(issue)}: #{inspect(reason)}"
    end
  end

  @spec cancel(term()) :: :ok | {:error, term()}
  def cancel(running_entry), do: cancel(running_entry, [])

  @spec cancel(term(), keyword()) :: :ok | {:error, term()}
  def cancel(running_entry, opts) when is_map(running_entry) do
    workflow_id = Map.get(running_entry, :workflow_id)

    case workflow_id do
      workflow_id when is_binary(workflow_id) ->
        case TemporalCli.cancel(
               temporal_request_payload(workflow_id,
                 workflow_mode: Map.get(running_entry, :workflow_mode) || Config.temporal_workflow_mode()
               ),
               cli_opts(opts)
             ) do
          {:ok, _payload} -> :ok
          {:error, reason} -> {:error, reason}
        end

      _ ->
        :ok
    end
  end

  def cancel(_running_entry, _opts), do: :ok

  @spec remove_issue_project(String.t()) :: :ok
  def remove_issue_project(identifier) when is_binary(identifier) do
    identifier
    |> project_roots_for_identifier()
    |> Enum.each(&remove_project_root(&1, identifier))

    :ok
  end

  def remove_issue_project(_identifier), do: :ok

  @spec runtime_status(keyword()) :: map()
  def runtime_status(opts \\ []) do
    case TemporalCli.readiness(runtime_status_payload(), cli_opts(opts)) do
      {:ok, %{} = payload} ->
        normalize_runtime_status(payload)

      {:error, reason} ->
        helper_failure_runtime_status(reason)
    end
  end

  @spec project_workspace_path(String.t()) :: Path.t()
  def project_workspace_path(identifier) when is_binary(identifier) do
    Path.join(project_root(identifier), "workspace")
  end

  def project_workspace_path(_identifier), do: Config.k3s_project_root()

  defp cli_opts(opts) do
    opts
    |> Keyword.take([:runner, :command])
  end

  defp runtime_status_payload do
    %{
      "temporal" => %{
        "address" => Config.temporal_address(),
        "namespace" => Config.temporal_namespace(),
        "taskQueue" => Config.temporal_task_queue()
      },
      "k3s" => %{
        "namespace" => Config.k3s_namespace()
      }
    }
  end

  defp prepare_project!(issue, opts) do
    identifier = issue.identifier || issue.id || "issue"
    attempt = normalize_run_attempt(Keyword.get(opts, :attempt))

    run_hint =
      Keyword.get(
        opts,
        :run_hint,
        Integer.to_string(System.unique_integer([:positive, :monotonic]))
      )

    project_id = project_id(identifier, attempt, run_hint)
    project_root = project_root(identifier, attempt, run_hint)
    workspace_path = Path.join(project_root, "workspace")
    outputs_path = Path.join(project_root, "outputs")

    for path <- [
          project_root,
          workspace_path,
          outputs_path,
          Path.join(project_root, "home"),
          Path.join(project_root, "config")
        ] do
      File.mkdir_p!(path)
    end

    %{
      identifier: identifier,
      attempt: attempt,
      project_id: project_id,
      project_root: project_root,
      workspace_path: workspace_path,
      outputs_path: outputs_path,
      run_hint: run_hint,
      symphony_path: Path.join(workspace_path, @symphony_dir)
    }
  end

  defp fetch_workpad(%Issue{id: issue_id}) when is_binary(issue_id) do
    case Config.tracker_kind() do
      "orgmode" -> fetch_org_workpad(issue_id)
      _ -> @default_workpad
    end
  end

  defp fetch_workpad(_issue), do: @default_workpad

  defp fetch_org_workpad(issue_id) do
    case Adapter.get_workpad(issue_id) do
      {:ok, content} when is_binary(content) -> normalize_workpad(content)
      _ -> @default_workpad
    end
  end

  defp normalize_workpad(content) do
    case String.trim(content) do
      "" -> @default_workpad
      _ -> content
    end
  end

  defp write_input_bundle!(issue, project, prompt, workpad) do
    File.mkdir_p!(project.symphony_path)

    paths = %{
      prompt_path: Path.join(project.symphony_path, @prompt_file),
      workpad_path: Path.join(project.symphony_path, @workpad_file),
      result_path: Path.join(project.symphony_path, @result_file),
      issue_path: Path.join(project.symphony_path, @issue_file)
    }

    File.write!(paths.prompt_path, prompt)
    File.write!(paths.workpad_path, workpad)
    File.write!(paths.issue_path, Jason.encode!(Map.from_struct(issue), pretty: true))

    paths
  end

  defp temporal_run_payload(issue, project, input) do
    %{
      "workflowId" => workflow_id(issue, project),
      "projectId" => project.project_id,
      "repository" => %{
        "originUrl" => Config.repository_origin_url(),
        "defaultBranch" => Config.repository_default_branch()
      },
      "codex" => %{
        "command" => Config.codex_command()
      },
      "workflowMode" => Config.temporal_workflow_mode(),
      "temporal" => Map.put(temporal_connection_payload(), "taskQueue", Config.temporal_task_queue()),
      "k3s" => %{
        "namespace" => Config.k3s_namespace(),
        "image" => Config.k3s_image(),
        "projectRoot" => Config.k3s_project_root(),
        "sharedCacheRoot" => Config.k3s_shared_cache_root(),
        "ttlSecondsAfterFinished" => Config.k3s_ttl_seconds_after_finished(),
        "defaultCPU" => Config.k3s_default_cpu(),
        "defaultMemory" => Config.k3s_default_memory(),
        "defaultGPUCount" => Config.k3s_default_gpu_count(),
        "runtimeClass" => Config.k3s_runtime_class()
      },
      "issue" => %{
        "id" => issue.id,
        "identifier" => issue.identifier,
        "title" => issue.title,
        "state" => issue.state
      },
      "paths" => %{
        "projectRoot" => project.project_root,
        "workspacePath" => project.workspace_path,
        "outputsPath" => project.outputs_path,
        "promptPath" => input.prompt_path,
        "workpadPath" => input.workpad_path,
        "resultPath" => input.result_path,
        "issuePath" => input.issue_path
      }
    }
  end

  defp await_remote_completion(issue, run_state, cli_opts, recipient) do
    poll_ms = Config.temporal_status_poll_ms()
    do_await_remote_completion(issue, run_state, cli_opts, recipient, poll_ms)
  end

  defp do_await_remote_completion(issue, run_state, cli_opts, recipient, poll_ms) do
    Process.sleep(poll_ms)

    log_remote_event(:info, "remote_status_poll_start", issue, run_state_log_fields(run_state))

    case TemporalCli.status(
           temporal_request_payload(run_state.workflow_id,
             run_id: run_state.run_id,
             workflow_mode: run_state.workflow_mode
           ),
           cli_opts
         ) do
      {:ok, status} ->
        updated_state =
          run_state
          |> update_run_state(status)
          |> mark_status_check_success()

        log_remote_event(:info, "remote_status_poll_result", issue, run_state_log_fields(updated_state))
        maybe_log_phase_transition(issue, run_state, updated_state)
        emit_status_update(recipient, issue, updated_state, status)

        case normalized_workflow_status(status) do
          status when status in ["running", "queued", "pending"] ->
            do_await_remote_completion(issue, updated_state, cli_opts, recipient, poll_ms)

          "succeeded" ->
            sync_and_finalize!(issue, updated_state, status)

          "cancelled" ->
            sync_and_finalize!(issue, updated_state, status)

          "failed" ->
            sync_and_finalize!(issue, updated_state, status)
        end

      {:error, reason} ->
        elapsed_ms = status_failure_elapsed_ms(run_state)
        timeout_ms = Config.codex_stall_timeout_ms()

        log_remote_event(
          :warning,
          "remote_status_poll_failed",
          issue,
          run_state_log_fields(run_state,
            elapsed_ms: elapsed_ms,
            timeout_ms: timeout_ms,
            reason: inspect(reason)
          )
        )

        Logger.warning("Temporal/K3s status check failed for #{issue_context(issue)} elapsed_ms=#{elapsed_ms} timeout_ms=#{timeout_ms}: #{inspect(reason)}")

        case status_failure_timed_out?(elapsed_ms, timeout_ms) do
          true ->
            raise RuntimeError,
                  "Temporal/K3s status checks stalled for #{issue_context(issue)} after #{elapsed_ms}ms (timeout=#{timeout_ms}ms): #{inspect(reason)}"

          false ->
            do_await_remote_completion(issue, run_state, cli_opts, recipient, poll_ms)
        end
    end
  end

  defp seed_run_state(project, run) do
    %{
      workflow_id: string_value(Map.get(run, "workflowId")),
      run_id: string_value(Map.get(run, "runId")),
      status: normalized_workflow_status(run),
      workflow_mode: normalized_workflow_mode(run),
      current_phase: normalized_current_phase(run, normalized_workflow_mode(run)),
      phases:
        normalized_phases(
          run,
          normalized_workflow_mode(run),
          normalized_current_phase(run, normalized_workflow_mode(run)),
          normalized_workflow_status(run),
          string_value(Map.get(run, "jobName")),
          string_value(Map.get(run, "artifactDir")) || project.outputs_path,
          string_value(Map.get(run, "workspacePath")) || project.workspace_path
        ),
      job_name: string_value(Map.get(run, "jobName")),
      artifact_dir: string_value(Map.get(run, "artifactDir")) || project.outputs_path,
      workspace_path: string_value(Map.get(run, "workspacePath")) || project.workspace_path,
      project_id: string_value(Map.get(run, "projectId")) || project.project_id,
      last_status_ok_at_ms: monotonic_now_ms()
    }
  end

  defp update_run_state(run_state, status) do
    workflow_mode = normalized_workflow_mode(status, run_state.workflow_mode)
    current_phase = normalized_current_phase(status, workflow_mode, run_state.current_phase)
    normalized_status = normalized_workflow_status(status)
    job_name = string_value(Map.get(status, "jobName")) || run_state.job_name
    artifact_dir = string_value(Map.get(status, "artifactDir")) || run_state.artifact_dir
    workspace_path = string_value(Map.get(status, "workspacePath")) || run_state.workspace_path

    %{
      run_state
      | status: normalized_status,
        workflow_mode: workflow_mode,
        current_phase: current_phase,
        phases:
          normalized_phases(
            status,
            workflow_mode,
            current_phase,
            normalized_status,
            job_name,
            artifact_dir,
            workspace_path
          ),
        job_name: job_name,
        artifact_dir: artifact_dir,
        workspace_path: workspace_path,
        run_id: string_value(Map.get(status, "runId")) || run_state.run_id
    }
  end

  defp sync_and_finalize!(issue, run_state, status) do
    workpad_path = Path.join(run_state.workspace_path, @symphony_dir <> "/" <> @workpad_file)
    result_path = Path.join(run_state.workspace_path, @symphony_dir <> "/" <> @result_file)

    log_remote_event(
      :info,
      "remote_artifact_sync_start",
      issue,
      run_state_log_fields(run_state, workpad_path: workpad_path, result_path: result_path)
    )

    workpad = read_optional_file(workpad_path)
    run_result = read_optional_json(result_path)
    target_state = if(is_map(run_result), do: target_state_from_run_result(run_result), else: nil)

    log_remote_event(
      :info,
      "remote_artifact_sync_complete",
      issue,
      run_state_log_fields(run_state,
        workpad_path: workpad_path,
        result_path: result_path,
        workpad_present: is_binary(workpad),
        run_result_present: is_map(run_result),
        target_state: target_state
      )
    )

    log_remote_event(
      :info,
      "remote_org_finalization_start",
      issue,
      run_state_log_fields(run_state,
        target_state: target_state,
        tracker_kind: Config.tracker_kind()
      )
    )

    try do
      maybe_replace_org_workpad(issue, workpad)
      maybe_apply_run_result_state(issue, run_result)

      log_remote_event(
        :info,
        "remote_org_finalization_complete",
        issue,
        run_state_log_fields(run_state,
          target_state: target_state,
          tracker_kind: Config.tracker_kind(),
          workpad_synced: is_binary(workpad) and Config.tracker_kind() == "orgmode",
          run_result_present: is_map(run_result)
        )
      )
    rescue
      error ->
        log_remote_event(
          :error,
          "remote_org_finalization_failed",
          issue,
          run_state_log_fields(run_state,
            target_state: target_state,
            tracker_kind: Config.tracker_kind(),
            reason: Exception.message(error)
          )
        )

        reraise(error, __STACKTRACE__)
    end

    case {normalized_workflow_status(status), run_result} do
      {status_name, %{} = result} when status_name in ["succeeded", "failed", "cancelled"] ->
        case allowed_target_state?(target_state_from_run_result(result)) do
          true ->
            :ok

          false ->
            raise RuntimeError,
                  "Temporal/K3s run ended without a valid target state for #{issue_context(issue)}"
        end

      {"succeeded", _} ->
        :ok

      {status_name, _} ->
        raise RuntimeError,
              "Temporal/K3s workflow ended with status=#{status_name} for #{issue_context(issue)}"
    end
  end

  defp maybe_replace_org_workpad(%Issue{id: issue_id} = issue, content)
       when is_binary(issue_id) and is_binary(content) do
    case Config.tracker_kind() do
      "orgmode" ->
        case Adapter.replace_workpad(issue_id, content) do
          {:ok, _content} ->
            :ok

          {:error, reason} ->
            raise RuntimeError,
                  "Temporal/K3s failed to sync Org workpad for #{issue_context(issue)}: #{inspect(reason)}"
        end

      _ ->
        :ok
    end
  end

  defp maybe_replace_org_workpad(_issue, _content), do: :ok

  defp maybe_apply_run_result_state(%Issue{id: issue_id} = issue, %{} = result)
       when is_binary(issue_id) do
    case Config.tracker_kind() do
      "orgmode" ->
        result
        |> target_state_from_run_result()
        |> maybe_sync_org_state!(issue, issue_id)

      _ ->
        :ok
    end
  end

  defp maybe_apply_run_result_state(_issue, _result), do: :ok

  defp target_state_from_run_result(result) do
    case string_value(Map.get(result, "targetState")) do
      nil -> default_target_state(result)
      explicit -> explicit
    end
  end

  defp maybe_sync_org_state!(target_state, issue, issue_id) do
    with true <- is_binary(target_state),
         true <- allowed_target_state?(target_state) do
      case Tracker.update_issue_state(issue_id, target_state) do
        :ok ->
          :ok

        {:error, reason} ->
          raise RuntimeError,
                "Temporal/K3s failed to sync Org state=#{target_state} for #{issue_context(issue)}: #{inspect(reason)}"
      end
    else
      _other ->
        :ok
    end
  end

  defp default_target_state(result) do
    cond do
      truthy?(Map.get(result, "needsContinuation")) ->
        "In Progress"

      string_value(Map.get(result, "blockedReason")) ->
        "Rework"

      true ->
        "Human Review"
    end
  end

  defp allowed_target_state?(state) when is_binary(state) do
    state in ["In Progress", "Human Review", "Rework", "Done"]
  end

  defp emit_session_started(recipient, issue, project, run) when is_pid(recipient) do
    send(recipient, {:codex_worker_update, issue.id, session_started_payload(project, run)})
  end

  defp emit_session_started(_recipient, _issue, _project, _run), do: :ok

  defp session_started_payload(project, run) do
    %{
      event: :session_started,
      timestamp: DateTime.utc_now(),
      session_id: session_id(run),
      execution_backend: "temporal_k3s",
      workflow_id: Map.get(run, "workflowId"),
      workflow_run_id: Map.get(run, "runId"),
      workflow_mode: normalized_workflow_mode(run),
      current_phase: normalized_current_phase(run, normalized_workflow_mode(run)),
      phases:
        normalized_phases(
          run,
          normalized_workflow_mode(run),
          normalized_current_phase(run, normalized_workflow_mode(run)),
          normalized_workflow_status(run),
          Map.get(run, "jobName"),
          Map.get(run, "artifactDir") || project.outputs_path,
          Map.get(run, "workspacePath") || project.workspace_path
        ),
      project_id: Map.get(run, "projectId") || project.project_id,
      workspace_path: Map.get(run, "workspacePath") || project.workspace_path,
      artifact_dir: Map.get(run, "artifactDir") || project.outputs_path,
      job_name: Map.get(run, "jobName"),
      payload: %{
        method: "temporal/session_started",
        params: run
      }
    }
  end

  defp emit_status_update(recipient, issue, run_state, status) when is_pid(recipient) do
    send(recipient, {:codex_worker_update, issue.id, status_payload(run_state, status)})
  end

  defp emit_status_update(_recipient, _issue, _run_state, _status), do: :ok

  defp status_payload(run_state, status) do
    %{
      event: :notification,
      timestamp: DateTime.utc_now(),
      session_id: "#{run_state.workflow_id}/#{run_state.run_id}",
      execution_backend: "temporal_k3s",
      workflow_id: run_state.workflow_id,
      workflow_run_id: run_state.run_id,
      workflow_mode: run_state.workflow_mode,
      current_phase: run_state.current_phase,
      phases: run_state.phases,
      project_id: run_state.project_id,
      workspace_path: run_state.workspace_path,
      artifact_dir: run_state.artifact_dir,
      job_name: run_state.job_name,
      payload: %{
        method: "temporal/status",
        params: status
      }
    }
  end

  defp workflow_id(%Issue{id: issue_id}) when is_binary(issue_id), do: "issue/#{issue_id}"

  defp workflow_id(%Issue{identifier: identifier}) when is_binary(identifier),
    do: "issue/#{safe_identifier(identifier)}"

  defp workflow_id(_issue), do: "issue/unknown"

  defp workflow_id(issue, %{attempt: attempt, run_hint: run_hint})
       when is_integer(attempt) and attempt > 0 and is_binary(run_hint) do
    workflow_id(issue) <> "/attempt-#{attempt}-#{safe_identifier(run_hint)}"
  end

  defp workflow_id(issue, _project), do: workflow_id(issue)

  defp project_root(identifier, attempt \\ nil, run_hint \\ nil) do
    Path.join(Config.k3s_project_root(), project_id(identifier, attempt, run_hint))
  end

  defp project_id(identifier, attempt, run_hint)
       when is_integer(attempt) and attempt > 0 and is_binary(run_hint) do
    base_project_id(identifier) <> "-attempt-#{attempt}-#{safe_identifier(run_hint)}"
  end

  defp project_id(identifier, _attempt, _run_hint) do
    base_project_id(identifier)
  end

  defp base_project_id(identifier) do
    safe_identifier(identifier || "issue")
  end

  defp project_roots_for_identifier(identifier) do
    project_root = Config.k3s_project_root()
    base_project_id = base_project_id(identifier)
    fallback_root = Path.join(project_root, base_project_id)

    case File.ls(project_root) do
      {:ok, entries} ->
        matches =
          entries
          |> Enum.filter(&project_root_entry_for_issue?(&1, base_project_id))
          |> Enum.map(&Path.join(project_root, &1))

        case matches do
          [] -> [fallback_root]
          _entries -> matches
        end

      {:error, _reason} ->
        [fallback_root]
    end
  end

  defp project_root_entry_for_issue?(entry, base_project_id) do
    entry == base_project_id || String.starts_with?(entry, base_project_id <> "-attempt-")
  end

  defp remove_project_root(project_root, identifier)
       when is_binary(project_root) and is_binary(identifier) do
    Workspace.run_before_remove_hook(Path.join(project_root, "workspace"), identifier)
    File.rm_rf(project_root)
  end

  defp temporal_request_payload(workflow_id, opts) when is_binary(workflow_id) and is_list(opts) do
    %{
      "workflowId" => workflow_id,
      "temporal" => temporal_connection_payload()
    }
    |> maybe_put_run_id(Keyword.get(opts, :run_id))
    |> maybe_put_workflow_mode(Keyword.get(opts, :workflow_mode))
  end

  defp temporal_connection_payload do
    %{
      "address" => Config.temporal_address(),
      "namespace" => Config.temporal_namespace()
    }
  end

  defp status_failure_elapsed_ms(run_state) do
    now_ms = monotonic_now_ms()
    last_status_ok_at_ms = Map.get(run_state, :last_status_ok_at_ms) || now_ms
    max(0, now_ms - last_status_ok_at_ms)
  end

  defp status_failure_timed_out?(_elapsed_ms, timeout_ms) when timeout_ms <= 0, do: false
  defp status_failure_timed_out?(elapsed_ms, timeout_ms), do: elapsed_ms >= timeout_ms

  defp mark_status_check_success(run_state) do
    Map.put(run_state, :last_status_ok_at_ms, monotonic_now_ms())
  end

  defp maybe_put_run_id(payload, run_id) when is_binary(run_id) do
    Map.put(payload, "runId", run_id)
  end

  defp maybe_put_run_id(payload, _run_id), do: payload

  defp maybe_put_workflow_mode(payload, workflow_mode) when is_binary(workflow_mode) do
    Map.put(payload, "workflowMode", workflow_mode)
  end

  defp maybe_put_workflow_mode(payload, _workflow_mode), do: payload

  defp maybe_log_phase_transition(issue, previous_state, next_state) do
    cond do
      phase_start?(previous_state, next_state) ->
        log_phase_started(issue, next_state)

      next_state.status == "succeeded" ->
        log_remote_event(:info, "remote_phase_completed", issue, run_state_log_fields(next_state))

      next_state.status in ["failed", "cancelled"] ->
        log_remote_event(:warning, "remote_phase_failed", issue, run_state_log_fields(next_state))

      true ->
        :ok
    end
  end

  defp phase_start?(previous_state, next_state) do
    next_state.status in ["queued", "pending", "running"] and
      (previous_state.current_phase != next_state.current_phase or previous_state.status not in ["queued", "pending", "running"])
  end

  defp log_phase_started(issue, run_state) do
    log_remote_event(:info, "remote_phase_started", issue, run_state_log_fields(run_state))
  end

  defp run_state_log_fields(run_state, extra_fields \\ []) do
    [
      workflow_id: Map.get(run_state, :workflow_id),
      run_id: Map.get(run_state, :run_id),
      workflow_mode: Map.get(run_state, :workflow_mode),
      current_phase: Map.get(run_state, :current_phase),
      status: Map.get(run_state, :status),
      project_id: Map.get(run_state, :project_id),
      workspace_path: Map.get(run_state, :workspace_path),
      artifact_dir: Map.get(run_state, :artifact_dir),
      job_name: Map.get(run_state, :job_name)
    ] ++ extra_fields
  end

  defp log_remote_event(level, event, %Issue{} = issue, fields) when is_list(fields) do
    message =
      [
        event: event,
        issue_id: issue.id,
        issue_identifier: issue.identifier
      ]
      |> Kernel.++(fields)
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Enum.map_join(" ", fn {key, value} -> "#{key}=#{format_log_value(value)}" end)

    case level do
      :error -> Logger.error(message)
      :warning -> Logger.warning(message)
      :info -> Logger.info(message)
    end
  end

  defp format_log_value(value) when is_binary(value) do
    if String.contains?(value, [" ", "\t", "\n"]) do
      inspect(value)
    else
      value
    end
  end

  defp format_log_value(value), do: inspect(value)

  defp session_id(run) do
    workflow_id = Map.get(run, "workflowId") || "issue/unknown"
    run_id = Map.get(run, "runId") || "pending"
    "#{workflow_id}/#{run_id}"
  end

  defp normalized_workflow_mode(%{} = payload, fallback \\ Config.temporal_workflow_mode()) do
    payload
    |> remote_workflow_mode_value()
    |> normalized_workflow_mode_value(fallback)
  end

  defp normalized_workflow_mode_value(value, fallback) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "vanilla" -> "vanilla"
      "phased" -> "phased"
      _ -> normalized_workflow_mode_fallback(fallback)
    end
  end

  defp normalized_workflow_mode_value(_value, fallback), do: normalized_workflow_mode_fallback(fallback)

  defp normalized_workflow_mode_fallback(fallback) when is_binary(fallback) do
    case String.trim(fallback) |> String.downcase() do
      "vanilla" -> "vanilla"
      _ -> "phased"
    end
  end

  defp normalized_current_phase(%{} = payload, workflow_mode, fallback \\ nil) do
    payload
    |> remote_current_phase_value()
    |> normalized_current_phase_value(workflow_mode, fallback)
  end

  defp normalized_current_phase_value(value, workflow_mode, _fallback) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "" -> default_current_phase(workflow_mode)
      normalized -> normalized
    end
  end

  defp normalized_current_phase_value(_value, workflow_mode, fallback) when is_binary(fallback) do
    normalized_current_phase_value(fallback, workflow_mode, nil)
  end

  defp normalized_current_phase_value(_value, workflow_mode, _fallback) do
    default_current_phase(workflow_mode)
  end

  defp normalized_phases(payload, workflow_mode, current_phase, status, job_name, artifact_dir, workspace_path)
       when is_map(payload) do
    case Map.get(payload, "phases") do
      phases when is_list(phases) ->
        phases
        |> Enum.map(&normalize_phase_entry(&1, current_phase, status, job_name, artifact_dir, workspace_path))
        |> Enum.reject(&is_nil/1)
        |> case do
          [] -> [default_phase_entry(workflow_mode, current_phase, status, job_name, artifact_dir, workspace_path)]
          normalized -> normalized
        end

      _ ->
        [default_phase_entry(workflow_mode, current_phase, status, job_name, artifact_dir, workspace_path)]
    end
  end

  defp normalize_phase_entry(entry, current_phase, status, job_name, artifact_dir, workspace_path)
       when is_map(entry) do
    phase_name =
      entry
      |> Map.get("name")
      |> string_value()
      |> case do
        nil -> current_phase
        value -> String.downcase(value)
      end

    phase_status =
      entry
      |> Map.get("status")
      |> string_value()
      |> case do
        nil -> if phase_name == current_phase, do: status, else: "queued"
        value -> normalize_status_value(value)
      end

    %{}
    |> Map.put("name", phase_name)
    |> Map.put("status", phase_status)
    |> maybe_put_string("jobName", Map.get(entry, "jobName") || job_name)
    |> maybe_put_string("artifactDir", Map.get(entry, "artifactDir") || artifact_dir)
    |> maybe_put_string("workspacePath", Map.get(entry, "workspacePath") || workspace_path)
  end

  defp normalize_phase_entry(_entry, _current_phase, _status, _job_name, _artifact_dir, _workspace_path),
    do: nil

  defp default_phase_entry(_workflow_mode, current_phase, status, job_name, artifact_dir, workspace_path) do
    %{}
    |> Map.put("name", current_phase)
    |> Map.put("status", status)
    |> maybe_put_string("jobName", job_name)
    |> maybe_put_string("artifactDir", artifact_dir)
    |> maybe_put_string("workspacePath", workspace_path)
  end

  defp remote_workflow_mode_value(payload) do
    Map.get(payload, "workflow_mode") || Map.get(payload, "workflowMode")
  end

  defp remote_current_phase_value(payload) do
    Map.get(payload, "current_phase") || Map.get(payload, "currentPhase")
  end

  defp default_current_phase("vanilla"), do: @default_vanilla_phase
  defp default_current_phase(_workflow_mode), do: @default_phased_phase

  defp normalized_workflow_status(%{} = payload) do
    payload
    |> Map.get("status", "running")
    |> normalize_status_value()
  end

  defp read_optional_file(path) when is_binary(path) do
    case File.read(path) do
      {:ok, content} ->
        case String.trim(content) do
          "" -> nil
          _ -> content
        end

      {:error, _reason} ->
        nil
    end
  end

  defp read_optional_json(path) when is_binary(path) do
    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, decoded} when is_map(decoded) -> decoded
          _ -> nil
        end

      {:error, _reason} ->
        nil
    end
  end

  defp safe_identifier(identifier) do
    String.replace(identifier, ~r/[^a-zA-Z0-9._-]/, "_")
  end

  defp normalize_run_attempt(attempt) when is_integer(attempt) and attempt > 0, do: attempt
  defp normalize_run_attempt(_attempt), do: nil

  defp string_value(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp string_value(_value), do: nil

  defp maybe_put_string(map, _key, nil), do: map
  defp maybe_put_string(map, key, value) when is_binary(value), do: Map.put(map, key, value)
  defp maybe_put_string(map, key, value), do: maybe_put_string(map, key, string_value(value))

  defp normalize_status_value(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> case do
      "completed" -> "succeeded"
      "success" -> "succeeded"
      "terminated" -> "cancelled"
      "canceled" -> "cancelled"
      "" -> "running"
      other -> other
    end
  end

  defp monotonic_now_ms do
    System.monotonic_time(:millisecond)
  end

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?("TRUE"), do: true
  defp truthy?(1), do: true
  defp truthy?(_value), do: false

  defp normalize_runtime_status(payload) when is_map(payload) do
    blockers = normalize_runtime_blockers(map_value(payload, "blockers"))

    %{
      execution_backend: "temporal_k3s",
      ready: truthy?(map_value(payload, "ready")) and blockers == [],
      blockers: blockers,
      temporal: normalize_runtime_section(map_value(payload, "temporal")),
      k3s: normalize_runtime_section(map_value(payload, "k3s")),
      checked_at: DateTime.utc_now()
    }
  end

  defp helper_failure_runtime_status(reason) do
    %{
      execution_backend: "temporal_k3s",
      ready: false,
      blockers: [
        %{
          "code" => "temporal_helper_failed",
          "message" => format_runtime_reason(reason)
        }
      ],
      temporal: nil,
      k3s: nil,
      checked_at: DateTime.utc_now()
    }
  end

  defp normalize_runtime_blockers(blockers) when is_list(blockers) do
    blockers
    |> Enum.map(&normalize_runtime_blocker/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_runtime_blockers(_blockers), do: []

  defp normalize_runtime_blocker(blocker) when is_map(blocker) do
    case {map_value(blocker, "code"), map_value(blocker, "message")} do
      {code, message} when is_binary(code) and is_binary(message) ->
        %{"code" => code, "message" => message}

      _ ->
        nil
    end
  end

  defp normalize_runtime_blocker(_blocker), do: nil

  defp normalize_runtime_section(section) when is_map(section), do: section
  defp normalize_runtime_section(_section), do: nil

  defp map_value(map, key) when is_map(map) do
    Enum.find_value(map, fn
      {^key, value} ->
        value

      {entry_key, value} ->
        if to_string(entry_key) == key, do: value
    end)
  end

  defp format_runtime_reason({:temporal_helper_failed, status, output})
       when is_integer(status) and is_binary(output) do
    "Temporal/K3s readiness helper failed with exit #{status}: #{output}"
  end

  defp format_runtime_reason({:temporal_helper_failed, message}) when is_binary(message) do
    "Temporal/K3s readiness helper failed: #{message}"
  end

  defp format_runtime_reason(reason), do: "Temporal/K3s readiness probe failed: #{inspect(reason)}"

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end
end
