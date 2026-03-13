defmodule SymphonyElixir.Codex.DynamicTool.OrgTask do
  @moduledoc false

  alias SymphonyElixir.Codex.DynamicTool.Response
  alias SymphonyElixir.Org.Adapter

  @tool_name "org_task"
  @actions ~w(get_task set_state get_workpad replace_workpad deep_dive deep_revision)
  @description """
  Read and update the current Org mode task, capture deep-dive analysis, and revise the Org plan
  by drafting or creating follow-on tasks through Symphony.
  """
  @input_schema %{
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
  @org_argument_atom_keys %{
    "action" => :action,
    "acceptanceCriteria" => :acceptanceCriteria,
    "content" => :content,
    "description" => :description,
    "details" => :details,
    "findings" => :findings,
    "identifier" => :identifier,
    "labels" => :labels,
    "mode" => :mode,
    "notes" => :notes,
    "openQuestions" => :openQuestions,
    "priority" => :priority,
    "rationale" => :rationale,
    "recommendations" => :recommendations,
    "risks" => :risks,
    "state" => :state,
    "summary" => :summary,
    "taskId" => :taskId,
    "tasks" => :tasks,
    "title" => :title,
    "uncertainty" => :uncertainty,
    "validation" => :validation
  }

  @spec tool_name() :: String.t()
  def tool_name, do: @tool_name

  @spec tool_spec() :: map()
  def tool_spec do
    %{
      "name" => @tool_name,
      "description" => @description,
      "inputSchema" => @input_schema
    }
  end

  @spec execute(term(), keyword()) :: map()
  def execute(arguments, opts \\ []) do
    org_adapter = Keyword.get(opts, :org_adapter, Adapter)

    with {:ok, normalized} <- normalize_arguments(arguments, opts),
         {:ok, response} <- run_org_task(normalized, org_adapter) do
      Response.success(response)
    else
      {:error, reason} ->
        Response.failure(error_payload(reason))
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

  defp normalize_arguments(arguments, opts) when is_map(arguments) do
    with {:ok, action} <- normalize_org_action(arguments),
         {:ok, task_id} <- normalize_org_task_id(arguments, opts) do
      build_org_task_arguments(action, task_id, arguments)
    end
  end

  defp normalize_arguments(_arguments, _opts), do: {:error, :invalid_org_arguments}

  defp build_org_task_arguments("set_state", task_id, arguments) do
    case normalize_org_state(arguments) do
      {:ok, state} -> {:ok, %{action: "set_state", task_id: task_id, state: state}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_org_task_arguments("replace_workpad", task_id, arguments) do
    case normalize_org_content(arguments) do
      {:ok, content} -> {:ok, %{action: "replace_workpad", task_id: task_id, content: content}}
      {:error, reason} -> {:error, reason}
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
      action when action in @actions -> {:ok, action}
      _ -> {:error, :invalid_org_action}
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
    with {:ok, summary} <- normalize_required_org_string(arguments, "summary", :missing_org_summary) do
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
    with {:ok, summary} <- normalize_required_org_string(arguments, "summary", :missing_org_summary),
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
      mode when mode in ["create", "draft"] -> {:ok, mode}
      nil -> {:error, :missing_org_revision_mode}
      _ -> {:error, :invalid_org_revision_mode}
    end
  end

  defp normalize_deep_revision_tasks(arguments) do
    case Map.get(arguments, "tasks") || Map.get(arguments, :tasks) do
      tasks when is_list(tasks) and tasks != [] ->
        normalize_revision_task_list(tasks)

      _ ->
        {:error, :missing_org_revision_tasks}
    end
  end

  defp normalize_revision_task_list(tasks) do
    tasks
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {task, index}, {:ok, acc} ->
      append_revision_task(acc, task, index)
    end)
    |> case do
      {:ok, normalized_tasks} -> {:ok, Enum.reverse(normalized_tasks)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp append_revision_task(acc, task, index) do
    case normalize_revision_task(task, index) do
      {:ok, normalized_task} -> {:cont, {:ok, [normalized_task | acc]}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp normalize_revision_task(task, index) when is_map(task) do
    with {:ok, title} <-
           normalize_required_org_string(task, "title", {:missing_org_revision_task_field, index, "title"}),
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
          value -> value |> to_string() |> String.trim()
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
        Map.get(arguments, Map.get(@org_argument_atom_keys, key))
    end
  end

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
      format_bullet_section("Proposed Tasks", Enum.map(revision.tasks, &format_revision_task_summary/1))
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

  defp format_named_section(heading, content) do
    if content in [nil, ""] do
      nil
    else
      "### #{heading}\n#{content}"
    end
  end

  defp format_bullet_section(_heading, []), do: nil

  defp format_bullet_section(heading, values) do
    "### #{heading}\n" <> Enum.map_join(values, "\n", fn value -> "- #{value}" end)
  end

  defp issue_id_from_opts(opts) do
    case Keyword.get(opts, :issue) do
      %{id: issue_id} when is_binary(issue_id) -> issue_id
      _ -> nil
    end
  end

  defp error_payload(:invalid_org_arguments) do
    %{
      "error" => %{
        "message" => "`org_task` expects an object with an `action` field."
      }
    }
  end

  defp error_payload(:invalid_org_action) do
    %{
      "error" => %{
        "message" => "`org_task.action` must be one of `get_task`, `set_state`, `get_workpad`, `replace_workpad`, `deep_dive`, or `deep_revision`."
      }
    }
  end

  defp error_payload(:missing_org_task_id) do
    %{
      "error" => %{
        "message" => "`org_task` requires `taskId` unless the current issue context is available."
      }
    }
  end

  defp error_payload(:missing_org_state) do
    %{
      "error" => %{
        "message" => "`org_task.state` is required for `set_state`."
      }
    }
  end

  defp error_payload(:missing_org_content) do
    %{
      "error" => %{
        "message" => "`org_task.content` is required for `replace_workpad`."
      }
    }
  end

  defp error_payload(:missing_org_summary) do
    %{
      "error" => %{
        "message" => "`org_task.summary` is required for `deep_dive` and `deep_revision`."
      }
    }
  end

  defp error_payload(:missing_org_revision_mode) do
    %{
      "error" => %{
        "message" => "`org_task.mode` is required for `deep_revision` and must be `create` or `draft`."
      }
    }
  end

  defp error_payload(:invalid_org_revision_mode) do
    %{
      "error" => %{
        "message" => "`org_task.mode` must be `create` or `draft`."
      }
    }
  end

  defp error_payload(:missing_org_revision_tasks) do
    %{
      "error" => %{
        "message" => "`org_task.tasks` must contain at least one detailed task when using `deep_revision`."
      }
    }
  end

  defp error_payload(:invalid_org_revision_task) do
    %{
      "error" => %{
        "message" => "Each `org_task.tasks[]` entry must be an object."
      }
    }
  end

  defp error_payload({:missing_org_revision_task_field, index, field}) do
    %{
      "error" => %{
        "message" => "`org_task.tasks[#{index - 1}].#{field}` is required so drafted or created tasks stay actionable."
      }
    }
  end

  defp error_payload({:invalid_org_revision_task_priority, index}) do
    %{
      "error" => %{
        "message" => "`org_task.tasks[#{index - 1}].priority` must be 1, 2, or 3."
      }
    }
  end

  defp error_payload(:org_task_not_found) do
    %{
      "error" => %{
        "message" => "The requested Org task was not found under the configured Symphony subtree."
      }
    }
  end

  defp error_payload(:org_root_not_found) do
    %{
      "error" => %{
        "message" => "The configured Org tracker root heading could not be found."
      }
    }
  end

  defp error_payload(:org_state_not_found) do
    %{
      "error" => %{
        "message" => "The requested Org state is not mapped in `tracker.state_map`."
      }
    }
  end

  defp error_payload({:org_emacsclient_failed, status, output}) do
    %{
      "error" => %{
        "message" => "Org task execution through `emacsclient` failed.",
        "status" => status,
        "output" => output
      }
    }
  end

  defp error_payload({:org_emacsclient_failed, reason}) do
    %{
      "error" => %{
        "message" => "Org task execution through `emacsclient` failed.",
        "reason" => reason
      }
    }
  end

  defp error_payload({:org_error, reason}) do
    %{
      "error" => %{
        "message" => "Org task tool execution failed.",
        "reason" => reason
      }
    }
  end

  defp error_payload(reason) do
    %{
      "error" => %{
        "message" => "Dynamic tool execution failed.",
        "reason" => inspect(reason)
      }
    }
  end
end
