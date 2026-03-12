defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Executes client-side tool calls requested by Codex app-server turns.
  """

  alias SymphonyElixir.Codex.DynamicTool.{LinearGraphQL, OrgTask, Response}
  alias SymphonyElixir.Config

  @tool_modules %{
    "linear_graphql" => LinearGraphQL,
    "org_task" => OrgTask
  }

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(tool, arguments, opts \\ []) do
    case tool_module(tool) do
      nil ->
        Response.failure(%{
          "error" => %{
            "message" => "Unsupported dynamic tool: #{inspect(tool)}.",
            "supportedTools" => supported_tool_names()
          }
        })

      module ->
        module.execute(arguments, opts)
    end
  end

  @spec tool_specs() :: [map()]
  def tool_specs do
    case Config.tracker_kind() do
      "orgmode" -> [OrgTask.tool_spec()]
      _ -> [LinearGraphQL.tool_spec()]
    end
  end

  defp tool_module(tool) when is_binary(tool), do: Map.get(@tool_modules, tool)
  defp tool_module(_tool), do: nil

  defp supported_tool_names do
    Enum.map(tool_specs(), & &1["name"])
  end
end
