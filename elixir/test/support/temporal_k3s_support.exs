defmodule SymphonyElixir.TestSupport.TemporalK3s do
  import ExUnit.Assertions

  alias SymphonyElixir.Config
  alias SymphonyElixir.Tracker.Issue

  defmodule FakeOrgClient do
    def fetch_candidate_issues, do: {:ok, []}
    def fetch_issues_by_states(_states), do: {:ok, []}
    def fetch_issue_states_by_ids(_issue_ids), do: {:ok, []}
    def get_task(issue_id), do: {:ok, %{id: issue_id}}

    def get_workpad(issue_id) do
      send(self(), {:org_get_workpad_called, issue_id})
      {:ok, "workpad for #{issue_id}"}
    end

    def replace_workpad(issue_id, content) do
      send(self(), {:org_replace_workpad_called, issue_id, content})
      {:ok, content}
    end

    def set_task_state(issue_id, state_name) do
      send(self(), {:org_set_task_state_called, issue_id, state_name})
      {:ok, %{id: issue_id, state: state_name}}
    end
  end

  defmodule FakeOrgStateFailureClient do
    def fetch_candidate_issues, do: {:ok, []}
    def fetch_issues_by_states(_states), do: {:ok, []}
    def fetch_issue_states_by_ids(_issue_ids), do: {:ok, []}
    def get_task(issue_id), do: {:ok, %{id: issue_id}}

    def get_workpad(issue_id) do
      send(self(), {:org_get_workpad_called, issue_id})
      {:ok, "workpad for #{issue_id}"}
    end

    def replace_workpad(issue_id, content) do
      send(self(), {:org_replace_workpad_called, issue_id, content})
      {:ok, content}
    end

    def set_task_state(issue_id, state_name) do
      send(self(), {:org_set_task_state_called, issue_id, state_name})
      {:error, :org_write_failed}
    end
  end

  defmodule FakeOrgWorkpadFailureClient do
    def fetch_candidate_issues, do: {:ok, []}
    def fetch_issues_by_states(_states), do: {:ok, []}
    def fetch_issue_states_by_ids(_issue_ids), do: {:ok, []}
    def get_task(issue_id), do: {:ok, %{id: issue_id}}

    def get_workpad(issue_id) do
      send(self(), {:org_get_workpad_called, issue_id})
      {:ok, "workpad for #{issue_id}"}
    end

    def replace_workpad(issue_id, content) do
      send(self(), {:org_replace_workpad_called, issue_id, content})
      {:error, :org_workpad_write_failed}
    end

    def set_task_state(issue_id, state_name) do
      send(self(), {:org_set_task_state_called, issue_id, state_name})
      {:ok, %{id: issue_id, state: state_name}}
    end
  end

  defmodule StatefulRetryOrgClient do
    def fetch_candidate_issues do
      {:ok, filter_issues(issue_entries(), Config.tracker_active_states())}
    end

    def fetch_issues_by_states(states) do
      {:ok, filter_issues(issue_entries(), states)}
    end

    def fetch_issue_states_by_ids(issue_ids) do
      wanted_ids = MapSet.new(issue_ids)

      {:ok,
       Enum.filter(issue_entries(), fn %Issue{id: id} ->
         MapSet.member?(wanted_ids, id)
       end)}
    end

    def get_task(issue_id), do: {:ok, %{id: issue_id}}

    def get_workpad(issue_id) do
      notify({:org_get_workpad_called, issue_id})
      {:ok, "workpad for #{issue_id}"}
    end

    def replace_workpad(issue_id, content) do
      notify({:org_replace_workpad_called, issue_id, content})
      {:ok, content}
    end

    def set_task_state(issue_id, state_name) do
      Agent.update(store(), fn issues ->
        Enum.map(issues, fn
          %Issue{id: ^issue_id} = issue -> %{issue | state: state_name}
          issue -> issue
        end)
      end)

      notify({:org_set_task_state_called, issue_id, state_name})
      {:ok, %{id: issue_id, state: state_name}}
    end

    defp issue_entries do
      Agent.get(store(), & &1)
    end

    defp filter_issues(issues, states) do
      normalized_states =
        states
        |> Enum.map(&normalize_state/1)
        |> MapSet.new()

      Enum.filter(issues, fn %Issue{state: state} ->
        MapSet.member?(normalized_states, normalize_state(state))
      end)
    end

    defp normalize_state(state) when is_binary(state) do
      state
      |> String.trim()
      |> String.downcase()
    end

    defp normalize_state(_state), do: ""

    defp store do
      Application.fetch_env!(:symphony_elixir, :temporal_retry_issue_store)
    end

    defp notify(message) do
      case Application.get_env(:symphony_elixir, :temporal_retry_test_recipient) do
        pid when is_pid(pid) -> send(pid, message)
        _ -> :ok
      end
    end
  end

  @spec assert_temporal_status_update(map(), String.t(), String.t()) :: true
  def assert_temporal_status_update(update, expected_status, expected_run_id) do
    assert update.event == :notification
    assert update.execution_backend == "temporal_k3s"
    assert update.workflow_id == "issue/issue-remote"
    assert update.workflow_run_id == expected_run_id
    assert update.payload.method == "temporal/status"
    assert update.payload.params["status"] == expected_status
    assert update.payload.params["runId"] == expected_run_id
  end

  @spec assert_temporal_connection_payload(map()) :: true
  def assert_temporal_connection_payload(payload) do
    assert temporal_connection_payload?(payload)
  end

  @spec orchestrated_retry_run_events(String.t()) :: {:ok, [map()]} | :pending
  def orchestrated_retry_run_events(trace_path) do
    if File.exists?(trace_path) do
      runs =
        trace_path
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.map(&Jason.decode!/1)
        |> Enum.filter(&(&1["event"] == "run"))

      if length(runs) >= 2 do
        {:ok, Enum.take(runs, 2)}
      else
        :pending
      end
    else
      :pending
    end
  end

  @spec assert_eventually((-> boolean()), pos_integer()) :: true
  def assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(25)
      assert_eventually(fun, attempts - 1)
    end
  end

  def assert_eventually(_fun, 0), do: ExUnit.Assertions.flunk("condition not met in time")

  @spec temporal_connection_payload?(map()) :: boolean()
  def temporal_connection_payload?(payload) do
    Map.take(payload["temporal"] || %{}, ["address", "namespace"]) == %{
      "address" => "temporal.example:7233",
      "namespace" => "customer-a"
    }
  end
end
