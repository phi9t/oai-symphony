defmodule SymphonyElixir.Execution.TemporalK3s do
  @moduledoc """
  Remote execution backend that runs agent work through Temporal and K3s.
  """

  require Logger

  alias SymphonyElixir.{Config, PromptBuilder, TemporalCli, Tracker}
  alias SymphonyElixir.Org.Adapter
  alias SymphonyElixir.Tracker.Issue

  @symphony_dir ".symphony"
  @workpad_file "workpad.md"
  @prompt_file "prompt.md"
  @result_file "run-result.json"
  @issue_file "issue.json"
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

    case TemporalCli.run(temporal_run_payload(issue, project, input), cli_opts) do
      {:ok, run} ->
        emit_session_started(codex_update_recipient, issue, project, run)
        await_remote_completion(issue, project, run, cli_opts, codex_update_recipient)

      {:error, reason} ->
        Logger.error("Temporal/K3s run failed for #{issue_context(issue)}: #{inspect(reason)}")

        raise RuntimeError,
              "Temporal/K3s run failed for #{issue_context(issue)}: #{inspect(reason)}"
    end
  end

  @spec cancel(map(), keyword()) :: :ok | {:error, term()}
  def cancel(running_entry, opts \\ [])

  def cancel(running_entry, opts) when is_map(running_entry) do
    workflow_id = Map.get(running_entry, :workflow_id)

    case workflow_id do
      workflow_id when is_binary(workflow_id) ->
        case TemporalCli.cancel(temporal_request_payload(workflow_id), cli_opts(opts)) do
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
    |> project_root()
    |> File.rm_rf()

    :ok
  end

  def remove_issue_project(_identifier), do: :ok

  @spec project_workspace_path(String.t()) :: Path.t()
  def project_workspace_path(identifier) when is_binary(identifier) do
    Path.join(project_root(identifier), "workspace")
  end

  def project_workspace_path(_identifier), do: Config.k3s_project_root()

  defp cli_opts(opts) do
    opts
    |> Keyword.take([:runner, :command])
  end

  defp prepare_project!(issue, opts) do
    identifier = issue.identifier || issue.id || "issue"
    project_id = project_id(identifier)
    project_root = project_root(identifier)
    workspace_path = Path.join(project_root, "workspace")
    outputs_path = Path.join(project_root, "outputs")

    run_hint =
      Keyword.get(
        opts,
        :run_hint,
        Integer.to_string(System.unique_integer([:positive, :monotonic]))
      )

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
      project_id: project_id,
      project_root: project_root,
      workspace_path: workspace_path,
      outputs_path: outputs_path,
      run_hint: run_hint,
      symphony_path: Path.join(workspace_path, @symphony_dir)
    }
  end

  defp fetch_workpad(%Issue{id: issue_id}) when is_binary(issue_id) do
    if Config.tracker_kind() == "orgmode" do
      fetch_org_workpad(issue_id)
    else
      @default_workpad
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
      "workflowId" => workflow_id(issue),
      "projectId" => project.project_id,
      "repository" => %{
        "originUrl" => Config.repository_origin_url(),
        "defaultBranch" => Config.repository_default_branch()
      },
      "codex" => %{
        "command" => Config.codex_command()
      },
      "temporal" =>
        Map.put(temporal_connection_payload(), "taskQueue", Config.temporal_task_queue()),
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

  defp await_remote_completion(issue, project, run, cli_opts, recipient) do
    poll_ms = Config.temporal_status_poll_ms()
    run_state = seed_run_state(project, run)
    do_await_remote_completion(issue, run_state, cli_opts, recipient, poll_ms)
  end

  defp do_await_remote_completion(issue, run_state, cli_opts, recipient, poll_ms) do
    Process.sleep(poll_ms)

    case TemporalCli.status(
           temporal_request_payload(run_state.workflow_id, run_state.run_id),
           cli_opts
         ) do
      {:ok, status} ->
        updated_state =
          run_state
          |> update_run_state(status)
          |> mark_status_check_success()

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

        Logger.warning(
          "Temporal/K3s status check failed for #{issue_context(issue)} elapsed_ms=#{elapsed_ms} timeout_ms=#{timeout_ms}: #{inspect(reason)}"
        )

        if status_failure_timed_out?(elapsed_ms, timeout_ms) do
          raise RuntimeError,
                "Temporal/K3s status checks stalled for #{issue_context(issue)} after #{elapsed_ms}ms (timeout=#{timeout_ms}ms): #{inspect(reason)}"
        else
          do_await_remote_completion(issue, run_state, cli_opts, recipient, poll_ms)
        end
    end
  end

  defp seed_run_state(project, run) do
    %{
      workflow_id: string_value(Map.get(run, "workflowId")),
      run_id: string_value(Map.get(run, "runId")),
      status: normalized_workflow_status(run),
      job_name: string_value(Map.get(run, "jobName")),
      artifact_dir: string_value(Map.get(run, "artifactDir")) || project.outputs_path,
      workspace_path: string_value(Map.get(run, "workspacePath")) || project.workspace_path,
      project_id: string_value(Map.get(run, "projectId")) || project.project_id,
      last_status_ok_at_ms: monotonic_now_ms()
    }
  end

  defp update_run_state(run_state, status) do
    %{
      run_state
      | status: normalized_workflow_status(status),
        job_name: string_value(Map.get(status, "jobName")) || run_state.job_name,
        artifact_dir: string_value(Map.get(status, "artifactDir")) || run_state.artifact_dir,
        workspace_path:
          string_value(Map.get(status, "workspacePath")) || run_state.workspace_path,
        run_id: string_value(Map.get(status, "runId")) || run_state.run_id
    }
  end

  defp sync_and_finalize!(issue, run_state, status) do
    workpad_path = Path.join(run_state.workspace_path, @symphony_dir <> "/" <> @workpad_file)
    result_path = Path.join(run_state.workspace_path, @symphony_dir <> "/" <> @result_file)
    workpad = read_optional_file(workpad_path)
    run_result = read_optional_json(result_path)

    maybe_replace_org_workpad(issue, workpad)
    maybe_apply_run_result_state(issue, run_result)

    case {normalized_workflow_status(status), run_result} do
      {status_name, %{} = result} when status_name in ["succeeded", "failed", "cancelled"] ->
        if allowed_target_state?(Map.get(result, "targetState")) or
             Map.has_key?(result, "needsContinuation") do
          :ok
        else
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
    if Config.tracker_kind() == "orgmode" do
      case Adapter.replace_workpad(issue_id, content) do
        {:ok, _content} ->
          :ok

        {:error, reason} ->
          raise RuntimeError,
                "Temporal/K3s failed to sync Org workpad for #{issue_context(issue)}: #{inspect(reason)}"
      end
    end

    :ok
  end

  defp maybe_replace_org_workpad(_issue, _content), do: :ok

  defp maybe_apply_run_result_state(%Issue{id: issue_id} = issue, %{} = result)
       when is_binary(issue_id) do
    if Config.tracker_kind() == "orgmode" do
      target_state =
        case string_value(Map.get(result, "targetState")) do
          nil ->
            default_target_state(result)

          explicit ->
            explicit
        end

      if allowed_target_state?(target_state) do
        case Tracker.update_issue_state(issue_id, target_state) do
          :ok ->
            :ok

          {:error, reason} ->
            raise RuntimeError,
                  "Temporal/K3s failed to sync Org state=#{target_state} for #{issue_context(issue)}: #{inspect(reason)}"
        end
      end
    end

    :ok
  end

  defp maybe_apply_run_result_state(_issue, _result), do: :ok

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

  defp allowed_target_state?(_state), do: false

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

  defp project_root(identifier) do
    Path.join(Config.k3s_project_root(), project_id(identifier))
  end

  defp project_id(identifier) do
    safe_identifier(identifier || "issue")
  end

  defp temporal_request_payload(workflow_id, run_id \\ nil) when is_binary(workflow_id) do
    %{
      "workflowId" => workflow_id,
      "temporal" => temporal_connection_payload()
    }
    |> maybe_put_run_id(run_id)
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

  defp session_id(run) do
    workflow_id = Map.get(run, "workflowId") || "issue/unknown"
    run_id = Map.get(run, "runId") || "pending"
    "#{workflow_id}/#{run_id}"
  end

  defp normalized_workflow_status(%{} = payload) do
    payload
    |> Map.get("status", "running")
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

  defp string_value(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp string_value(_value), do: nil

  defp monotonic_now_ms do
    System.monotonic_time(:millisecond)
  end

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?("TRUE"), do: true
  defp truthy?(1), do: true
  defp truthy?(_value), do: false

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end
end
