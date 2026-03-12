defmodule SymphonyElixir.Org.Client do
  @moduledoc """
  Executes Org mode tracker operations through the configured Emacs command.
  """

  alias SymphonyElixir.{Config, Tracker.Issue}

  @default_timeout_ms 30_000

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    with {:ok, data} <-
           invoke("fetch_candidate_issues", %{"states" => Config.tracker_active_states()}) do
      decode_issue_list(data)
    end
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) when is_list(state_names) do
    normalized_states =
      state_names
      |> Enum.map(&to_string/1)
      |> Enum.uniq()

    if normalized_states == [] do
      {:ok, []}
    else
      with {:ok, data} <-
             invoke("fetch_issues_by_states", %{"states" => normalized_states}) do
        decode_issue_list(data)
      end
    end
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) when is_list(issue_ids) do
    ids =
      issue_ids
      |> Enum.map(&to_string/1)
      |> Enum.uniq()

    if ids == [] do
      {:ok, []}
    else
      with {:ok, data} <- invoke("fetch_issue_states_by_ids", %{"ids" => ids}) do
        decode_issue_list(data)
      end
    end
  end

  @spec get_task(String.t()) :: {:ok, Issue.t()} | {:error, term()}
  def get_task(issue_id) when is_binary(issue_id) do
    with {:ok, data} <- invoke("get_task", %{"task_id" => issue_id}) do
      decode_single_issue(data)
    end
  end

  @spec get_workpad(String.t()) :: {:ok, String.t()} | {:error, term()}
  def get_workpad(issue_id) when is_binary(issue_id) do
    case invoke("get_workpad", %{"task_id" => issue_id}) do
      {:ok, %{"content" => content}} when is_binary(content) -> {:ok, content}
      {:ok, _unexpected} -> {:error, :invalid_org_workpad_response}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec replace_workpad(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def replace_workpad(issue_id, content) when is_binary(issue_id) and is_binary(content) do
    case invoke("replace_workpad", %{"task_id" => issue_id, "content" => content}) do
      {:ok, %{"content" => updated_content}} when is_binary(updated_content) ->
        {:ok, updated_content}

      {:ok, _unexpected} ->
        {:error, :invalid_org_workpad_response}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec deep_dive(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def deep_dive(issue_id, content) when is_binary(issue_id) and is_binary(content) do
    with {:ok, data} <- invoke("deep_dive", %{"task_id" => issue_id, "content" => content}) do
      decode_content_response(data, "Deep Dive")
    end
  end

  @spec deep_revision(String.t(), String.t(), String.t(), [map()]) ::
          {:ok, map()} | {:error, term()}
  def deep_revision(issue_id, mode, content, tasks)
      when is_binary(issue_id) and is_binary(mode) and is_binary(content) and is_list(tasks) do
    with {:ok, data} <-
           invoke("deep_revision", %{
             "task_id" => issue_id,
             "mode" => mode,
             "content" => content,
             "tasks" => tasks
           }) do
      decode_revision_response(data)
    end
  end

  @spec set_task_state(String.t(), String.t()) :: {:ok, Issue.t()} | {:error, term()}
  def set_task_state(issue_id, state_name)
      when is_binary(issue_id) and is_binary(state_name) do
    with {:ok, data} <-
           invoke("set_state", %{"task_id" => issue_id, "state" => state_name}) do
      decode_single_issue(data)
    end
  end

  defp decode_issue_list(data) when is_list(data) do
    {:ok, Enum.map(data, &decode_issue!/1)}
  rescue
    error in [ArgumentError, KeyError] ->
      {:error, {:invalid_org_issue_payload, Exception.message(error)}}
  end

  defp decode_issue_list(nil), do: {:ok, []}
  defp decode_issue_list(_data), do: {:error, :invalid_org_issue_list_payload}

  defp decode_single_issue(data) when is_map(data), do: {:ok, decode_issue!(data)}
  defp decode_single_issue(_data), do: {:error, :invalid_org_issue_payload}

  defp decode_content_response(data, default_section) when is_map(data) do
    case {string_or_nil(Map.get(data, "taskId")), string_or_nil(Map.get(data, "content"))} do
      {task_id, content} when is_binary(task_id) and is_binary(content) ->
        {:ok,
         %{
           "taskId" => task_id,
           "section" => string_or_nil(Map.get(data, "section")) || default_section,
           "content" => content
         }}

      _ ->
        {:error, :invalid_org_workpad_response}
    end
  end

  defp decode_content_response(_data, _default_section),
    do: {:error, :invalid_org_workpad_response}

  defp decode_revision_response(data) when is_map(data) do
    with {:ok, response} <- decode_content_response(data, "Deep Revision"),
         {:ok, created_tasks} <- decode_created_tasks(Map.get(data, "createdTasks")) do
      {:ok,
       response
       |> Map.put("mode", string_or_nil(Map.get(data, "mode")) || "draft")
       |> Map.put("createdTasks", created_tasks)}
    end
  end

  defp decode_revision_response(_data), do: {:error, :invalid_org_workpad_response}

  defp decode_created_tasks(nil), do: {:ok, []}
  defp decode_created_tasks(data), do: decode_issue_list(data)

  defp decode_issue!(data) when is_map(data) do
    %Issue{
      id: string_or_nil(Map.get(data, "id")),
      identifier: string_or_nil(Map.get(data, "identifier")),
      title: string_or_nil(Map.get(data, "title")),
      description: string_or_nil(Map.get(data, "description")),
      priority: integer_or_nil(Map.get(data, "priority")),
      state: string_or_nil(Map.get(data, "state")),
      branch_name: string_or_nil(Map.get(data, "branch_name")),
      url: string_or_nil(Map.get(data, "url")),
      assignee_id: nil,
      blocked_by: normalize_blockers(Map.get(data, "blocked_by")),
      labels: normalize_labels(Map.get(data, "labels")),
      assigned_to_worker: true,
      created_at: datetime_or_nil(Map.get(data, "created_at")),
      updated_at: datetime_or_nil(Map.get(data, "updated_at"))
    }
  end

  defp normalize_labels(labels) when is_list(labels) do
    labels
    |> Enum.map(&string_or_nil/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&String.downcase/1)
  end

  defp normalize_labels(_labels), do: []

  defp normalize_blockers(blockers) when is_list(blockers) do
    Enum.map(blockers, fn blocker ->
      %{
        id: string_or_nil(Map.get(blocker, "id")),
        identifier: string_or_nil(Map.get(blocker, "identifier")),
        state: string_or_nil(Map.get(blocker, "state"))
      }
    end)
  end

  defp normalize_blockers(_blockers), do: []

  defp datetime_or_nil(nil), do: nil

  defp datetime_or_nil(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp datetime_or_nil(_value), do: nil

  defp integer_or_nil(value) when is_integer(value), do: value
  defp integer_or_nil(_value), do: nil

  defp string_or_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp string_or_nil(_value), do: nil

  defp invoke(action, payload) when is_binary(action) and is_map(payload) do
    request =
      payload
      |> Map.put("action", action)
      |> Map.put("file", Config.org_file())
      |> Map.put("root_id", Config.org_root_id())
      |> Map.put("state_map", Config.org_state_map())

    lock_key = {:symphony_org_tracker, Path.expand(Config.org_file() || "orgmode")}

    :global.trans(lock_key, fn ->
      request
      |> execute_request()
      |> normalize_response()
    end)
  end

  defp execute_request(request) do
    request_json = Jason.encode!(request)
    helper_path = helper_path()
    dispatch_expression = dispatch_expression(helper_path, Base.encode64(request_json))

    with {:ok, command, args} <- parse_emacsclient_command(Config.org_emacsclient_command()) do
      case run_emacsclient(command, args ++ ["--eval", dispatch_expression]) do
        {output, 0} ->
          decode_emacsclient_output(output)

        {output, status} when is_binary(output) and is_integer(status) ->
          {:error, {:org_emacsclient_failed, status, String.trim(output)}}

        {:error, :timeout} ->
          {:error, {:org_emacsclient_failed, :timeout}}
      end
    end
  rescue
    error in [ArgumentError, RuntimeError] ->
      {:error, {:org_emacsclient_failed, Exception.message(error)}}
  end

  defp normalize_response({:ok, %{"status" => "ok", "data" => data}}), do: {:ok, data}

  defp normalize_response({:ok, %{"status" => "error", "error" => error}}),
    do: {:error, normalize_error(error)}

  defp normalize_response({:ok, _response}), do: {:error, :invalid_org_response}
  defp normalize_response({:error, reason}), do: {:error, reason}

  defp normalize_error("root_not_found"), do: :org_root_not_found
  defp normalize_error("task_not_found"), do: :org_task_not_found
  defp normalize_error("state_not_found"), do: :org_state_not_found
  defp normalize_error("invalid_action"), do: :invalid_org_action
  defp normalize_error(other) when is_binary(other), do: {:org_error, other}
  defp normalize_error(other), do: other

  defp decode_emacsclient_output(output) when is_binary(output) do
    output
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> List.last()
    |> case do
      nil ->
        {:error, :missing_org_emacsclient_output}

      encoded ->
        encoded
        |> strip_wrapping_quotes()
        |> Base.decode64()
        |> case do
          {:ok, response_json} -> Jason.decode(response_json)
          :error -> {:error, :invalid_org_emacsclient_payload}
        end
    end
  end

  defp strip_wrapping_quotes("\"" <> encoded) do
    encoded
    |> String.trim_trailing("\"")
    |> String.replace("\\\"", "\"")
    |> String.replace("\\\\", "\\")
  end

  defp strip_wrapping_quotes(encoded), do: encoded

  defp parse_emacsclient_command(command) when is_binary(command) do
    case OptionParser.split(command) do
      [binary | args] -> {:ok, binary, args}
      _ -> {:error, :missing_org_emacsclient}
    end
  rescue
    _error ->
      {:error, :missing_org_emacsclient}
  end

  defp dispatch_expression(helper_path, request_base64)
       when is_binary(helper_path) and is_binary(request_base64) do
    """
    (progn
      (load #{Jason.encode!(helper_path)} nil t)
      (let ((result (symphony-orgmode-dispatch-json #{Jason.encode!(request_base64)})))
        (princ result)
        (terpri)))
    """
    |> String.trim()
  end

  defp run_emacsclient(command, args) do
    task =
      Task.async(fn ->
        System.cmd(command, args, stderr_to_stdout: true)
      end)

    case Task.yield(task, @default_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> {:error, :timeout}
    end
  end

  defp helper_path do
    Path.expand("../../../priv/elisp/symphony_orgmode", __DIR__)
  end
end
