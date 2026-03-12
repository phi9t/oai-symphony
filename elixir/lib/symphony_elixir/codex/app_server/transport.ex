defmodule SymphonyElixir.Codex.AppServer.Transport do
  @moduledoc false

  require Logger

  @port_line_bytes 1_048_576
  @max_stream_log_bytes 1_000

  @spec start_port(Path.t(), String.t()) :: {:ok, port()} | {:error, term()}
  def start_port(workspace, command) when is_binary(workspace) and is_binary(command) do
    executable = System.find_executable("bash")

    if is_nil(executable) do
      {:error, :bash_not_found}
    else
      port =
        Port.open(
          {:spawn_executable, String.to_charlist(executable)},
          [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: [~c"-lc", String.to_charlist(command)],
            cd: String.to_charlist(workspace),
            line: @port_line_bytes
          ]
        )

      {:ok, port}
    end
  end

  @spec port_metadata(port()) :: map()
  def port_metadata(port) when is_port(port) do
    case :erlang.port_info(port, :os_pid) do
      {:os_pid, os_pid} ->
        %{codex_app_server_pid: to_string(os_pid)}

      _ ->
        %{}
    end
  end

  @spec await_response(port(), integer(), non_neg_integer()) :: {:ok, term()} | {:error, term()}
  def await_response(port, request_id, timeout_ms) when is_integer(timeout_ms) and timeout_ms >= 0 do
    with_timeout_response(port, request_id, timeout_ms, "")
  end

  @spec send_message(port(), map()) :: true
  def send_message(port, message) when is_port(port) and is_map(message) do
    line = Jason.encode!(message) <> "\n"
    Port.command(port, line)
  end

  @spec stop_port(port()) :: :ok
  def stop_port(port) when is_port(port) do
    Port.close(port)
    :ok
  rescue
    ArgumentError ->
      :ok
  end

  defp with_timeout_response(port, request_id, timeout_ms, pending_line) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        complete_line = pending_line <> to_string(chunk)
        handle_response(port, request_id, complete_line, timeout_ms)

      {^port, {:data, {:noeol, chunk}}} ->
        with_timeout_response(port, request_id, timeout_ms, pending_line <> to_string(chunk))

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}
    after
      timeout_ms ->
        {:error, :response_timeout}
    end
  end

  defp handle_response(port, request_id, data, timeout_ms) do
    payload = to_string(data)

    case Jason.decode(payload) do
      {:ok, %{"id" => ^request_id, "error" => error}} ->
        {:error, {:response_error, error}}

      {:ok, %{"id" => ^request_id, "result" => result}} ->
        {:ok, result}

      {:ok, %{"id" => ^request_id} = response_payload} ->
        {:error, {:response_error, response_payload}}

      {:ok, %{} = other} ->
        Logger.debug("Ignoring message while waiting for response: #{inspect(other)}")
        with_timeout_response(port, request_id, timeout_ms, "")

      {:error, _} ->
        log_non_json_stream_line(payload, "response stream")
        with_timeout_response(port, request_id, timeout_ms, "")
    end
  end

  defp log_non_json_stream_line(data, stream_label) do
    text =
      data
      |> to_string()
      |> String.trim()
      |> String.slice(0, @max_stream_log_bytes)

    if text != "" do
      if String.match?(text, ~r/\b(error|warn|warning|failed|fatal|panic|exception)\b/i) do
        Logger.warning("Codex #{stream_label} output: #{text}")
      else
        Logger.debug("Codex #{stream_label} output: #{text}")
      end
    end
  end
end
