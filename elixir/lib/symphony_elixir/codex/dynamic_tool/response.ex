defmodule SymphonyElixir.Codex.DynamicTool.Response do
  @moduledoc false

  alias SymphonyElixir.Tracker.Issue

  @spec graphql(term()) :: map()
  def graphql(response) do
    success =
      case response do
        %{"errors" => errors} when is_list(errors) and errors != [] -> false
        %{errors: errors} when is_list(errors) and errors != [] -> false
        _ -> true
      end

    respond(success, response)
  end

  @spec success(map() | [term()]) :: map()
  def success(payload) when is_map(payload) or is_list(payload) do
    respond(true, payload)
  end

  @spec failure(map() | [term()]) :: map()
  def failure(payload) when is_map(payload) or is_list(payload) do
    respond(false, payload)
  end

  defp respond(success, payload) do
    %{
      "success" => success,
      "contentItems" => [
        %{
          "type" => "inputText",
          "text" => encode_payload(payload)
        }
      ]
    }
  end

  defp encode_payload(payload) when is_map(payload) or is_list(payload) do
    payload
    |> normalize_payload()
    |> Jason.encode!(pretty: true)
  end

  defp encode_payload(payload), do: inspect(payload)

  defp normalize_payload(%Issue{} = issue) do
    issue
    |> Map.from_struct()
    |> normalize_payload()
  end

  defp normalize_payload(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)

  defp normalize_payload(payload) when is_map(payload) do
    Map.new(payload, fn {key, value} ->
      {normalize_payload_key(key), normalize_payload(value)}
    end)
  end

  defp normalize_payload(payload) when is_list(payload) do
    Enum.map(payload, &normalize_payload/1)
  end

  defp normalize_payload(payload), do: payload

  defp normalize_payload_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_payload_key(key), do: key
end
