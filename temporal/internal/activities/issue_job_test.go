package activities

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"runtime"
	"strings"
	"testing"
	"time"

	"go.temporal.io/sdk/temporal"
)

func TestBuildJobCommandUsesContainerPaths(t *testing.T) {
	input := newTestRunInput(t)

	command, err := buildJobCommand(input)
	if err != nil {
		t.Fatalf("buildJobCommand returned error: %v", err)
	}

	for _, expected := range []string{
		"PROMPT_PATH='/workspace/.symphony/prompt.md'",
		"WORKPAD_PATH='/workspace/.symphony/workpad.md'",
		"RESULT_PATH='/workspace/.symphony/run-result.json'",
		"ISSUE_PATH='/workspace/.symphony/issue.json'",
		"WORKSPACE_PATH='/workspace'",
		"/opt/symphony/k3s/bin/run-agent-job",
	} {
		if !strings.Contains(command, expected) {
			t.Fatalf("expected command to contain %q, got %q", expected, command)
		}
	}

	if strings.Contains(command, input.Paths.WorkspacePath) {
		t.Fatalf("expected command to use container paths instead of host workspace path: %q", command)
	}
}

func TestSjobRunArgsUseConcreteProjectRoot(t *testing.T) {
	input := newTestRunInput(t)
	input.K3s.ProjectRoot = filepath.Join(t.TempDir(), "global-root")

	got := sjobRunArgs(input, "job-1", "echo hi")
	want := []string{
		"run",
		"--project-id", "REV-19",
		"--job", "job-1",
		"--namespace", "symphony",
		"--image", "symphony/agent:latest",
		"--cpu", "2",
		"--memory", "8Gi",
		"--gpu-count", "0",
		"--ttl-seconds-after-finished", "86400",
		"--project-root", input.Paths.ProjectRoot,
		"--shared-cache-root", input.K3s.SharedCacheRoot,
		"--", "echo hi",
	}

	if !reflect.DeepEqual(got, want) {
		t.Fatalf("unexpected args:\n got: %#v\nwant: %#v", got, want)
	}
}

func TestRunIssueJobCollectsArtifactsAndCleansUpAfterSuccess(t *testing.T) {
	input := newTestRunInput(t)
	writeRunResultFixture(t, input.Paths.ResultPath, "run-result-success.json")
	writeWorkspaceArtifact(t, input.Paths.WorkpadPath, "### Notes\n- synced\n")
	writeWorkspaceArtifact(t, input.Paths.IssuePath, `{"identifier":"REV-19"}`)
	writeWorkspaceArtifact(t, filepath.Join(input.Paths.WorkspacePath, symphonyDirName, "codex-output.jsonl"), "{\"event\":\"done\"}\n")

	expectedJobName := JobResourceName(input.ProjectID, input.WorkflowID, input.RunID)
	var calls [][]string

	installActivityHooks(t, func(_ context.Context, _ string, args []string) (string, error) {
		calls = append(calls, append([]string(nil), args...))

		switch args[0] {
		case "run":
			return "", nil
		case "status":
			return fmt.Sprintf(`{"status":"succeeded","jobName":"%s"}`, expectedJobName), nil
		case "stop":
			return "", nil
		default:
			t.Fatalf("unexpected command args: %#v", args)
			return "", nil
		}
	})

	result, err := RunIssueJob(context.Background(), input)
	if err != nil {
		t.Fatalf("RunIssueJob returned error: %v", err)
	}

	if result.Status != "succeeded" {
		t.Fatalf("expected succeeded result, got %#v", result)
	}
	if result.JobName != expectedJobName {
		t.Fatalf("expected jobName %q, got %q", expectedJobName, result.JobName)
	}

	expectedArtifactDir := filepath.Join(input.Paths.OutputsPath, input.RunID)
	for _, artifact := range []string{
		filepath.Join(expectedArtifactDir, ".symphony", "run-result.json"),
		filepath.Join(expectedArtifactDir, ".symphony", "workpad.md"),
		filepath.Join(expectedArtifactDir, ".symphony", "issue.json"),
		filepath.Join(expectedArtifactDir, ".symphony", "codex-output.jsonl"),
		filepath.Join(expectedArtifactDir, "metadata.json"),
	} {
		if _, err := os.Stat(artifact); err != nil {
			t.Fatalf("expected collected artifact %s: %v", artifact, err)
		}
	}

	if len(calls) != 3 || calls[2][0] != "stop" {
		t.Fatalf("expected run, status, and stop calls, got %#v", calls)
	}
}

func TestRunIssueJobFailsWhenRunResultIsMissing(t *testing.T) {
	input := newTestRunInput(t)
	writeWorkspaceArtifact(t, input.Paths.WorkpadPath, "### Notes\n- missing result\n")

	installActivityHooks(t, func(_ context.Context, _ string, args []string) (string, error) {
		switch args[0] {
		case "run", "stop":
			return "", nil
		case "status":
			return fmt.Sprintf(`{"status":"succeeded","jobName":"%s"}`, JobResourceName(input.ProjectID, input.WorkflowID, input.RunID)), nil
		default:
			t.Fatalf("unexpected command args: %#v", args)
			return "", nil
		}
	})

	result, err := RunIssueJob(context.Background(), input)
	if err == nil {
		t.Fatalf("expected RunIssueJob to fail when run-result.json is missing")
	}

	assertApplicationError(t, err, "missing_run_result", true)

	if result.JobName != JobResourceName(input.ProjectID, input.WorkflowID, input.RunID) {
		t.Fatalf("expected result to preserve jobName, got %#v", result)
	}
}

func TestRunIssueJobFailsWhenRunResultIsMalformed(t *testing.T) {
	input := newTestRunInput(t)
	writeRunResultFixture(t, input.Paths.ResultPath, "run-result-malformed.json")

	installActivityHooks(t, func(_ context.Context, _ string, args []string) (string, error) {
		switch args[0] {
		case "run", "stop":
			return "", nil
		case "status":
			return fmt.Sprintf(`{"status":"failed","jobName":"%s"}`, JobResourceName(input.ProjectID, input.WorkflowID, input.RunID)), nil
		default:
			t.Fatalf("unexpected command args: %#v", args)
			return "", nil
		}
	})

	_, err := RunIssueJob(context.Background(), input)
	if err == nil {
		t.Fatalf("expected RunIssueJob to fail when run-result.json is malformed")
	}

	assertApplicationError(t, err, "malformed_run_result", true)
}

func TestRunIssueJobPreservesIdentifierContinuityAcrossStatusChecks(t *testing.T) {
	input := newTestRunInput(t)
	writeRunResultFixture(t, input.Paths.ResultPath, "run-result-success.json")

	expectedJobName := JobResourceName(input.ProjectID, input.WorkflowID, input.RunID)
	statusCalls := 0

	installActivityHooks(t, func(_ context.Context, _ string, args []string) (string, error) {
		switch args[0] {
		case "run", "stop":
			return "", nil
		case "status":
			statusCalls++
			if statusCalls == 1 {
				return fmt.Sprintf(`{"status":"running","jobName":"%s"}`, expectedJobName), nil
			}
			return fmt.Sprintf(`{"status":"succeeded","jobName":"%s"}`, expectedJobName), nil
		default:
			t.Fatalf("unexpected command args: %#v", args)
			return "", nil
		}
	})

	result, err := RunIssueJob(context.Background(), input)
	if err != nil {
		t.Fatalf("RunIssueJob returned error: %v", err)
	}

	if statusCalls != 2 {
		t.Fatalf("expected two status polls, got %d", statusCalls)
	}
	if result.WorkflowID != input.WorkflowID || result.RunID != input.RunID {
		t.Fatalf("expected identifier continuity in result, got %#v", result)
	}
}

func TestRunIssueJobReturnsRetryableDependencyFailures(t *testing.T) {
	input := newTestRunInput(t)

	installActivityHooks(t, func(_ context.Context, _ string, args []string) (string, error) {
		switch args[0] {
		case "run":
			return "", nil
		case "status":
			return "", errors.New("kubectl not reachable")
		default:
			return "", nil
		}
	})

	_, err := RunIssueJob(context.Background(), input)
	if err == nil {
		t.Fatalf("expected RunIssueJob to return a dependency failure")
	}

	assertApplicationError(t, err, "k3s_status_failed", false)
}

func TestJobResourceNameIsStableUniqueAndBounded(t *testing.T) {
	first := JobResourceName("REV-19", "issue/really-long-workflow-identifier-for-retry-path", "run-0000000001")
	second := JobResourceName("REV-19", "issue/really-long-workflow-identifier-for-retry-path", "run-0000000001")
	third := JobResourceName("REV-19-attempt-1", "issue/really-long-workflow-identifier-for-retry-path", "run-0000000002")

	if first != second {
		t.Fatalf("expected stable job names, got %q and %q", first, second)
	}
	if first == third {
		t.Fatalf("expected unique job names for different identifiers, got %q", first)
	}
	if len(first) > 63 || len(third) > 63 {
		t.Fatalf("expected bounded job names, got %q (%d) and %q (%d)", first, len(first), third, len(third))
	}
	if strings.Contains(first, "REV-19") {
		t.Fatalf("expected resource name components to be Kubernetes-safe, got %q", first)
	}
}

func installActivityHooks(t *testing.T, runner func(context.Context, string, []string) (string, error)) {
	t.Helper()

	previousRunner := executeExternalCommand
	previousInterval := activityPollInterval

	executeExternalCommand = runner
	activityPollInterval = time.Millisecond

	t.Cleanup(func() {
		executeExternalCommand = previousRunner
		activityPollInterval = previousInterval
	})
}

func newTestRunInput(t *testing.T) RunInput {
	t.Helper()

	t.Setenv("SYMPHONY_HOME", repoRoot(t))

	root := t.TempDir()
	projectRoot := filepath.Join(root, "projects", "REV-19")
	workspacePath := filepath.Join(projectRoot, "workspace")
	outputsPath := filepath.Join(projectRoot, "outputs")
	cacheRoot := filepath.Join(root, "cache")

	for _, path := range []string{
		projectRoot,
		workspacePath,
		outputsPath,
		cacheRoot,
		filepath.Join(workspacePath, symphonyDirName),
	} {
		if err := os.MkdirAll(path, 0o755); err != nil {
			t.Fatalf("unable to create %s: %v", path, err)
		}
	}

	writeWorkspaceArtifact(t, filepath.Join(workspacePath, symphonyDirName, "prompt.md"), "Implement the task.\n")
	writeWorkspaceArtifact(t, filepath.Join(workspacePath, symphonyDirName, "workpad.md"), "### Notes\n- initial\n")
	writeWorkspaceArtifact(t, filepath.Join(workspacePath, symphonyDirName, "issue.json"), `{"identifier":"REV-19"}`)

	return RunInput{
		WorkflowID: "issue/REV-19",
		RunID:      "run-00123456",
		ProjectID:  "REV-19",
		Repository: RepositoryConfig{
			OriginURL:     "https://example.com/repo.git",
			DefaultBranch: "main",
		},
		Codex: CodexConfig{
			Command: "codex exec --full-auto --json",
		},
		K3s: K3sConfig{
			Namespace:       "symphony",
			Image:           "symphony/agent:latest",
			ProjectRoot:     filepath.Join(root, "projects"),
			SharedCacheRoot: cacheRoot,
		},
		Paths: PathConfig{
			ProjectRoot:   projectRoot,
			WorkspacePath: workspacePath,
			OutputsPath:   outputsPath,
			PromptPath:    filepath.Join(workspacePath, symphonyDirName, "prompt.md"),
			WorkpadPath:   filepath.Join(workspacePath, symphonyDirName, "workpad.md"),
			ResultPath:    filepath.Join(workspacePath, symphonyDirName, "run-result.json"),
			IssuePath:     filepath.Join(workspacePath, symphonyDirName, "issue.json"),
		},
	}
}

func writeWorkspaceArtifact(t *testing.T, path, content string) {
	t.Helper()

	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatalf("unable to create parent directory for %s: %v", path, err)
	}
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatalf("unable to write %s: %v", path, err)
	}
}

func writeRunResultFixture(t *testing.T, destinationPath, fixtureName string) {
	t.Helper()

	data := readContractFixture(t, fixtureName)
	writeWorkspaceArtifact(t, destinationPath, string(data))
}

func readContractFixture(t *testing.T, fixtureName string) []byte {
	t.Helper()

	_, currentFile, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatalf("unable to resolve test file path")
	}

	path := filepath.Join(filepath.Dir(currentFile), "..", "contracts", "testdata", fixtureName)
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("unable to read fixture %s: %v", path, err)
	}
	return data
}

func assertApplicationError(t *testing.T, err error, expectedType string, expectedNonRetryable bool) {
	t.Helper()

	var applicationError *temporal.ApplicationError
	if !errors.As(err, &applicationError) {
		t.Fatalf("expected application error, got %T: %v", err, err)
	}
	if applicationError.Type() != expectedType {
		t.Fatalf("expected application error type %q, got %q", expectedType, applicationError.Type())
	}
	if applicationError.NonRetryable() != expectedNonRetryable {
		t.Fatalf("expected non-retryable=%t, got %t", expectedNonRetryable, applicationError.NonRetryable())
	}
}
