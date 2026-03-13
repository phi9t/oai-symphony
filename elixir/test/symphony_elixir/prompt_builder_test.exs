defmodule SymphonyElixir.PromptBuilderTest do
  use SymphonyElixir.TestSupport

  import SymphonyElixir.TestSupport.Scenarios, only: [issue_fixture: 1]

  test "prompt builder renders issue and attempt values from workflow template" do
    workflow_prompt =
      "Ticket {{ issue.identifier }} {{ issue.title }} labels={{ issue.labels }} attempt={{ attempt }}"

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    issue =
      issue_fixture(
        identifier: "S-1",
        title: "Refactor backend request path",
        description: "Replace transport layer",
        state: "Todo",
        labels: ["backend"]
      )

    prompt = PromptBuilder.build_prompt(issue, attempt: 3)

    assert prompt =~ "Ticket S-1 Refactor backend request path"
    assert prompt =~ "labels=backend"
    assert prompt =~ "attempt=3"
  end

  test "prompt builder renders issue datetime fields without crashing" do
    workflow_prompt =
      "Ticket {{ issue.identifier }} created={{ issue.created_at }} updated={{ issue.updated_at }}"

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    created_at = DateTime.from_naive!(~N[2026-02-26 18:06:48], "Etc/UTC")
    updated_at = DateTime.from_naive!(~N[2026-02-26 18:07:03], "Etc/UTC")

    issue =
      issue_fixture(
        identifier: "MT-697",
        title: "Live smoke",
        description: "Prompt should serialize datetimes",
        state: "Todo",
        labels: [],
        created_at: created_at,
        updated_at: updated_at
      )

    prompt = PromptBuilder.build_prompt(issue)

    assert prompt =~ "Ticket MT-697"
    assert prompt =~ "created=2026-02-26T18:06:48Z"
    assert prompt =~ "updated=2026-02-26T18:07:03Z"
  end

  test "prompt builder normalizes nested date-like values, maps, and structs in issue fields" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "Ticket {{ issue.identifier }}")

    issue =
      issue_fixture(
        identifier: "MT-701",
        title: "Serialize nested values",
        description: "Prompt builder should normalize nested terms",
        state: "Todo",
        labels: [
          ~N[2026-02-27 12:34:56],
          ~D[2026-02-28],
          ~T[12:34:56],
          %{phase: "test"},
          URI.parse("https://example.org/issues/MT-701")
        ]
      )

    assert PromptBuilder.build_prompt(issue) == "Ticket MT-701"
  end

  test "prompt builder uses strict variable rendering" do
    workflow_prompt = "Work on ticket {{ missing.ticket_id }} and follow these steps."

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    issue =
      issue_fixture(
        identifier: "MT-123",
        title: "Investigate broken sync",
        description: "Reproduce and fix",
        state: "In Progress",
        labels: ["bug"]
      )

    assert_raise Solid.RenderError, fn ->
      PromptBuilder.build_prompt(issue)
    end
  end

  test "prompt builder surfaces invalid template content with prompt context" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "{% if issue.identifier %}")

    issue =
      issue_fixture(
        identifier: "MT-999",
        title: "Broken prompt",
        description: "Invalid template syntax",
        state: "Todo",
        labels: []
      )

    assert_raise RuntimeError, ~r/template_parse_error:.*template="/s, fn ->
      PromptBuilder.build_prompt(issue)
    end
  end

  test "prompt builder uses a sensible default template when workflow prompt is blank" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "   \n")

    issue =
      issue_fixture(
        identifier: "MT-777",
        title: "Make fallback prompt useful",
        description: "Include enough issue context to start working.",
        state: "In Progress",
        labels: ["prompt"]
      )

    prompt = PromptBuilder.build_prompt(issue)

    assert prompt =~ "You are working on a tracked issue."
    assert prompt =~ "Identifier: MT-777"
    assert prompt =~ "Title: Make fallback prompt useful"
    assert prompt =~ "Body:"
    assert prompt =~ "Include enough issue context to start working."
    assert Config.workflow_prompt() =~ "{{ issue.identifier }}"
    assert Config.workflow_prompt() =~ "{{ issue.title }}"
    assert Config.workflow_prompt() =~ "{{ issue.description }}"
  end

  test "prompt builder default template handles missing issue body" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "")

    issue =
      issue_fixture(
        identifier: "MT-778",
        title: "Handle empty body",
        description: nil,
        state: "Todo",
        labels: []
      )

    prompt = PromptBuilder.build_prompt(issue)

    assert prompt =~ "Identifier: MT-778"
    assert prompt =~ "Title: Handle empty body"
    assert prompt =~ "No description provided."
  end

  test "prompt builder reports workflow load failures separately from template parse errors" do
    original_workflow_path = Workflow.workflow_file_path()
    workflow_store_pid = Process.whereis(SymphonyElixir.WorkflowStore)

    on_exit(fn ->
      Workflow.set_workflow_file_path(original_workflow_path)

      if is_pid(workflow_store_pid) and is_nil(Process.whereis(SymphonyElixir.WorkflowStore)) do
        Supervisor.restart_child(SymphonyElixir.Supervisor, SymphonyElixir.WorkflowStore)
      end
    end)

    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.WorkflowStore)

    Workflow.set_workflow_file_path(Path.join(System.tmp_dir!(), "missing-workflow-#{System.unique_integer([:positive])}.md"))

    issue =
      issue_fixture(
        identifier: "MT-780",
        title: "Workflow unavailable",
        description: "Missing workflow file",
        state: "Todo",
        labels: []
      )

    assert_raise RuntimeError, ~r/workflow_unavailable:/, fn ->
      PromptBuilder.build_prompt(issue)
    end
  end

  test "in-repo WORKFLOW.md renders correctly" do
    workflow_path = Workflow.workflow_file_path()
    Workflow.set_workflow_file_path(Path.expand("WORKFLOW.md", File.cwd!()))

    issue =
      issue_fixture(
        identifier: "MT-616",
        title: "Use rich templates for WORKFLOW.md",
        description: "Render with rich template variables",
        state: "In Progress",
        url: "https://example.org/issues/MT-616/use-rich-templates-for-workflowmd",
        labels: ["templating", "workflow"]
      )

    on_exit(fn -> Workflow.set_workflow_file_path(workflow_path) end)

    prompt = PromptBuilder.build_prompt(issue, attempt: 2)

    assert prompt =~ "You are working on an Org task `MT-616`"
    assert prompt =~ "Issue context:"
    assert prompt =~ "Identifier: MT-616"
    assert prompt =~ "Title: Use rich templates for WORKFLOW.md"
    assert prompt =~ "Current status: In Progress"
    assert prompt =~ "https://example.org/issues/MT-616/use-rich-templates-for-workflowmd"
    assert prompt =~ "This is an unattended orchestration session."
    assert prompt =~ "The control plane owns Org updates."
    assert prompt =~ "./.symphony/workpad.md"
    assert prompt =~ "./.symphony/run-result.json"
    assert prompt =~ "targetState"
    assert prompt =~ "Continuation context:"
    assert prompt =~ "retry attempt #2"
  end

  test "prompt builder adds continuation guidance for retries" do
    workflow_prompt = "{% if attempt %}Retry #" <> "{{ attempt }}" <> "{% endif %}"
    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    issue =
      issue_fixture(
        identifier: "MT-201",
        title: "Continue autonomous ticket",
        description: "Retry flow",
        state: "In Progress",
        labels: []
      )

    prompt = PromptBuilder.build_prompt(issue, attempt: 2)

    assert prompt == "Retry #2"
  end
end
