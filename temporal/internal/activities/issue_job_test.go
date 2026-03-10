package activities

import (
	"reflect"
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
