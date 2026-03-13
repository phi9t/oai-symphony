defmodule SymphonyElixir.ConfigLoaderTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.{Access, Loader}

  test "loader parses schema-facing workflow settings from current workflow data" do
    current_workflow = {:ok, %{config: %{"tracker" => %{"kind" => "org"}, "polling" => %{"interval_ms" => 45_000}}}}

    assert {:ok, settings} = Loader.settings(current_workflow)
    assert settings.tracker.kind == "orgmode"
    assert settings.polling.interval_ms == 45_000
  end

  test "loader returns the default prompt template when prompt_template is blank" do
    default_prompt = "default prompt"
    current_workflow = {:ok, %{prompt_template: "   "}}

    assert Loader.workflow_prompt(current_workflow, default_prompt) == default_prompt
  end

  test "access resolves env-backed paths and normalizes secrets and states" do
    previous = System.get_env("REV12_CONFIG_ACCESS_PATH")

    on_exit(fn ->
      restore_env("REV12_CONFIG_ACCESS_PATH", previous)
    end)

    System.put_env("REV12_CONFIG_ACCESS_PATH", "/tmp/rev12-config-access")

    assert Access.resolve_path_value("$REV12_CONFIG_ACCESS_PATH", nil) == "/tmp/rev12-config-access"
    assert Access.normalize_secret_value("  token  ") == "token"
    assert Access.normalize_issue_state(" In Progress ") == "in progress"
  end

  test "loader normalizes mixed config keys and formats config errors" do
    current_workflow =
      {:ok,
       %{
         config: %{
           tracker: %{
             kind: "  ORG ",
             active_states: [" Todo ", nil, true, 7, 1.5, :done, ""],
             terminal_states: [" Done ", nil]
           },
           polling: :invalid,
           workspace: [],
           codex: %{turn_sandbox_policy: "invalid"},
           hooks: %{},
           observability: %{},
           server: %{}
         }
       }}

    assert {:ok, settings} = Loader.settings(current_workflow)
    assert settings.tracker.kind == "orgmode"
    assert settings.tracker.active_states == ["Todo", "true", "7", "1.5", "done"]
    assert settings.tracker.terminal_states == ["Done"]
    assert settings.codex.turn_sandbox_policy == nil

    assert Loader.settings(:missing) == Loader.settings({:ok, %{}})
    assert Loader.settings({:error, :boom}) == {:error, :boom}
    assert Loader.workflow_prompt({:ok, %{prompt_template: "prompt"}}, "default") == "prompt"
    assert Loader.workflow_prompt(:missing, "default") == "default"

    assert Loader.format_config_error({:invalid_workflow_config, "bad"}) =~ "Invalid WORKFLOW.md config: bad"
    assert Loader.format_config_error({:missing_workflow_file, "/tmp/WORKFLOW.md", :enoent}) =~ "Missing WORKFLOW.md"
    assert Loader.format_config_error({:workflow_parse_error, :bad_yaml}) =~ "Failed to parse WORKFLOW.md"
    assert Loader.format_config_error(:workflow_front_matter_not_a_map) =~ "front matter must decode"
    assert Loader.format_config_error(:other) =~ "Invalid WORKFLOW.md config"
  end

  test "loader handles blank or non-binary tracker kinds and unsupported list values" do
    blank_kind_workflow = {:ok, %{config: %{tracker: %{kind: "   ", active_states: [%{}]}}}}
    non_binary_kind_workflow = {:ok, %{config: %{tracker: %{kind: 1}}}}

    assert {:ok, blank_settings} = Loader.settings(blank_kind_workflow)
    assert blank_settings.tracker.kind == nil
    assert blank_settings.tracker.active_states == []

    assert {:ok, non_binary_settings} = Loader.settings(non_binary_kind_workflow)
    assert non_binary_settings.tracker.kind == nil
  end

  test "access resolves env values, preserves commands, and detects emacsclient availability" do
    previous_empty = System.get_env("REV12_EMPTY_ENV")
    previous_full = System.get_env("REV12_FULL_ENV")
    previous_path = System.get_env("PATH")
    command_path = Path.join(System.tmp_dir!(), "rev12-emacsclient-#{System.unique_integer([:positive])}")

    on_exit(fn ->
      restore_env("REV12_EMPTY_ENV", previous_empty)
      restore_env("REV12_FULL_ENV", previous_full)
      restore_env("PATH", previous_path)
      File.rm(command_path)
    end)

    System.put_env("REV12_EMPTY_ENV", "")
    System.put_env("REV12_FULL_ENV", "value")
    File.write!(command_path, "#!/bin/sh\nexit 0\n")
    File.chmod!(command_path, 0o755)

    assert Access.resolve_path_value(:missing, "/fallback") == "/fallback"
    assert Access.resolve_path_value(123, "/fallback") == "/fallback"
    assert Access.resolve_path_value(" relative/path ", nil) == Path.expand("relative/path")
    assert Access.resolve_path_value("emacsclient", nil) == "emacsclient"
    assert Access.resolve_path_value("https://example.test/tool", nil) == "https://example.test/tool"
    assert Access.resolve_path_value("$REV12_EMPTY_ENV", "/fallback") == "/fallback"

    assert Access.resolve_env_value(:missing, "/fallback") == "/fallback"
    assert Access.resolve_env_value("$REV12_FULL_ENV", "/fallback") == "value"
    assert Access.resolve_env_value("$REV12_EMPTY_ENV", "/fallback") == nil
    assert Access.resolve_env_value("$REV12_MISSING_ENV", "/fallback") == "/fallback"
    assert Access.resolve_env_value(" literal ", "/fallback") == "literal"
    assert Access.resolve_env_value(123, "/fallback") == "/fallback"

    assert Access.normalize_secret_value("   ") == nil
    assert Access.normalize_secret_value(:nope) == nil
    assert Access.normalize_issue_state(nil) == ""
    assert Access.org_emacsclient_available?(command_path)
    assert Access.org_emacsclient_available?("sh")
    refute Access.org_emacsclient_available?("\"\" arg")
    refute Access.org_emacsclient_available?("")
    refute Access.org_emacsclient_available?("\"unterminated")
    refute Access.org_emacsclient_available?(nil)
  end
end
