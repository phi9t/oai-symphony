defmodule SymphonyElixir.AppServerTransportTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.AppServer.Transport

  defp open_sink_port! do
    assert {:ok, port} = Transport.start_port(System.tmp_dir!(), "cat >/dev/null")

    on_exit(fn ->
      Transport.stop_port(port)
    end)

    port
  end

  test "start_port reports a missing bash executable" do
    previous_path = System.get_env("PATH")

    on_exit(fn ->
      restore_env("PATH", previous_path)
    end)

    System.put_env("PATH", "")

    assert {:error, :bash_not_found} = Transport.start_port(System.tmp_dir!(), "true")
  end

  test "port metadata and stop_port handle open and closed ports" do
    port = open_sink_port!()

    assert %{codex_app_server_pid: pid} = Transport.port_metadata(port)
    assert is_binary(pid)

    assert :ok = Transport.stop_port(port)
    assert :ok = Transport.stop_port(port)
    assert Transport.port_metadata(port) == %{}
  end

  test "await_response handles streamed results, ignored JSON, and non-json output" do
    port = open_sink_port!()

    send(self(), {port, {:data, {:eol, "plain output"}}})
    send(self(), {port, {:data, {:eol, Jason.encode!(%{"id" => 999, "result" => %{"skip" => true}})}}})
    send(self(), {port, {:data, {:noeol, ~s({"id":42,"result":{"ok":true})}}})
    send(self(), {port, {:data, {:eol, "}"}}})

    assert {:ok, %{"ok" => true}} = Transport.await_response(port, 42, 50)
  end

  test "await_response returns response errors and timeout conditions" do
    error_port = open_sink_port!()
    send(self(), {error_port, {:data, {:eol, Jason.encode!(%{"id" => 7, "error" => %{"message" => "boom"}})}}})
    assert {:error, {:response_error, %{"message" => "boom"}}} = Transport.await_response(error_port, 7, 50)

    payload_port = open_sink_port!()
    send(self(), {payload_port, {:data, {:eol, Jason.encode!(%{"id" => 8, "status" => "odd"})}}})
    assert {:error, {:response_error, %{"id" => 8, "status" => "odd"}}} = Transport.await_response(payload_port, 8, 50)

    timeout_port = open_sink_port!()
    assert {:error, :response_timeout} = Transport.await_response(timeout_port, 9, 0)
  end

  test "await_response handles warning stream lines and port exits" do
    warning_port = open_sink_port!()
    send(self(), {warning_port, {:data, {:eol, "warning: slow response"}}})
    send(self(), {warning_port, {:data, {:eol, Jason.encode!(%{"id" => 10, "result" => %{"ok" => true}})}}})
    assert {:ok, %{"ok" => true}} = Transport.await_response(warning_port, 10, 50)

    exit_port = open_sink_port!()
    send(self(), {exit_port, {:exit_status, 9}})
    assert {:error, {:port_exit, 9}} = Transport.await_response(exit_port, 11, 50)
  end
end
