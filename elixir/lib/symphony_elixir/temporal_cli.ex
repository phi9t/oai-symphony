defmodule SymphonyElixir.TemporalCli do
  @moduledoc """
  Shells out to the Go Temporal helper for workflow lifecycle operations.
  """

  alias SymphonyElixir.Config

  @spec run(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(payload, opts \\ []) when is_map(payload) do
    invoke("run", payload, opts)
  end

  @spec status(map() | String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def status(%{"workflowId" => workflow_id} = payload, opts) when is_binary(workflow_id) do
    invoke("status", payload, opts)
  end

  def status(workflow_id, opts) when is_binary(workflow_id) do
    invoke("status", %{"workflowId" => workflow_id}, opts)
  end

  @spec cancel(map() | String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def cancel(%{"workflowId" => workflow_id} = payload, opts) when is_binary(workflow_id) do
    invoke("cancel", payload, opts)
  end

  def cancel(workflow_id, opts) when is_binary(workflow_id) do
    invoke("cancel", %{"workflowId" => workflow_id}, opts)
  end

  @spec describe(map() | String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def describe(%{"workflowId" => workflow_id} = payload, opts) when is_binary(workflow_id) do
    invoke("describe", payload, opts)
  end

  def describe(workflow_id, opts) when is_binary(workflow_id) do
    invoke("describe", %{"workflowId" => workflow_id}, opts)
  end

  defp invoke(subcommand, payload, opts) when is_binary(subcommand) and is_map(payload) do
    runner = Keyword.get(opts, :runner, &default_runner/3)
    command = Keyword.get(opts, :command, Config.temporal_helper_command())

    case runner.(command, subcommand, payload) do
      {:ok, output} ->
        decode_output(output)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp default_runner(command, subcommand, payload) do
    payload_path = temp_payload_path(subcommand)

    try do
      File.write!(payload_path, Jason.encode!(payload, pretty: true))

      with {:ok, binary, args} <- parse_command(command) do
        case System.cmd(binary, args ++ [subcommand, "--input", payload_path, "--output", "json"], stderr_to_stdout: true) do
          {output, 0} ->
            {:ok, output}

          {output, status} ->
            {:error, {:temporal_helper_failed, status, String.trim(output)}}
        end
      end
    after
      File.rm(payload_path)
    end
  rescue
    error in [ArgumentError, File.Error] ->
      {:error, {:temporal_helper_failed, Exception.message(error)}}
  end

  defp decode_output(output) when is_binary(output) do
    output
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> List.last()
    |> case do
      nil -> {:error, :missing_temporal_helper_output}
      json -> Jason.decode(json)
    end
  end

  defp parse_command(command) when is_binary(command) do
    case OptionParser.split(command) do
      [binary | args] -> {:ok, binary, args}
      _ -> {:error, :missing_temporal_helper_command}
    end
  rescue
    _error ->
      {:error, :missing_temporal_helper_command}
  end

  defp temp_payload_path(subcommand) do
    unique = System.unique_integer([:positive, :monotonic])
    Path.join(System.tmp_dir!(), "symphony-temporal-#{subcommand}-#{unique}.json")
  end
end
