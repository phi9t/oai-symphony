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

func TestBuildJobCommandUsesContainerWorkspacePaths(t *testing.T) {
	input := RunInput{
		Repository: RepositoryConfig{
			OriginURL:     "/opt/symphony",
			DefaultBranch: "main",
		},
		Codex: CodexConfig{
			Command: "python3 /opt/symphony/dev/smoke_codex.py",
		},
		Paths: PathConfig{
			WorkspacePath: "/host/projects/rev-16/workspace",
			PromptPath:    "/host/projects/rev-16/workspace/.symphony/prompt.md",
			WorkpadPath:   "/host/projects/rev-16/workspace/.symphony/workpad.md",
			ResultPath:    "/host/projects/rev-16/workspace/.symphony/run-result.json",
			IssuePath:     "/host/projects/rev-16/workspace/.symphony/issue.json",
		},
	}

	command := buildJobCommand(input)

	expected := []string{
		"PROMPT_PATH='/workspace/.symphony/prompt.md'",
		"WORKPAD_PATH='/workspace/.symphony/workpad.md'",
		"RESULT_PATH='/workspace/.symphony/run-result.json'",
		"ISSUE_PATH='/workspace/.symphony/issue.json'",
		"WORKSPACE_PATH='/workspace'",
	}

	for _, fragment := range expected {
		if !strings.Contains(command, fragment) {
			t.Fatalf("expected %q in command %q", fragment, command)
		}
	}
}
