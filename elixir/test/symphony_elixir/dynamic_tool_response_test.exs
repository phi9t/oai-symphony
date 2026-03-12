defmodule SymphonyElixir.Codex.DynamicToolResponseTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.DynamicTool.Response

  test "response encodes issues, datetimes, and plain fallback payloads" do
    issue = %Issue{id: "issue-1", identifier: "REV-12", title: "Split modules", state: "In Progress"}
    timestamp = DateTime.utc_now()

    response =
      Response.success(%{
        issue: issue,
        generated_at: timestamp
      })

    assert response["success"] == true

    decoded =
      response["contentItems"]
      |> hd()
      |> Map.fetch!("text")
      |> Jason.decode!()

    assert decoded["issue"]["identifier"] == "REV-12"
    assert decoded["generated_at"] == DateTime.to_iso8601(timestamp)

    assert Response.graphql(%{"errors" => [%{"message" => "boom"}]})["success"] == false
    assert Response.graphql(%{errors: [%{message: "boom"}]})["success"] == false
    assert Response.graphql(:plain)["contentItems"] |> hd() |> Map.fetch!("text") =~ ":plain"
  end
end
