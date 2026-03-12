defmodule SymphonyElixir.Codex.DynamicToolLinearGraphqlTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.DynamicTool.LinearGraphQL

  test "tool_spec exposes the linear GraphQL contract" do
    assert %{
             "name" => "linear_graphql",
             "inputSchema" => %{"required" => ["query"]}
           } = LinearGraphQL.tool_spec()

    assert LinearGraphQL.tool_name() == "linear_graphql"
  end

  test "execute returns GraphQL responses through the response wrapper" do
    response =
      LinearGraphQL.execute(
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts ->
          {:ok, %{"data" => %{"viewer" => %{"id" => "usr_1"}}}}
        end
      )

    assert response["success"] == true
  end

  test "execute accepts bare query strings and surfaces common client failures" do
    response =
      LinearGraphQL.execute(" query Viewer { viewer { id } } ",
        linear_client: fn query, variables, _opts ->
          assert query == "query Viewer { viewer { id } }"
          assert variables == %{}
          {:ok, %{errors: [%{message: "boom"}]}}
        end
      )

    assert response["success"] == false

    for {reason, expected} <- [
          {:missing_linear_api_token, "missing Linear auth"},
          {{:linear_api_status, 429}, "HTTP 429"},
          {{:linear_api_request, :timeout}, "before receiving a successful response"},
          {:other, "tool execution failed"}
        ] do
      response =
        LinearGraphQL.execute(
          %{"query" => "query Viewer { viewer { id } }"},
          linear_client: fn _query, _variables, _opts -> {:error, reason} end
        )

      assert response["success"] == false
      assert response["contentItems"] |> hd() |> Map.fetch!("text") =~ expected
    end
  end

  test "execute rejects invalid variables before calling Linear" do
    response =
      LinearGraphQL.execute(
        %{"query" => "query Viewer { viewer { id } }", "variables" => "nope"},
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called for invalid variables")
        end
      )

    assert response["success"] == false
  end

  test "execute rejects missing or invalid arguments" do
    assert LinearGraphQL.execute(123)["success"] == false
    assert LinearGraphQL.execute("", linear_client: fn _, _, _ -> flunk("unexpected client call") end)["success"] == false

    assert LinearGraphQL.execute(%{"query" => "   "}, linear_client: fn _, _, _ -> flunk("unexpected client call") end)["success"] ==
             false
  end
end
