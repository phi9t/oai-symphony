defmodule SymphonyElixir.Org.Adapter do
  @moduledoc """
  Org mode-backed tracker adapter.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Org.Client

  @spec fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues, do: client_module().fetch_candidate_issues()

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states), do: client_module().fetch_issues_by_states(states)

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids),
    do: client_module().fetch_issue_states_by_ids(issue_ids)

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    case client_module().replace_workpad(issue_id, body) do
      {:ok, _content} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name)
      when is_binary(issue_id) and is_binary(state_name) do
    case client_module().set_task_state(issue_id, state_name) do
      {:ok, _issue} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec get_task(String.t()) :: {:ok, term()} | {:error, term()}
  def get_task(issue_id) when is_binary(issue_id), do: client_module().get_task(issue_id)

  @spec get_workpad(String.t()) :: {:ok, String.t()} | {:error, term()}
  def get_workpad(issue_id) when is_binary(issue_id), do: client_module().get_workpad(issue_id)

  @spec replace_workpad(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def replace_workpad(issue_id, content) when is_binary(issue_id) and is_binary(content) do
    client_module().replace_workpad(issue_id, content)
  end

  @spec deep_dive(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def deep_dive(issue_id, content) when is_binary(issue_id) and is_binary(content) do
    client_module().deep_dive(issue_id, content)
  end

  @spec deep_revision(String.t(), String.t(), String.t(), [map()]) ::
          {:ok, map()} | {:error, term()}
  def deep_revision(issue_id, mode, content, tasks)
      when is_binary(issue_id) and is_binary(mode) and is_binary(content) and is_list(tasks) do
    client_module().deep_revision(issue_id, mode, content, tasks)
  end

  defp client_module do
    Application.get_env(:symphony_elixir, :org_client_module, Client)
  end
end
