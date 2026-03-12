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
  @org_task_actions ~w(get_task set_state get_workpad replace_workpad deep_dive deep_revision)
  @org_task_description """
  Read and update the current Org mode task, capture deep-dive analysis, and revise the Org plan
  by drafting or creating follow-on tasks through Symphony.
  """
  @org_task_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["action"],
    "properties" => %{
      "action" => %{
        "type" => "string",
        "description" => "One of `get_task`, `set_state`, `get_workpad`, `replace_workpad`, `deep_dive`, or `deep_revision`."
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
      },
      "mode" => %{
        "type" => ["string", "null"],
        "description" => "Used with `deep_revision`: `create` adds high-level tasks directly when the plan is clear; `draft` records the proposal for human discussion."
      },
      "summary" => %{
        "type" => ["string", "null"],
        "description" => "Required for `deep_dive` and `deep_revision`. A short summary of the analysis or plan change."
      },
      "details" => %{
        "type" => ["string", "null"],
        "description" => "Optional longer narrative used with `deep_dive`."
      },
      "rationale" => %{
        "type" => ["string", "null"],
        "description" => "Optional planning rationale used with `deep_revision`."
      },
      "uncertainty" => %{
        "type" => ["string", "null"],
        "description" => "Optional uncertainty or discussion note used with `deep_revision`."
      },
      "findings" => %{
        "type" => ["array", "null"],
        "items" => %{"type" => "string"},
        "description" => "Optional bullet findings used with `deep_dive`."
      },
      "risks" => %{
        "type" => ["array", "null"],
        "items" => %{"type" => "string"},
        "description" => "Optional risks used with `deep_dive`."
      },
      "openQuestions" => %{
        "type" => ["array", "null"],
        "items" => %{"type" => "string"},
        "description" => "Optional open questions used with `deep_dive`."
      },
      "recommendations" => %{
        "type" => ["array", "null"],
        "items" => %{"type" => "string"},
        "description" => "Optional recommendations used with `deep_dive`."
      },
      "validation" => %{
        "type" => ["array", "null"],
        "items" => %{"type" => "string"},
        "description" => "Optional validation or verification methods used with planning actions."
      },
      "tasks" => %{
        "type" => ["array", "null"],
        "description" => "Used with `deep_revision`. Each proposed task should be detailed enough to stand on its own.",
        "items" => %{
          "type" => "object",
          "additionalProperties" => false,
          "required" => ["title", "description", "acceptanceCriteria", "priority", "validation"],
          "properties" => %{
            "identifier" => %{
              "type" => ["string", "null"],
              "description" => "Optional explicit task identifier. When omitted, Symphony generates the next identifier."
            },
            "title" => %{
              "type" => "string",
              "description" => "Clear, high-level task title."
            },
            "description" => %{
              "type" => "string",
              "description" => "Detailed task description with enough context to begin implementation."
            },
            "state" => %{
              "type" => ["string", "null"],
              "description" => "Optional initial display state, for example `Backlog` or `Todo`."
            },
            "priority" => %{
              "type" => "integer",
              "description" => "Priority level where 1 is highest and 3 is lowest."
            },
            "labels" => %{
              "type" => ["array", "null"],
              "items" => %{"type" => "string"},
              "description" => "Optional Org tags for the created or drafted task."
            },
            "acceptanceCriteria" => %{
              "type" => "array",
              "items" => %{"type" => "string"},
              "description" => "Required acceptance criteria."
            },
            "validation" => %{
              "type" => "array",
              "items" => %{"type" => "string"},
              "description" => "Required verification steps or validation methods."
            },
            "notes" => %{
              "type" => ["array", "null"],
              "items" => %{"type" => "string"},
              "description" => "Optional notes, risks, or sequencing guidance."
            }
          }
        }
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

  defp run_org_task(%{action: "deep_dive", task_id: task_id, content: content}, org_adapter) do
    org_adapter.deep_dive(task_id, content)
  end

  defp run_org_task(
         %{action: "deep_revision", task_id: task_id, mode: mode, content: content, tasks: tasks},
         org_adapter
       ) do
    org_adapter.deep_revision(task_id, mode, content, tasks)
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

  defp build_org_task_arguments("deep_dive", task_id, arguments) do
    with {:ok, deep_dive} <- normalize_deep_dive(arguments) do
      {:ok,
       %{
         action: "deep_dive",
         task_id: task_id,
         content: format_deep_dive_content(deep_dive)
       }}
    end
  end

  defp build_org_task_arguments("deep_revision", task_id, arguments) do
    with {:ok, mode} <- normalize_org_revision_mode(arguments),
         {:ok, revision} <- normalize_deep_revision(arguments) do
      {:ok,
       %{
         action: "deep_revision",
         task_id: task_id,
         mode: mode,
         content: format_deep_revision_content(mode, revision),
         tasks: Enum.map(revision.tasks, &revision_task_payload/1)
       }}
    end
  end

  defp build_org_task_arguments(action, task_id, _arguments) do
    {:ok, %{action: action, task_id: task_id}}
  end

  defp normalize_org_action(arguments) do
    case Map.get(arguments, "action") || Map.get(arguments, :action) do
      action when action in @org_task_actions ->
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

  defp normalize_deep_dive(arguments) do
    with {:ok, summary} <-
           normalize_required_org_string(arguments, "summary", :missing_org_summary) do
      {:ok,
       %{
         summary: summary,
         details: normalize_optional_org_string(arguments, "details"),
         findings: normalize_string_list(arguments, "findings"),
         risks: normalize_string_list(arguments, "risks"),
         open_questions: normalize_string_list(arguments, "openQuestions"),
         recommendations: normalize_string_list(arguments, "recommendations"),
         validation: normalize_string_list(arguments, "validation")
       }}
    end
  end

  defp normalize_deep_revision(arguments) do
    with {:ok, summary} <-
           normalize_required_org_string(arguments, "summary", :missing_org_summary),
         {:ok, tasks} <- normalize_deep_revision_tasks(arguments) do
      {:ok,
       %{
         summary: summary,
         rationale: normalize_optional_org_string(arguments, "rationale"),
         uncertainty: normalize_optional_org_string(arguments, "uncertainty"),
         validation: normalize_string_list(arguments, "validation"),
         tasks: tasks
       }}
    end
  end

  defp normalize_org_revision_mode(arguments) do
    case Map.get(arguments, "mode") || Map.get(arguments, :mode) do
      mode when mode in ["create", "draft"] ->
        {:ok, mode}

      nil ->
        {:error, :missing_org_revision_mode}

      _ ->
        {:error, :invalid_org_revision_mode}
    end
  end

  defp normalize_deep_revision_tasks(arguments) do
    case Map.get(arguments, "tasks") || Map.get(arguments, :tasks) do
      tasks when is_list(tasks) and tasks != [] ->
        normalize_deep_revision_task_list(tasks)

      _ ->
        {:error, :missing_org_revision_tasks}
    end
  end

  defp normalize_deep_revision_task_list(tasks) do
    tasks
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {task, index}, {:ok, acc} ->
      case normalize_revision_task(task, index) do
        {:ok, normalized_task} -> {:cont, {:ok, [normalized_task | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> finalize_normalized_deep_revision_tasks()
  end

  defp finalize_normalized_deep_revision_tasks({:ok, normalized_tasks}),
    do: {:ok, Enum.reverse(normalized_tasks)}

  defp finalize_normalized_deep_revision_tasks({:error, reason}), do: {:error, reason}

  defp normalize_revision_task(task, index) when is_map(task) do
    with {:ok, title} <-
           normalize_required_org_string(
             task,
             "title",
             {:missing_org_revision_task_field, index, "title"}
           ),
         {:ok, description} <-
           normalize_required_org_string(
             task,
             "description",
             {:missing_org_revision_task_field, index, "description"}
           ),
         {:ok, priority} <- normalize_revision_task_priority(task, index),
         {:ok, acceptance_criteria} <-
           normalize_required_string_list(
             task,
             "acceptanceCriteria",
             {:missing_org_revision_task_field, index, "acceptanceCriteria"}
           ),
         {:ok, validation} <-
           normalize_required_string_list(
             task,
             "validation",
             {:missing_org_revision_task_field, index, "validation"}
           ) do
      {:ok,
       %{
         identifier: normalize_optional_org_string(task, "identifier"),
         title: title,
         state: normalize_optional_org_string(task, "state") || "Backlog",
         priority: priority,
         labels: normalize_string_list(task, "labels"),
         body:
           format_revision_task_body(
             description,
             acceptance_criteria,
             validation,
             normalize_string_list(task, "notes")
           )
       }}
    end
  end

  defp normalize_revision_task(_task, _index), do: {:error, :invalid_org_revision_task}

  defp normalize_revision_task_priority(task, index) do
    case org_argument_value(task, "priority") do
      priority when priority in [1, 2, 3] -> {:ok, priority}
      _ -> {:error, {:invalid_org_revision_task_priority, index}}
    end
  end

  defp normalize_required_org_string(arguments, key, error_reason) do
    case org_argument_value(arguments, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, error_reason}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, error_reason}
    end
  end

  defp normalize_optional_org_string(arguments, key) do
    case org_argument_value(arguments, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  defp normalize_required_string_list(arguments, key, error_reason) do
    values = normalize_string_list(arguments, key)
    if values == [], do: {:error, error_reason}, else: {:ok, values}
  end

  defp normalize_string_list(arguments, key) do
    case org_argument_value(arguments, key) do
      values when is_list(values) ->
        values
        |> Enum.map(fn
          value when is_binary(value) -> String.trim(value)
          value -> to_string(value) |> String.trim()
        end)
        |> Enum.reject(&(&1 == ""))

      _ ->
        []
    end
  end

  defp org_argument_value(arguments, key) when is_map(arguments) and is_binary(key) do
    case Map.fetch(arguments, key) do
      {:ok, value} ->
        value

      :error ->
        case org_argument_atom_key(key) do
          nil -> nil
          atom_key -> Map.get(arguments, atom_key)
        end
    end
  end

  defp org_argument_value(_arguments, _key), do: nil

  defp org_argument_atom_key("action"), do: :action
  defp org_argument_atom_key("acceptanceCriteria"), do: :acceptanceCriteria
  defp org_argument_atom_key("content"), do: :content
  defp org_argument_atom_key("description"), do: :description
  defp org_argument_atom_key("details"), do: :details
  defp org_argument_atom_key("findings"), do: :findings
  defp org_argument_atom_key("identifier"), do: :identifier
  defp org_argument_atom_key("labels"), do: :labels
  defp org_argument_atom_key("mode"), do: :mode
  defp org_argument_atom_key("notes"), do: :notes
  defp org_argument_atom_key("openQuestions"), do: :openQuestions
  defp org_argument_atom_key("priority"), do: :priority
  defp org_argument_atom_key("rationale"), do: :rationale
  defp org_argument_atom_key("recommendations"), do: :recommendations
  defp org_argument_atom_key("risks"), do: :risks
  defp org_argument_atom_key("state"), do: :state
  defp org_argument_atom_key("summary"), do: :summary
  defp org_argument_atom_key("taskId"), do: :taskId
  defp org_argument_atom_key("tasks"), do: :tasks
  defp org_argument_atom_key("title"), do: :title
  defp org_argument_atom_key("uncertainty"), do: :uncertainty
  defp org_argument_atom_key("validation"), do: :validation
  defp org_argument_atom_key(_key), do: nil

  defp format_deep_dive_content(deep_dive) do
    [
      format_named_section("Summary", deep_dive.summary),
      format_named_section("Details", deep_dive.details),
      format_bullet_section("Findings", deep_dive.findings),
      format_bullet_section("Risks", deep_dive.risks),
      format_bullet_section("Open Questions", deep_dive.open_questions),
      format_bullet_section("Recommendations", deep_dive.recommendations),
      format_bullet_section("Validation / Verification", deep_dive.validation)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp format_deep_revision_content(mode, revision) do
    [
      format_named_section("Revision Summary", revision.summary),
      format_named_section(
        "Mode",
        if(mode == "create",
          do: "Create clear follow-on tasks directly.",
          else: "Draft proposed tasks for human discussion."
        )
      ),
      format_named_section("Rationale", revision.rationale),
      format_named_section("Uncertainty", revision.uncertainty),
      format_bullet_section("Validation / Verification", revision.validation),
      format_bullet_section(
        "Proposed Tasks",
        Enum.map(revision.tasks, &format_revision_task_summary/1)
      )
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp format_revision_task_body(description, acceptance_criteria, validation, notes) do
    [
      description,
      format_bullet_section("Acceptance Criteria", acceptance_criteria),
      format_bullet_section("Validation / Verification", validation),
      format_bullet_section("Notes", notes)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp revision_task_payload(task) do
    %{
      "identifier" => task.identifier,
      "title" => task.title,
      "state" => task.state,
      "priority" => task.priority,
      "labels" => task.labels,
      "body" => task.body
    }
  end

  defp format_revision_task_summary(task) do
    priority = task.priority || 2
    identifier = task.identifier || "auto"
    "#{identifier} | #{task.title} | state: #{task.state} | priority: #{priority}"
  end

  defp format_named_section(_heading, nil), do: nil
  defp format_named_section(_heading, ""), do: nil

  defp format_named_section(heading, content) do
    "### #{heading}\n#{content}"
  end

  defp format_bullet_section(_heading, []), do: nil

  defp format_bullet_section(heading, values) do
    "### #{heading}\n" <>
      Enum.map_join(values, "\n", fn value -> "- #{value}" end)
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
        "message" => "`org_task.action` must be one of `get_task`, `set_state`, `get_workpad`, `replace_workpad`, `deep_dive`, or `deep_revision`."
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

  defp tool_error_payload(:missing_org_summary) do
    %{
      "error" => %{
        "message" => "`org_task.summary` is required for `deep_dive` and `deep_revision`."
      }
    }
  end

  defp tool_error_payload(:missing_org_revision_mode) do
    %{
      "error" => %{
        "message" => "`org_task.mode` is required for `deep_revision` and must be `create` or `draft`."
      }
    }
  end

  defp tool_error_payload(:invalid_org_revision_mode) do
    %{
      "error" => %{
        "message" => "`org_task.mode` must be `create` or `draft`."
      }
    }
  end

  defp tool_error_payload(:missing_org_revision_tasks) do
    %{
      "error" => %{
        "message" => "`org_task.tasks` must contain at least one detailed task when using `deep_revision`."
      }
    }
  end

  defp tool_error_payload(:invalid_org_revision_task) do
    %{
      "error" => %{
        "message" => "Each `org_task.tasks[]` entry must be an object."
      }
    }
  end

  defp tool_error_payload({:missing_org_revision_task_field, index, field}) do
    %{
      "error" => %{
        "message" => "`org_task.tasks[#{index - 1}].#{field}` is required so drafted or created tasks stay actionable."
      }
    }
  end

  defp tool_error_payload({:invalid_org_revision_task_priority, index}) do
    %{
      "error" => %{
        "message" => "`org_task.tasks[#{index - 1}].priority` must be 1, 2, or 3."
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
        "message" => "Org task execution through `tracker.emacsclient_command` failed.",
        "status" => status,
        "output" => output
      }
    }
  end

  defp tool_error_payload({:org_emacsclient_failed, reason}) do
    %{
      "error" => %{
        "message" => "Org task execution through `tracker.emacsclient_command` failed.",
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
