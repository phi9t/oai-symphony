defmodule SymphonyElixir.TestSupport.Scenarios do
  alias SymphonyElixir.Tracker.Issue

  @default_issue %{
    id: "issue-1",
    identifier: "MT-1",
    title: "Test issue",
    description: "Test issue description",
    state: "In Progress",
    url: "https://example.org/issues/MT-1",
    labels: []
  }

  @spec temp_dir!(String.t()) :: String.t()
  def temp_dir!(prefix) do
    path =
      Path.join(
        System.tmp_dir!(),
        "#{prefix}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(path)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf(path) end)
    path
  end

  @spec workspace_fixture!(String.t(), keyword()) :: %{
          test_root: String.t(),
          workspace_root: String.t()
        }
  def workspace_fixture!(prefix, opts \\ []) do
    test_root = temp_dir!(prefix)
    workspace_root = Path.join(test_root, Keyword.get(opts, :workspace_dir, "workspaces"))
    File.mkdir_p!(workspace_root)
    %{test_root: test_root, workspace_root: workspace_root}
  end

  @spec temporal_k3s_fixture!(String.t(), keyword()) :: %{
          test_root: String.t(),
          k3s_project_root: String.t()
        }
  def temporal_k3s_fixture!(prefix, opts \\ []) do
    test_root = temp_dir!(prefix)
    k3s_project_root = Path.join(test_root, Keyword.get(opts, :project_dir, "projects"))
    File.mkdir_p!(k3s_project_root)

    if module = Keyword.get(opts, :org_client_module) do
      put_app_env!(:org_client_module, module)
    end

    %{test_root: test_root, k3s_project_root: k3s_project_root}
  end

  @spec template_repo_fixture!(String.t(), map()) :: String.t()
  def template_repo_fixture!(test_root, files \\ %{"README.md" => "# test\n"}) do
    template_repo = Path.join(test_root, "source")
    File.mkdir_p!(template_repo)

    Enum.each(files, fn {relative_path, content} ->
      path = Path.join(template_repo, relative_path)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, content)
    end)

    System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
    System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
    System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
    System.cmd("git", ["-C", template_repo, "add", "."])
    System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])
    template_repo
  end

  @spec codex_transport_fixture!(String.t(), iodata(), keyword()) :: map()
  def codex_transport_fixture!(prefix, script, opts \\ []) do
    %{test_root: test_root, workspace_root: workspace_root} = workspace_fixture!(prefix, opts)
    workspace_name = Keyword.get(opts, :workspace_name, "MT-1")
    workspace = Path.join(workspace_root, workspace_name)
    File.mkdir_p!(workspace)

    codex_binary = Path.join(test_root, Keyword.get(opts, :binary_name, "fake-codex"))
    write_executable!(codex_binary, script)

    trace_file =
      case Keyword.get(opts, :trace_name) do
        nil -> nil
        trace_name -> Path.join(test_root, trace_name)
      end

    if trace_env = Keyword.get(opts, :trace_env) do
      put_env!(trace_env, trace_file || Path.join(test_root, "codex.trace"))
    end

    %{
      test_root: test_root,
      workspace_root: workspace_root,
      workspace: workspace,
      codex_binary: codex_binary,
      trace_file: trace_file
    }
  end

  @spec issue_fixture(keyword() | map()) :: Issue.t()
  def issue_fixture(attrs \\ %{}) do
    attrs =
      case attrs do
        attrs when is_list(attrs) -> Map.new(attrs)
        attrs when is_map(attrs) -> attrs
      end

    struct(Issue, Map.merge(@default_issue, attrs))
  end

  @spec start_agent!(term()) :: pid()
  def start_agent!(initial_state) do
    {:ok, pid} = Agent.start_link(fn -> initial_state end)

    ExUnit.Callbacks.on_exit(fn ->
      if Process.alive?(pid) do
        Agent.stop(pid)
      end
    end)

    pid
  end

  @spec put_env!(String.t(), String.t() | nil) :: :ok
  def put_env!(key, value) do
    previous_value = System.get_env(key)

    ExUnit.Callbacks.on_exit(fn ->
      restore_env(key, previous_value)
    end)

    if is_nil(value) do
      System.delete_env(key)
    else
      System.put_env(key, value)
    end

    :ok
  end

  @spec put_app_env!(atom(), term()) :: :ok
  def put_app_env!(key, value) do
    previous_value = Application.get_env(:symphony_elixir, key)

    ExUnit.Callbacks.on_exit(fn ->
      restore_app_env(key, previous_value)
    end)

    Application.put_env(:symphony_elixir, key, value)
    :ok
  end

  @spec restore_env(String.t(), String.t() | nil) :: :ok
  def restore_env(key, nil) do
    System.delete_env(key)
    :ok
  end

  def restore_env(key, value) do
    System.put_env(key, value)
    :ok
  end

  @spec restore_app_env(atom(), term()) :: :ok
  def restore_app_env(key, nil) do
    Application.delete_env(:symphony_elixir, key)
    :ok
  end

  def restore_app_env(key, value) do
    Application.put_env(:symphony_elixir, key, value)
    :ok
  end

  @spec write_executable!(String.t(), iodata()) :: String.t()
  def write_executable!(path, content) do
    File.write!(path, content)
    File.chmod!(path, 0o755)
    path
  end
end
