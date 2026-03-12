defmodule SymphonyElixir.Execution do
  @moduledoc """
  Utilities for switching between local and remote execution backends.
  """

  alias SymphonyElixir.{Config, Workspace}
  alias SymphonyElixir.Execution.TemporalK3s

  @spec remote_backend?(map()) :: boolean()
  def remote_backend?(running_entry) when is_map(running_entry) do
    backend = Map.get(running_entry, :execution_backend) || Config.execution_kind()
    backend == "temporal_k3s"
  end

  def remote_backend?(_running_entry), do: Config.execution_kind() == "temporal_k3s"

  @spec cancel(map()) :: :ok
  def cancel(running_entry) when is_map(running_entry) do
    if remote_backend?(running_entry) do
      _ = TemporalK3s.cancel(running_entry)
    end

    :ok
  end

  def cancel(_running_entry), do: :ok

  @spec cleanup_issue_workspace(String.t() | nil) :: :ok
  def cleanup_issue_workspace(identifier), do: cleanup_issue_workspace(identifier, nil)

  @spec cleanup_issue_workspace(String.t() | nil, map() | nil) :: :ok
  def cleanup_issue_workspace(identifier, running_entry) when is_binary(identifier) do
    if remote_backend?(running_entry || %{}) do
      TemporalK3s.remove_issue_project(identifier)
    else
      Workspace.remove_issue_workspaces(identifier)
    end

    :ok
  end

  def cleanup_issue_workspace(_identifier, _running_entry), do: :ok

  @spec workspace_path(String.t()) :: Path.t()
  def workspace_path(identifier), do: workspace_path(identifier, nil)

  @spec workspace_path(String.t(), map() | nil) :: Path.t()
  def workspace_path(identifier, running_entry) when is_binary(identifier) do
    cond do
      is_map(running_entry) and is_binary(Map.get(running_entry, :workspace_path)) ->
        Map.get(running_entry, :workspace_path)

      remote_backend?(running_entry || %{}) ->
        TemporalK3s.project_workspace_path(identifier)

      true ->
        Path.join(Config.workspace_root(), safe_identifier(identifier))
    end
  end

  def workspace_path(_identifier, _running_entry), do: Config.workspace_root()

  @spec skip_stall_detection?(map()) :: boolean()
  def skip_stall_detection?(running_entry) when is_map(running_entry) do
    remote_backend?(running_entry)
  end

  def skip_stall_detection?(_running_entry), do: false

  @spec runtime_status() :: map()
  def runtime_status do
    case Config.execution_kind() do
      "temporal_k3s" ->
        TemporalK3s.runtime_status()

      kind ->
        %{
          execution_backend: kind,
          ready: true,
          blockers: [],
          checked_at: DateTime.utc_now()
        }
    end
  end

  defp safe_identifier(identifier) when is_binary(identifier) do
    String.replace(identifier, ~r/[^a-zA-Z0-9._-]/, "_")
  end
end
