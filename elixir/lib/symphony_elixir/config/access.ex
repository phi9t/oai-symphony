defmodule SymphonyElixir.Config.Access do
  @moduledoc false

  @spec resolve_path_value(term(), term()) :: term()
  def resolve_path_value(:missing, default), do: default
  def resolve_path_value(nil, default), do: default

  def resolve_path_value(value, default) when is_binary(value) do
    case normalize_path_token(value) do
      :missing ->
        default

      path ->
        path
        |> String.trim()
        |> preserve_command_name()
        |> then(fn
          "" -> default
          resolved -> resolved
        end)
    end
  end

  def resolve_path_value(_value, default), do: default

  @spec resolve_env_value(term(), term()) :: term()
  def resolve_env_value(:missing, fallback), do: fallback
  def resolve_env_value(nil, fallback), do: fallback

  def resolve_env_value(value, fallback) when is_binary(value) do
    trimmed = String.trim(value)

    case env_reference_name(trimmed) do
      {:ok, env_name} ->
        env_name
        |> System.get_env()
        |> then(fn
          nil -> fallback
          "" -> nil
          env_value -> env_value
        end)

      :error ->
        trimmed
    end
  end

  def resolve_env_value(_value, fallback), do: fallback

  @spec normalize_secret_value(term()) :: String.t() | nil
  def normalize_secret_value(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  def normalize_secret_value(_value), do: nil

  @spec normalize_issue_state(String.t() | term()) :: String.t()
  def normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  def normalize_issue_state(_state_name), do: ""

  @spec org_emacsclient_available?(String.t()) :: boolean()
  def org_emacsclient_available?(command) when is_binary(command) do
    case OptionParser.split(command) do
      [command_name | _args] ->
        org_emacsclient_command_path?(command_name)

      _ ->
        false
    end
  rescue
    _error ->
      false
  end

  def org_emacsclient_available?(_command), do: false

  defp preserve_command_name(path) do
    cond do
      uri_path?(path) ->
        path

      String.contains?(path, "/") or String.contains?(path, "\\") ->
        Path.expand(path)

      true ->
        path
    end
  end

  defp uri_path?(path) do
    String.match?(to_string(path), ~r/^[a-zA-Z][a-zA-Z0-9+.-]*:\/\//)
  end

  defp normalize_path_token(value) when is_binary(value) do
    trimmed = String.trim(value)

    case env_reference_name(trimmed) do
      {:ok, env_name} -> resolve_env_token(env_name)
      :error -> trimmed
    end
  end

  defp env_reference_name("$" <> env_name) do
    if String.match?(env_name, ~r/^[A-Za-z_][A-Za-z0-9_]*$/) do
      {:ok, env_name}
    else
      :error
    end
  end

  defp env_reference_name(_value), do: :error

  defp resolve_env_token(value) do
    case System.get_env(value) do
      nil -> :missing
      env_value -> env_value
    end
  end

  defp org_emacsclient_command_path?(command) when is_binary(command) do
    cond do
      command == "" ->
        false

      String.contains?(command, "/") ->
        File.exists?(command)

      true ->
        not is_nil(System.find_executable(command))
    end
  end
end
