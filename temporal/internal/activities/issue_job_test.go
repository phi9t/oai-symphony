package activities

import (
	"reflect"
	"strings"
	"testing"
)

func TestSjobRunArgsIncludesGPUAndRuntimeClass(t *testing.T) {
	input := RunInput{
		ProjectID: "proj-1",
		K3s: K3sConfig{
			Namespace:               "symphony",
			Image:                   "symphony/agent:latest",
			ProjectRoot:             "/tmp/project",
			SharedCacheRoot:         "/tmp/cache",
			TTLSecondsAfterFinished: 120,
			DefaultCPU:              "4",
			DefaultMemory:           "16Gi",
			DefaultGPUCount:         2,
			RuntimeClass:            "nvidia",
		},
	}

	got := sjobRunArgs(input, "job-1", "echo hi")
	want := []string{
		"run",
		"--project-id", "proj-1",
		"--job", "job-1",
		"--namespace", "symphony",
		"--image", "symphony/agent:latest",
		"--cpu", "4",
		"--memory", "16Gi",
		"--gpu-count", "2",
		"--ttl-seconds-after-finished", "120",
		"--project-root", "/tmp/project",
		"--shared-cache-root", "/tmp/cache",
		"--runtime-class", "nvidia",
		"--", "echo hi",
	}

	if !reflect.DeepEqual(got, want) {
		t.Fatalf("unexpected args:\n got: %#v\nwant: %#v", got, want)
	}
}

func TestSjobRunArgsDefaultsOptionalResources(t *testing.T) {
	input := RunInput{
		ProjectID: "proj-2",
		K3s: K3sConfig{
			Namespace:               "symphony",
			Image:                   "symphony/agent:latest",
			ProjectRoot:             "/tmp/project",
			SharedCacheRoot:         "/tmp/cache",
			TTLSecondsAfterFinished: 0,
			DefaultCPU:              "",
			DefaultMemory:           "",
			DefaultGPUCount:         -1,
			RuntimeClass:            "   ",
		},
	}

	got := sjobRunArgs(input, "job-2", "echo bye")
	want := []string{
		"run",
		"--project-id", "proj-2",
		"--job", "job-2",
		"--namespace", "symphony",
		"--image", "symphony/agent:latest",
		"--cpu", "2",
		"--memory", "8Gi",
		"--gpu-count", "0",
		"--ttl-seconds-after-finished", "86400",
		"--project-root", "/tmp/project",
		"--shared-cache-root", "/tmp/cache",
		"--", "echo bye",
	}

	if !reflect.DeepEqual(got, want) {
		t.Fatalf("unexpected args:\n got: %#v\nwant: %#v", got, want)
	}
}

func TestBuildJobCommandUsesContainerVisibleWorkspacePaths(t *testing.T) {
	input := RunInput{
		Repository: RepositoryConfig{
			OriginURL:     "/opt/symphony",
			DefaultBranch: "main",
		},
		Codex: CodexConfig{
			Command: "python3 /opt/symphony/dev/smoke_codex.py",
		},
		Paths: PathConfig{
			WorkspacePath: "/host/project/workspace",
			PromptPath:    "/host/project/workspace/.symphony/prompt.md",
			WorkpadPath:   "/host/project/workspace/.symphony/workpad.md",
			ResultPath:    "/host/project/workspace/.symphony/run-result.json",
			IssuePath:     "/host/project/workspace/.symphony/issue.json",
		},
	}

	command := buildJobCommand(input)

	expectedFragments := []string{
		"PROMPT_PATH='/workspace/.symphony/prompt.md'",
		"WORKPAD_PATH='/workspace/.symphony/workpad.md'",
		"RESULT_PATH='/workspace/.symphony/run-result.json'",
		"ISSUE_PATH='/workspace/.symphony/issue.json'",
		"WORKSPACE_PATH='/workspace'",
		"REPOSITORY_ORIGIN_URL='/opt/symphony'",
		"REPOSITORY_DEFAULT_BRANCH='main'",
		"CODEX_COMMAND='python3 /opt/symphony/dev/smoke_codex.py'",
	}

	for _, fragment := range expectedFragments {
		if !strings.Contains(command, fragment) {
			t.Fatalf("buildJobCommand missing %q in %q", fragment, command)
		}
	}
}
