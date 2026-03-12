defmodule SymphonyElixir.AppServerProtocolTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.AppServer.{Protocol, Transport}

  defp open_sink_port! do
    assert {:ok, port} = Transport.start_port(System.tmp_dir!(), "cat >/dev/null")

    on_exit(fn ->
      Transport.stop_port(port)
    end)

    port
  end

  defp on_message do
    parent = self()
    fn message -> send(parent, {:protocol_message, message}) end
  end

  defp tool_executor(result \\ %{"success" => true}) do
    parent = self()

    fn tool_name, arguments ->
      send(parent, {:tool_executor_called, tool_name, arguments})
      result
    end
  end

  test "await_turn_completion requires an explicit timeout when called through the default arity" do
    port = open_sink_port!()

    assert_raise KeyError, fn ->
      Protocol.await_turn_completion(port, on_message(), tool_executor(), true)
    end
  end

  test "await_turn_completion handles streamed completed, failed, cancelled, exit, and timeout cases" do
    completed_port = open_sink_port!()
    send(self(), {completed_port, {:data, {:noeol, ~s({"method":"turn/completed")}}})
    send(self(), {completed_port, {:data, {:eol, "}"}}})

    assert {:ok, :turn_completed} =
             Protocol.await_turn_completion(completed_port, on_message(), tool_executor(), true, turn_timeout_ms: 50)

    assert_received {:protocol_message, %{event: :turn_completed}}

    failed_port = open_sink_port!()

    send(
      self(),
      {failed_port, {:data, {:eol, Jason.encode!(%{"method" => "turn/failed", "params" => %{"reason" => "boom"}})}}}
    )

    assert {:error, {:turn_failed, %{"reason" => "boom"}}} =
             Protocol.await_turn_completion(failed_port, on_message(), tool_executor(), true, turn_timeout_ms: 50)

    assert_received {:protocol_message, %{event: :turn_failed}}

    cancelled_port = open_sink_port!()

    send(
      self(),
      {cancelled_port, {:data, {:eol, Jason.encode!(%{"method" => "turn/cancelled", "params" => %{"reason" => "stop"}})}}}
    )

    assert {:error, {:turn_cancelled, %{"reason" => "stop"}}} =
             Protocol.await_turn_completion(cancelled_port, on_message(), tool_executor(), true, turn_timeout_ms: 50)

    assert_received {:protocol_message, %{event: :turn_cancelled}}

    exit_port = open_sink_port!()
    send(self(), {exit_port, {:exit_status, 7}})

    assert {:error, {:port_exit, 7}} =
             Protocol.await_turn_completion(exit_port, on_message(), tool_executor(), true, turn_timeout_ms: 50)

    timeout_port = open_sink_port!()

    assert {:error, :turn_timeout} =
             Protocol.await_turn_completion(timeout_port, on_message(), tool_executor(), true, turn_timeout_ms: 0)
  end

  test "await_turn_completion emits other message, malformed, and notification events" do
    port = open_sink_port!()

    send(self(), {port, {:data, {:eol, Jason.encode!([1, 2, 3])}}})
    send(self(), {port, {:data, {:eol, "plain text"}}})

    send(
      self(),
      {port, {:data, {:eol, Jason.encode!(%{"method" => "item/updated", "usage" => %{"total_tokens" => 3}})}}}
    )

    send(self(), {port, {:data, {:eol, Jason.encode!(%{"method" => "turn/completed"})}}})

    assert {:ok, :turn_completed} =
             Protocol.await_turn_completion(port, on_message(), tool_executor(), true, turn_timeout_ms: 50)

    assert_received {:protocol_message, %{event: :other_message}}
    assert_received {:protocol_message, %{event: :malformed}}
    assert_received {:protocol_message, %{event: :notification, usage: %{"total_tokens" => 3}}}
    assert_received {:protocol_message, %{event: :turn_completed}}
  end

  test "approval request variants auto approve and approval-required requests fail when disabled" do
    auto_port = open_sink_port!()

    for method <- ["execCommandApproval", "applyPatchApproval", "item/fileChange/requestApproval"] do
      send(
        self(),
        {auto_port, {:data, {:eol, Jason.encode!(%{"method" => method, "id" => "#{method}-1"})}}}
      )
    end

    send(self(), {auto_port, {:data, {:eol, Jason.encode!(%{"method" => "turn/completed"})}}})

    assert {:ok, :turn_completed} =
             Protocol.await_turn_completion(auto_port, on_message(), tool_executor(), true, turn_timeout_ms: 50)

    assert_received {:protocol_message, %{event: :approval_auto_approved}}
    assert_received {:protocol_message, %{event: :approval_auto_approved}}
    assert_received {:protocol_message, %{event: :approval_auto_approved}}

    required_port = open_sink_port!()

    send(
      self(),
      {required_port, {:data, {:eol, Jason.encode!(%{"method" => "item/commandExecution/requestApproval", "id" => "approve-1"})}}}
    )

    assert {:error, {:approval_required, %{"id" => "approve-1", "method" => "item/commandExecution/requestApproval"}}} =
             Protocol.await_turn_completion(required_port, on_message(), tool_executor(), false, turn_timeout_ms: 50)

    assert_received {:protocol_message, %{event: :approval_required}}
  end

  test "tool calls complete, fail, and report unsupported tool names or params" do
    success_port = open_sink_port!()

    send(
      self(),
      {success_port,
       {:data,
        {:eol,
         Jason.encode!(%{
           "method" => "item/tool/call",
           "id" => "tool-1",
           "params" => %{"tool" => "linear_graphql", "arguments" => %{"query" => "{ viewer { id } }"}}
         })}}}
    )

    send(self(), {success_port, {:data, {:eol, Jason.encode!(%{"method" => "turn/completed"})}}})

    assert {:ok, :turn_completed} =
             Protocol.await_turn_completion(success_port, on_message(), tool_executor(), true, turn_timeout_ms: 50)

    assert_received {:tool_executor_called, "linear_graphql", %{"query" => "{ viewer { id } }"}}
    assert_received {:protocol_message, %{event: :tool_call_completed}}

    unsupported_params_port = open_sink_port!()

    send(
      self(),
      {unsupported_params_port, {:data, {:eol, Jason.encode!(%{"method" => "item/tool/call", "id" => "tool-2", "params" => "oops"})}}}
    )

    send(self(), {unsupported_params_port, {:data, {:eol, Jason.encode!(%{"method" => "turn/completed"})}}})

    assert {:ok, :turn_completed} =
             Protocol.await_turn_completion(
               unsupported_params_port,
               on_message(),
               tool_executor(%{"success" => false}),
               true,
               turn_timeout_ms: 50
             )

    assert_received {:tool_executor_called, nil, %{}}
    assert_received {:protocol_message, %{event: :unsupported_tool_call}}

    blank_name_port = open_sink_port!()

    send(
      self(),
      {blank_name_port, {:data, {:eol, Jason.encode!(%{"method" => "item/tool/call", "id" => "tool-3", "params" => %{"name" => "   ", "arguments" => %{}}})}}}
    )

    send(self(), {blank_name_port, {:data, {:eol, Jason.encode!(%{"method" => "turn/completed"})}}})

    assert {:ok, :turn_completed} =
             Protocol.await_turn_completion(
               blank_name_port,
               on_message(),
               tool_executor(%{"success" => false}),
               true,
               turn_timeout_ms: 50
             )

    assert_received {:tool_executor_called, nil, %{}}
    assert_received {:protocol_message, %{event: :unsupported_tool_call}}

    non_binary_name_port = open_sink_port!()

    send(
      self(),
      {non_binary_name_port, {:data, {:eol, Jason.encode!(%{"method" => "item/tool/call", "id" => "tool-4", "params" => %{"tool" => 123, "arguments" => %{}}})}}}
    )

    send(self(), {non_binary_name_port, {:data, {:eol, Jason.encode!(%{"method" => "turn/completed"})}}})

    assert {:ok, :turn_completed} =
             Protocol.await_turn_completion(
               non_binary_name_port,
               on_message(),
               tool_executor(%{"success" => false}),
               true,
               turn_timeout_ms: 50
             )

    assert_received {:tool_executor_called, nil, %{}}
    assert_received {:protocol_message, %{event: :unsupported_tool_call}}

    failed_port = open_sink_port!()

    send(
      self(),
      {failed_port,
       {:data,
        {:eol,
         Jason.encode!(%{
           "method" => "item/tool/call",
           "id" => "tool-5",
           "params" => %{"tool" => "linear_graphql", "arguments" => %{}}
         })}}}
    )

    send(self(), {failed_port, {:data, {:eol, Jason.encode!(%{"method" => "turn/completed"})}}})

    assert {:ok, :turn_completed} =
             Protocol.await_turn_completion(
               failed_port,
               on_message(),
               tool_executor(%{"success" => false}),
               true,
               turn_timeout_ms: 50
             )

    assert_received {:tool_executor_called, "linear_graphql", %{}}
    assert_received {:protocol_message, %{event: :tool_call_failed}}
  end

  test "tool input requests auto approve, auto answer, and fail when no answers can be derived" do
    approve_port = open_sink_port!()

    send(
      self(),
      {approve_port,
       {:data,
        {:eol,
         Jason.encode!(%{
           "method" => "item/tool/requestUserInput",
           "id" => "input-1",
           "params" => %{
             "questions" => [
               %{
                 "id" => "q1",
                 "options" => [%{}, %{"label" => " Allow write"}]
               }
             ]
           }
         })}}}
    )

    send(self(), {approve_port, {:data, {:eol, Jason.encode!(%{"method" => "turn/completed"})}}})

    assert {:ok, :turn_completed} =
             Protocol.await_turn_completion(approve_port, on_message(), tool_executor(), true, turn_timeout_ms: 50)

    assert_received {:protocol_message, %{event: :approval_auto_approved}}

    auto_answer_port = open_sink_port!()

    send(
      self(),
      {auto_answer_port,
       {:data,
        {:eol,
         Jason.encode!(%{
           "method" => "item/tool/requestUserInput",
           "id" => "input-2",
           "params" => %{
             "questions" => [
               %{
                 "id" => "q2",
                 "options" => [%{"label" => "Deny"}]
               }
             ]
           }
         })}}}
    )

    send(self(), {auto_answer_port, {:data, {:eol, Jason.encode!(%{"method" => "turn/completed"})}}})

    assert {:ok, :turn_completed} =
             Protocol.await_turn_completion(auto_answer_port, on_message(), tool_executor(), true, turn_timeout_ms: 50)

    assert_received {:protocol_message, %{event: :tool_input_auto_answered}}

    invalid_port = open_sink_port!()

    send(
      self(),
      {invalid_port, {:data, {:eol, Jason.encode!(%{"method" => "item/tool/requestUserInput", "id" => "input-3", "params" => %{}})}}}
    )

    assert {:error, {:turn_input_required, %{"id" => "input-3", "method" => "item/tool/requestUserInput", "params" => %{}}}} =
             Protocol.await_turn_completion(invalid_port, on_message(), tool_executor(), true, turn_timeout_ms: 50)

    assert_received {:protocol_message, %{event: :turn_input_required}}

    empty_questions_port = open_sink_port!()

    send(
      self(),
      {empty_questions_port, {:data, {:eol, Jason.encode!(%{"method" => "item/tool/requestUserInput", "id" => "input-4", "params" => %{"questions" => []}})}}}
    )

    assert {:error, {:turn_input_required, %{"id" => "input-4", "method" => "item/tool/requestUserInput", "params" => %{"questions" => []}}}} =
             Protocol.await_turn_completion(
               empty_questions_port,
               on_message(),
               tool_executor(),
               true,
               turn_timeout_ms: 50
             )

    empty_questions_port = open_sink_port!()

    send(
      self(),
      {empty_questions_port, {:data, {:eol, Jason.encode!(%{"method" => "item/tool/requestUserInput", "id" => "input-4b", "params" => %{"questions" => []}})}}}
    )

    assert {:error, {:turn_input_required, %{"id" => "input-4b", "method" => "item/tool/requestUserInput", "params" => %{"questions" => []}}}} =
             Protocol.await_turn_completion(
               empty_questions_port,
               on_message(),
               tool_executor(),
               false,
               turn_timeout_ms: 50
             )

    missing_id_port = open_sink_port!()

    send(
      self(),
      {missing_id_port,
       {:data,
        {:eol,
         Jason.encode!(%{
           "method" => "item/tool/requestUserInput",
           "id" => "input-5",
           "params" => %{"questions" => [%{"options" => [%{"label" => "Approve Once"}]}]}
         })}}}
    )

    assert {:error, {:turn_input_required, %{"id" => "input-5", "method" => "item/tool/requestUserInput"}}} =
             Protocol.await_turn_completion(missing_id_port, on_message(), tool_executor(), false, turn_timeout_ms: 50)
  end

  test "unhandled turn notifications become input-required failures when payloads request input" do
    payloads = [
      %{"requiresInput" => true},
      %{"needsInput" => true},
      %{"input_required" => true},
      %{"inputRequired" => true},
      %{"type" => "input_required"},
      %{"type" => "needs_input"}
    ]

    Enum.each(payloads, fn payload ->
      port = open_sink_port!()
      send(self(), {port, {:data, {:eol, Jason.encode!(Map.put(payload, "method", "turn/custom"))}}})

      assert {:error, {:turn_input_required, %{"method" => "turn/custom"}}} =
               Protocol.await_turn_completion(port, on_message(), tool_executor(), true, turn_timeout_ms: 50)

      assert_received {:protocol_message, %{event: :turn_input_required}}
    end)
  end

  test "turn input alias methods all surface input-required failures" do
    for method <- [
          "turn/needs_input",
          "turn/need_input",
          "turn/request_input",
          "turn/request_response",
          "turn/provide_input",
          "turn/approval_required"
        ] do
      port = open_sink_port!()
      send(self(), {port, {:data, {:eol, Jason.encode!(%{"method" => method})}}})

      assert {:error, {:turn_input_required, %{"method" => ^method}}} =
               Protocol.await_turn_completion(port, on_message(), tool_executor(), true, turn_timeout_ms: 50)

      assert_received {:protocol_message, %{event: :turn_input_required}}
    end
  end

  test "turn notifications without input markers remain notifications even with non-map params" do
    port = open_sink_port!()
    send(self(), {port, {:data, {:eol, Jason.encode!(%{"method" => "turn/ping", "params" => "ignore"})}}})
    send(self(), {port, {:data, {:eol, Jason.encode!(%{"method" => "turn/completed"})}}})

    assert {:ok, :turn_completed} =
             Protocol.await_turn_completion(port, on_message(), tool_executor(), true, turn_timeout_ms: 50)

    assert_received {:protocol_message, %{event: :notification}}
  end
end
