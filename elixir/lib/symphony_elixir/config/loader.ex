defmodule SymphonyElixir.Config.Loader do
  @moduledoc false

  alias SymphonyElixir.Config.Schema

  @spec settings({:ok, map()} | {:error, term()} | term()) :: {:ok, Schema.t()} | {:error, term()}
  def settings(current_workflow) do
    case current_workflow do
      {:ok, %{config: config}} when is_map(config) ->
        config
        |> normalize_keys()
        |> schema_settings_payload()
        |> Schema.parse()

      {:error, reason} ->
        {:error, reason}

      _ ->
        Schema.parse(%{})
    end
  end

  @spec settings!({:ok, map()} | {:error, term()} | term()) :: Schema.t()
  def settings!(current_workflow) do
    case settings(current_workflow) do
      {:ok, settings} ->
        settings

      {:error, reason} ->
        raise ArgumentError, message: format_config_error(reason)
    end
  end

  @spec workflow_prompt({:ok, map()} | {:error, term()} | term(), String.t()) :: String.t()
  def workflow_prompt(current_workflow, default_prompt_template) do
    case current_workflow do
      {:ok, %{prompt_template: prompt}} when is_binary(prompt) ->
        if String.trim(prompt) == "", do: default_prompt_template, else: prompt

      _ ->
        default_prompt_template
    end
  end

  @spec format_config_error(term()) :: String.t()
  def format_config_error(reason) do
    case reason do
      {:invalid_workflow_config, message} ->
        "Invalid WORKFLOW.md config: #{message}"

      {:missing_workflow_file, path, raw_reason} ->
        "Missing WORKFLOW.md at #{path}: #{inspect(raw_reason)}"

      {:workflow_parse_error, raw_reason} ->
        "Failed to parse WORKFLOW.md: #{inspect(raw_reason)}"

      :workflow_front_matter_not_a_map ->
        "Failed to parse WORKFLOW.md: workflow front matter must decode to a map"

      other ->
        "Invalid WORKFLOW.md config: #{inspect(other)}"
    end
  end

  defp schema_settings_payload(config) when is_map(config) do
    %{
      "tracker" => schema_tracker_payload(section_map(config, "tracker")),
      "polling" => section_map(config, "polling"),
      "workspace" => section_map(config, "workspace"),
      "agent" => section_map(config, "agent"),
      "codex" => schema_codex_payload(section_map(config, "codex")),
      "hooks" => section_map(config, "hooks"),
      "observability" => section_map(config, "observability"),
      "server" => section_map(config, "server")
    }
  end

  defp schema_tracker_payload(section) when is_map(section) do
    section
    |> Map.update("kind", nil, &normalize_tracker_kind/1)
    |> Map.update("active_states", nil, &schema_csv_or_list_value/1)
    |> Map.update("terminal_states", nil, &schema_csv_or_list_value/1)
  end

  defp schema_codex_payload(section) when is_map(section) do
    case Map.get(section, "turn_sandbox_policy") do
      nil ->
        section

      policy when is_map(policy) ->
        section

      _other ->
        Map.delete(section, "turn_sandbox_policy")
    end
  end

  defp schema_csv_or_list_value(nil), do: nil

  defp schema_csv_or_list_value(values) when is_list(values) do
    values
    |> Enum.map(&scalar_string_value/1)
    |> Enum.reject(&(&1 in [:omit, ""]))
  end

  defp schema_csv_or_list_value(value), do: value

  defp normalize_keys(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, raw_value}, normalized ->
      Map.put(normalized, normalize_key(key), normalize_keys(raw_value))
    end)
  end

  defp normalize_keys(value) when is_list(value), do: Enum.map(value, &normalize_keys/1)
  defp normalize_keys(value), do: value

  defp normalize_key(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_key(value), do: to_string(value)

  defp normalize_tracker_kind(kind) when is_binary(kind) do
    kind
    |> String.trim()
    |> String.downcase()
    |> case do
      "org" -> "orgmode"
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_tracker_kind(_kind), do: nil

  defp scalar_string_value(nil), do: :omit
  defp scalar_string_value(value) when is_binary(value), do: String.trim(value)
  defp scalar_string_value(value) when is_boolean(value), do: to_string(value)
  defp scalar_string_value(value) when is_integer(value), do: to_string(value)
  defp scalar_string_value(value) when is_float(value), do: to_string(value)
  defp scalar_string_value(value) when is_atom(value), do: Atom.to_string(value)
  defp scalar_string_value(_value), do: :omit

  defp section_map(config, key) do
    case Map.get(config, key) do
      section when is_map(section) -> section
      _ -> %{}
    end
  end
end
