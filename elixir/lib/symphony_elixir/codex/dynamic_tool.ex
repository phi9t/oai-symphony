defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Executes client-side tool calls requested by Codex app-server turns.
  """

  alias SymphonyElixir.{Config, Linear.Client, Org.Adapter}
  alias SymphonyElixir.Tracker.Issue

  @linear_graphql_tool "linear_graphql"
  @linear_graphql_description """
  Execute a raw GraphQL query or mutation against Linear using Symphony's configured auth.
  """
  @linear_graphql_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["query"],
    "properties" => %{
      "query" => %{
        "type" => "string",
        "description" => "GraphQL query or mutation document to execute against Linear."
      },
      "variables" => %{
        "type" => ["object", "null"],
        "description" => "Optional GraphQL variables object.",
        "additionalProperties" => true
      }
    }
  }

  @org_task_tool "org_task"
  @org_task_description """
  Read and update the current Org mode task and its in-heading Codex workpad through Symphony.
  """
  @org_task_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["action"],
    "properties" => %{
      "action" => %{
        "type" => "string",
        "description" => "One of `get_task`, `set_state`, `get_workpad`, or `replace_workpad`."
      },
      "taskId" => %{
        "type" => ["string", "null"],
        "description" => "Optional Org task ID. Defaults to the current issue when omitted."
      },
      "state" => %{
        "type" => ["string", "null"],
        "description" => "Display state name used with `set_state`, for example `In Progress`."
      },
      "content" => %{
        "type" => ["string", "null"],
        "description" => "Replacement workpad content used with `replace_workpad`."
      }
    }
  }

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(tool, arguments, opts \\ []) do
    case tool do
      @linear_graphql_tool ->
        execute_linear_graphql(arguments, opts)

      @org_task_tool ->
        execute_org_task(arguments, opts)

      other ->
        failure_response(%{
          "error" => %{
            "message" => "Unsupported dynamic tool: #{inspect(other)}.",
            "supportedTools" => supported_tool_names()
          }
        })
    end
  end

  @spec tool_specs() :: [map()]
  def tool_specs do
    case Config.tracker_kind() do
      "orgmode" ->
        [
          %{
            "name" => @org_task_tool,
            "description" => @org_task_description,
            "inputSchema" => @org_task_input_schema
          }
        ]

      _ ->
        [
          %{
            "name" => @linear_graphql_tool,
            "description" => @linear_graphql_description,
            "inputSchema" => @linear_graphql_input_schema
          }
        ]
    end
  end

  defp execute_linear_graphql(arguments, opts) do
    linear_client = Keyword.get(opts, :linear_client, &Client.graphql/3)

    with {:ok, query, variables} <- normalize_linear_graphql_arguments(arguments),
         {:ok, response} <- linear_client.(query, variables, []) do
      graphql_response(response)
    else
      {:error, reason} ->
        failure_response(linear_tool_error_payload(reason))
    end
  end

  defp execute_org_task(arguments, opts) do
    org_adapter = Keyword.get(opts, :org_adapter, Adapter)

    with {:ok, normalized} <- normalize_org_task_arguments(arguments, opts),
         {:ok, response} <- run_org_task(normalized, org_adapter) do
      success_response(response)
    else
      {:error, reason} ->
        failure_response(tool_error_payload(reason))
    end
  end

  defp run_org_task(%{action: "get_task", task_id: task_id}, org_adapter) do
    org_adapter.get_task(task_id)
  end

  defp run_org_task(%{action: "set_state", task_id: task_id, state: state}, org_adapter) do
    case org_adapter.update_issue_state(task_id, state) do
      :ok -> org_adapter.get_task(task_id)
      {:error, reason} -> {:error, reason}
    end
  end

  defp run_org_task(%{action: "get_workpad", task_id: task_id}, org_adapter) do
    with {:ok, content} <- org_adapter.get_workpad(task_id) do
      {:ok, %{"taskId" => task_id, "content" => content}}
    end
  end

  defp run_org_task(%{action: "replace_workpad", task_id: task_id, content: content}, org_adapter) do
    with {:ok, updated_content} <- org_adapter.replace_workpad(task_id, content) do
      {:ok, %{"taskId" => task_id, "content" => updated_content}}
    end
  end

  defp normalize_linear_graphql_arguments(arguments) when is_binary(arguments) do
    case String.trim(arguments) do
      "" -> {:error, :missing_query}
      query -> {:ok, query, %{}}
    end
  end

  defp normalize_linear_graphql_arguments(arguments) when is_map(arguments) do
    case normalize_query(arguments) do
      {:ok, query} ->
        case normalize_variables(arguments) do
          {:ok, variables} ->
            {:ok, query, variables}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_linear_graphql_arguments(_arguments), do: {:error, :invalid_arguments}

  defp normalize_org_task_arguments(arguments, opts) when is_map(arguments) do
    with {:ok, action} <- normalize_org_action(arguments),
         {:ok, task_id} <- normalize_org_task_id(arguments, opts) do
      build_org_task_arguments(action, task_id, arguments)
    end
  end

  defp normalize_org_task_arguments(_arguments, _opts), do: {:error, :invalid_org_arguments}

  defp build_org_task_arguments("set_state", task_id, arguments) do
    case normalize_org_state(arguments) do
      {:ok, state} -> {:ok, %{action: "set_state", task_id: task_id, state: state}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_org_task_arguments("replace_workpad", task_id, arguments) do
    case normalize_org_content(arguments) do
      {:ok, content} ->
        {:ok, %{action: "replace_workpad", task_id: task_id, content: content}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_org_task_arguments(action, task_id, _arguments) do
    {:ok, %{action: action, task_id: task_id}}
  end

  defp normalize_org_action(arguments) do
    case Map.get(arguments, "action") || Map.get(arguments, :action) do
      action when action in ["get_task", "set_state", "get_workpad", "replace_workpad"] ->
        {:ok, action}

      _ ->
        {:error, :invalid_org_action}
    end
  end

  defp normalize_org_task_id(arguments, opts) do
    case Map.get(arguments, "taskId") || Map.get(arguments, :taskId) || issue_id_from_opts(opts) do
      task_id when is_binary(task_id) ->
        case String.trim(task_id) do
          "" -> {:error, :missing_org_task_id}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, :missing_org_task_id}
    end
  end

  defp normalize_org_state(arguments) do
    case Map.get(arguments, "state") || Map.get(arguments, :state) do
      state when is_binary(state) ->
        case String.trim(state) do
          "" -> {:error, :missing_org_state}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, :missing_org_state}
    end
  end

  defp normalize_org_content(arguments) do
    case Map.get(arguments, "content") || Map.get(arguments, :content) do
      content when is_binary(content) -> {:ok, content}
      _ -> {:error, :missing_org_content}
    end
  end

  defp issue_id_from_opts(opts) do
    case Keyword.get(opts, :issue) do
      %{id: issue_id} when is_binary(issue_id) -> issue_id
      _ -> nil
    end
  end

  defp normalize_query(arguments) do
    case Map.get(arguments, "query") || Map.get(arguments, :query) do
      query when is_binary(query) ->
        case String.trim(query) do
          "" -> {:error, :missing_query}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, :missing_query}
    end
  end

  defp normalize_variables(arguments) do
    case Map.get(arguments, "variables") || Map.get(arguments, :variables) || %{} do
      variables when is_map(variables) -> {:ok, variables}
      _ -> {:error, :invalid_variables}
    end
  end

  defp graphql_response(response) do
    success =
      case response do
        %{"errors" => errors} when is_list(errors) and errors != [] -> false
        %{errors: errors} when is_list(errors) and errors != [] -> false
        _ -> true
      end

    %{
      "success" => success,
      "contentItems" => [
        %{
          "type" => "inputText",
          "text" => encode_payload(response)
        }
      ]
    }
  end

  defp success_response(payload) do
    %{
      "success" => true,
      "contentItems" => [
        %{
          "type" => "inputText",
          "text" => encode_payload(payload)
        }
      ]
    }
  end

  defp failure_response(payload) do
    %{
      "success" => false,
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

  defp tool_error_payload(:missing_query) do
    %{
      "error" => %{
        "message" => "`linear_graphql` requires a non-empty `query` string."
      }
    }
  end

  defp tool_error_payload(:invalid_arguments) do
    %{
      "error" => %{
        "message" => "`linear_graphql` expects either a GraphQL query string or an object with `query` and optional `variables`."
      }
    }
  end

  defp tool_error_payload(:invalid_variables) do
    %{
      "error" => %{
        "message" => "`linear_graphql.variables` must be a JSON object when provided."
      }
    }
  end

  defp tool_error_payload(:invalid_org_arguments) do
    %{
      "error" => %{
        "message" => "`org_task` expects an object with an `action` field."
      }
    }
  end

  defp tool_error_payload(:invalid_org_action) do
    %{
      "error" => %{
        "message" => "`org_task.action` must be one of `get_task`, `set_state`, `get_workpad`, or `replace_workpad`."
      }
    }
  end

  defp tool_error_payload(:missing_org_task_id) do
    %{
      "error" => %{
        "message" => "`org_task` requires `taskId` unless the current issue context is available."
      }
    }
  end

  defp tool_error_payload(:missing_org_state) do
    %{
      "error" => %{
        "message" => "`org_task.state` is required for `set_state`."
      }
    }
  end

  defp tool_error_payload(:missing_org_content) do
    %{
      "error" => %{
        "message" => "`org_task.content` is required for `replace_workpad`."
      }
    }
  end

  defp tool_error_payload(:org_task_not_found) do
    %{
      "error" => %{
        "message" => "The requested Org task was not found under the configured Symphony subtree."
      }
    }
  end

  defp tool_error_payload(:org_root_not_found) do
    %{
      "error" => %{
        "message" => "The configured Org tracker root heading could not be found."
      }
    }
  end

  defp tool_error_payload(:org_state_not_found) do
    %{
      "error" => %{
        "message" => "The requested Org state is not mapped in `tracker.state_map`."
      }
    }
  end

  defp tool_error_payload({:org_emacsclient_failed, status, output}) do
    %{
      "error" => %{
        "message" => "Org task execution through `emacsclient` failed.",
        "status" => status,
        "output" => output
      }
    }
  end

  defp tool_error_payload({:org_emacsclient_failed, reason}) do
    %{
      "error" => %{
        "message" => "Org task execution through `emacsclient` failed.",
        "reason" => reason
      }
    }
  end

  defp tool_error_payload({:org_error, reason}) do
    %{
      "error" => %{
        "message" => "Org task tool execution failed.",
        "reason" => reason
      }
    }
  end

  defp tool_error_payload(:missing_linear_api_token) do
    %{
      "error" => %{
        "message" => "Symphony is missing Linear auth. Set `linear.api_key` in `WORKFLOW.md` or export `LINEAR_API_KEY`."
      }
    }
  end

  defp tool_error_payload({:linear_api_status, status}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed with HTTP #{status}.",
        "status" => status
      }
    }
  end

  defp tool_error_payload({:linear_api_request, reason}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed before receiving a successful response.",
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload(reason) do
    %{
      "error" => %{
        "message" => "Dynamic tool execution failed.",
        "reason" => inspect(reason)
      }
    }
  end

  defp linear_tool_error_payload(reason) do
    case tool_error_payload(reason) do
      %{"error" => %{"message" => "Dynamic tool execution failed."} = error} ->
        %{
          "error" => Map.put(error, "message", "Linear GraphQL tool execution failed.")
        }

      payload ->
        payload
    end
  end

  defp supported_tool_names do
    Enum.map(tool_specs(), & &1["name"])
  end
end
