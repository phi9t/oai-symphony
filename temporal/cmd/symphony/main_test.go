package main

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	commonpb "go.temporal.io/api/common/v1"
	enumspb "go.temporal.io/api/enums/v1"
	taskqueuepb "go.temporal.io/api/taskqueue/v1"
	workflowpb "go.temporal.io/api/workflow/v1"
	workflowservice "go.temporal.io/api/workflowservice/v1"
	"go.temporal.io/sdk/client"

	"symphony-temporal/internal/activities"
)

type fakeTemporalClient struct {
	workflowRun        client.WorkflowRun
	describeResponse   *workflowservice.DescribeWorkflowExecutionResponse
	cancelWorkflowID   string
	cancelRunID        string
	executeWorkflowID  string
	executeTaskQueue   string
	executeWorkflowArg any
	systemInfoErr      error
	namespaceErr       error
	taskQueueResponses map[enumspb.TaskQueueType]*workflowservice.DescribeTaskQueueResponse
	taskQueueErrors    map[enumspb.TaskQueueType]error
}

func (f *fakeTemporalClient) ExecuteWorkflow(_ context.Context, options client.StartWorkflowOptions, _ interface{}, args ...interface{}) (client.WorkflowRun, error) {
	f.executeWorkflowID = options.ID
	f.executeTaskQueue = options.TaskQueue

	if len(args) > 0 {
		f.executeWorkflowArg = args[0]
	}

	return f.workflowRun, nil
}

func (f *fakeTemporalClient) DescribeWorkflowExecution(_ context.Context, _ string, _ string) (*workflowservice.DescribeWorkflowExecutionResponse, error) {
	return f.describeResponse, nil
}

func (f *fakeTemporalClient) CancelWorkflow(_ context.Context, workflowID string, runID string) error {
	f.cancelWorkflowID = workflowID
	f.cancelRunID = runID
	return nil
}

func (f *fakeTemporalClient) GetSystemInfo(_ context.Context) (*workflowservice.GetSystemInfoResponse, error) {
	if f.systemInfoErr != nil {
		return nil, f.systemInfoErr
	}
	return &workflowservice.GetSystemInfoResponse{}, nil
}

func (f *fakeTemporalClient) DescribeNamespace(_ context.Context, _ string) (*workflowservice.DescribeNamespaceResponse, error) {
	if f.namespaceErr != nil {
		return nil, f.namespaceErr
	}
	return &workflowservice.DescribeNamespaceResponse{}, nil
}

func (f *fakeTemporalClient) DescribeTaskQueue(_ context.Context, _ string, taskQueueType enumspb.TaskQueueType) (*workflowservice.DescribeTaskQueueResponse, error) {
	if err := f.taskQueueErrors[taskQueueType]; err != nil {
		return nil, err
	}
	if response := f.taskQueueResponses[taskQueueType]; response != nil {
		return response, nil
	}
	return &workflowservice.DescribeTaskQueueResponse{}, nil
}

func (f *fakeTemporalClient) Close() {}

type fakeWorkflowRun struct {
	id    string
	runID string
}

func (f fakeWorkflowRun) GetID() string {
	return f.id
}

func (f fakeWorkflowRun) GetRunID() string {
	return f.runID
}

func (f fakeWorkflowRun) Get(_ context.Context, _ interface{}) error {
	return nil
}

func (f fakeWorkflowRun) GetWithOptions(_ context.Context, _ interface{}, _ client.WorkflowRunGetOptions) error {
	return nil
}

func TestRunCommandUsesTemporalConfigFromPayload(t *testing.T) {
	fakeClient := &fakeTemporalClient{
		workflowRun: fakeWorkflowRun{id: "issue/1", runID: "run-001"},
	}

	var capturedOptions client.Options
	stdout := installTestHooks(t, fakeClient, &capturedOptions)

	inputPath := writeJSONInput(t, activities.RunInput{
		WorkflowID: "issue/1",
		ProjectID:  "REV-7",
		Temporal: activities.TemporalConfig{
			Address:   "temporal.example:7233",
			Namespace: "customer-a",
			TaskQueue: "symphony",
		},
		Paths: activities.PathConfig{
			WorkspacePath: "/tmp/workspace",
			OutputsPath:   "/tmp/outputs",
		},
	})

	if err := runCommand([]string{"--input", inputPath, "--output", "json"}); err != nil {
		t.Fatalf("runCommand returned error: %v", err)
	}

	assertDialOptions(t, capturedOptions)

	if fakeClient.executeWorkflowID != "issue/1" {
		t.Fatalf("expected workflow ID issue/1, got %q", fakeClient.executeWorkflowID)
	}

	if fakeClient.executeTaskQueue != "symphony" {
		t.Fatalf("expected task queue symphony, got %q", fakeClient.executeTaskQueue)
	}

	var payload map[string]any
	if err := json.Unmarshal(stdout.Bytes(), &payload); err != nil {
		t.Fatalf("unable to decode stdout JSON: %v", err)
	}

	if payload["workflowId"] != "issue/1" || payload["runId"] != "run-001" {
		t.Fatalf("unexpected run payload: %#v", payload)
	}
}

func TestStatusCommandUsesTemporalConfigFromPayload(t *testing.T) {
	fakeClient := &fakeTemporalClient{
		describeResponse: &workflowservice.DescribeWorkflowExecutionResponse{
			WorkflowExecutionInfo: &workflowpb.WorkflowExecutionInfo{
				Execution: &commonpb.WorkflowExecution{RunId: "run-001"},
				Status:    enumspb.WORKFLOW_EXECUTION_STATUS_RUNNING,
			},
		},
	}

	var capturedOptions client.Options
	stdout := installTestHooks(t, fakeClient, &capturedOptions)

	inputPath := writeJSONInput(t, workflowInput{
		WorkflowID: "issue/1",
		RunID:      "run-001",
		Temporal: activities.TemporalConfig{
			Address:   "temporal.example:7233",
			Namespace: "customer-a",
		},
	})

	if err := statusCommand([]string{"--input", inputPath, "--output", "json"}); err != nil {
		t.Fatalf("statusCommand returned error: %v", err)
	}

	assertDialOptions(t, capturedOptions)

	var payload map[string]any
	if err := json.Unmarshal(stdout.Bytes(), &payload); err != nil {
		t.Fatalf("unable to decode stdout JSON: %v", err)
	}

	if payload["workflowId"] != "issue/1" || payload["runId"] != "run-001" || payload["status"] != "running" {
		t.Fatalf("unexpected status payload: %#v", payload)
	}
}

func TestCancelCommandUsesTemporalConfigFromPayload(t *testing.T) {
	fakeClient := &fakeTemporalClient{}

	var capturedOptions client.Options
	_ = installTestHooks(t, fakeClient, &capturedOptions)

	inputPath := writeJSONInput(t, workflowInput{
		WorkflowID: "issue/1",
		RunID:      "run-001",
		Temporal: activities.TemporalConfig{
			Address:   "temporal.example:7233",
			Namespace: "customer-a",
		},
	})

	if err := cancelCommand([]string{"--input", inputPath, "--output", "json"}); err != nil {
		t.Fatalf("cancelCommand returned error: %v", err)
	}

	assertDialOptions(t, capturedOptions)

	if fakeClient.cancelWorkflowID != "issue/1" || fakeClient.cancelRunID != "run-001" {
		t.Fatalf("unexpected cancel target: workflow=%q run=%q", fakeClient.cancelWorkflowID, fakeClient.cancelRunID)
	}
}

func TestDescribeSubcommandUsesTemporalConfigFromPayload(t *testing.T) {
	fakeClient := &fakeTemporalClient{
		describeResponse: &workflowservice.DescribeWorkflowExecutionResponse{
			WorkflowExecutionInfo: &workflowpb.WorkflowExecutionInfo{
				Execution: &commonpb.WorkflowExecution{RunId: "run-009"},
				Status:    enumspb.WORKFLOW_EXECUTION_STATUS_COMPLETED,
			},
		},
	}

	var capturedOptions client.Options
	stdout := installTestHooks(t, fakeClient, &capturedOptions)

	inputPath := writeJSONInput(t, workflowInput{
		WorkflowID: "issue/1",
		Temporal: activities.TemporalConfig{
			Address:   "temporal.example:7233",
			Namespace: "customer-a",
		},
	})

	if err := run([]string{"describe", "--input", inputPath, "--output", "json"}); err != nil {
		t.Fatalf("run describe returned error: %v", err)
	}

	assertDialOptions(t, capturedOptions)

	var payload map[string]any
	if err := json.Unmarshal(stdout.Bytes(), &payload); err != nil {
		t.Fatalf("unable to decode stdout JSON: %v", err)
	}

	if payload["workflowId"] != "issue/1" || payload["runId"] != "run-009" || payload["status"] != "succeeded" {
		t.Fatalf("unexpected describe payload: %#v", payload)
	}
}

func TestReadinessCommandReportsReadyRuntime(t *testing.T) {
	fakeClient := &fakeTemporalClient{
		taskQueueResponses: map[enumspb.TaskQueueType]*workflowservice.DescribeTaskQueueResponse{
			enumspb.TASK_QUEUE_TYPE_WORKFLOW: {
				Pollers: []*taskqueuepb.PollerInfo{{Identity: "workflow-worker"}},
			},
			enumspb.TASK_QUEUE_TYPE_ACTIVITY: {
				Pollers: []*taskqueuepb.PollerInfo{{Identity: "activity-worker"}},
			},
		},
	}

	var capturedOptions client.Options
	stdout := installTestHooks(t, fakeClient, &capturedOptions)

	home := t.TempDir()
	writeExecutable(t, filepath.Join(home, "k3s", "bin", "sjob"), "#!/bin/sh\nexit 0\n")

	kubectlWrapper := filepath.Join(home, "kubectl-wrapper.sh")
	writeExecutable(t, kubectlWrapper, "#!/bin/sh\necho symphony\n")

	t.Setenv("SYMPHONY_HOME", home)
	t.Setenv("SYMPHONY_KUBECTL_WRAPPER", kubectlWrapper)

	inputPath := writeJSONInput(t, readinessInput{
		Temporal: activities.TemporalConfig{
			Address:   "temporal.example:7233",
			Namespace: "customer-a",
			TaskQueue: "symphony",
		},
		K3s: activities.K3sConfig{Namespace: "symphony"},
	})

	if err := readinessCommand([]string{"--input", inputPath, "--output", "json"}); err != nil {
		t.Fatalf("readinessCommand returned error: %v", err)
	}

	assertDialOptions(t, capturedOptions)

	var payload readinessPayload
	if err := json.Unmarshal(stdout.Bytes(), &payload); err != nil {
		t.Fatalf("unable to decode readiness JSON: %v", err)
	}

	if !payload.Ready {
		t.Fatalf("expected readiness payload to be ready, got %#v", payload)
	}
	if payload.Temporal.WorkflowPollers != 1 || payload.Temporal.ActivityPollers != 1 || !payload.Temporal.WorkerReady {
		t.Fatalf("unexpected Temporal readiness payload: %#v", payload.Temporal)
	}
	if !payload.K3s.NamespaceReady || payload.K3s.LauncherPath == "" || payload.K3s.KubectlCommand == "" {
		t.Fatalf("unexpected K3s readiness payload: %#v", payload.K3s)
	}
}

func TestReadinessCommandReportsSpecificBlockers(t *testing.T) {
	fakeClient := &fakeTemporalClient{
		taskQueueResponses: map[enumspb.TaskQueueType]*workflowservice.DescribeTaskQueueResponse{
			enumspb.TASK_QUEUE_TYPE_WORKFLOW: {},
			enumspb.TASK_QUEUE_TYPE_ACTIVITY: {},
		},
	}

	var capturedOptions client.Options
	stdout := installTestHooks(t, fakeClient, &capturedOptions)

	home := t.TempDir()
	writeExecutable(t, filepath.Join(home, "k3s", "bin", "sjob"), "#!/bin/sh\nexit 0\n")

	kubectlWrapper := filepath.Join(home, "kubectl-wrapper.sh")
	writeExecutable(t, kubectlWrapper, "#!/bin/sh\nprintf '%s\\n' 'Error from server (NotFound): namespaces \"symphony\" not found' >&2\nexit 1\n")

	t.Setenv("SYMPHONY_HOME", home)
	t.Setenv("SYMPHONY_KUBECTL_WRAPPER", kubectlWrapper)

	inputPath := writeJSONInput(t, readinessInput{
		Temporal: activities.TemporalConfig{
			Address:   "temporal.example:7233",
			Namespace: "customer-a",
			TaskQueue: "symphony",
		},
		K3s: activities.K3sConfig{Namespace: "symphony"},
	})

	if err := readinessCommand([]string{"--input", inputPath, "--output", "json"}); err != nil {
		t.Fatalf("readinessCommand returned error: %v", err)
	}

	assertDialOptions(t, capturedOptions)

	var payload readinessPayload
	if err := json.Unmarshal(stdout.Bytes(), &payload); err != nil {
		t.Fatalf("unable to decode readiness JSON: %v", err)
	}

	if payload.Ready {
		t.Fatalf("expected readiness payload to be blocked, got %#v", payload)
	}

	codes := map[string]bool{}
	for _, blocker := range payload.Blockers {
		codes[blocker.Code] = true
	}

	if !codes["temporal_worker_missing"] || !codes["k3s_namespace_missing"] {
		t.Fatalf("expected worker and namespace blockers, got %#v", payload.Blockers)
	}
}

func installTestHooks(t *testing.T, fakeClient *fakeTemporalClient, capturedOptions *client.Options) *bytes.Buffer {
	t.Helper()

	stdout := &bytes.Buffer{}
	previousDialer := dialTemporalClient
	previousOutputWriter := outputWriter

	dialTemporalClient = func(options client.Options) (temporalClient, error) {
		*capturedOptions = options
		return fakeClient, nil
	}
	outputWriter = stdout

	t.Cleanup(func() {
		dialTemporalClient = previousDialer
		outputWriter = previousOutputWriter
	})

	return stdout
}

func writeJSONInput(t *testing.T, payload any) string {
	t.Helper()

	path := filepath.Join(t.TempDir(), "input.json")
	data, err := json.Marshal(payload)
	if err != nil {
		t.Fatalf("unable to encode test input: %v", err)
	}

	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatalf("unable to write test input: %v", err)
	}

	return path
}

func assertDialOptions(t *testing.T, options client.Options) {
	t.Helper()

	if options.HostPort != "temporal.example:7233" {
		t.Fatalf("expected HostPort temporal.example:7233, got %q", options.HostPort)
	}

	if options.Namespace != "customer-a" {
		t.Fatalf("expected Namespace customer-a, got %q", options.Namespace)
	}
}

func writeExecutable(t *testing.T, path, content string) {
	t.Helper()

	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatalf("unable to create parent dir for %s: %v", path, err)
	}
	if err := os.WriteFile(path, []byte(content), 0o755); err != nil {
		t.Fatalf("unable to write executable %s: %v", path, err)
	}
}
