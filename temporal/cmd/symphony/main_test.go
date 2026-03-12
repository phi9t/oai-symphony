package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"testing"

	commonpb "go.temporal.io/api/common/v1"
	enumspb "go.temporal.io/api/enums/v1"
	workflowpb "go.temporal.io/api/workflow/v1"
	workflowservice "go.temporal.io/api/workflowservice/v1"
	"go.temporal.io/sdk/client"
	"go.temporal.io/sdk/converter"

	"symphony-temporal/internal/activities"
)

type fakeTemporalClient struct {
	workflowRun        client.WorkflowRun
	describeResponse   *workflowservice.DescribeWorkflowExecutionResponse
	queryResponse      any
	queryErr           error
	cancelWorkflowID   string
	cancelRunID        string
	executeWorkflowID  string
	executeTaskQueue   string
	executeWorkflowArg any
	queryWorkflowID    string
	queryRunID         string
	queryType          string
}

type fakeEncodedValue struct {
	value any
}

func (f fakeEncodedValue) HasValue() bool {
	return f.value != nil
}

func (f fakeEncodedValue) Get(valuePtr interface{}) error {
	data, err := json.Marshal(f.value)
	if err != nil {
		return err
	}

	return json.Unmarshal(data, valuePtr)
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

func (f *fakeTemporalClient) QueryWorkflow(_ context.Context, workflowID string, runID string, queryType string, _ ...interface{}) (converter.EncodedValue, error) {
	f.queryWorkflowID = workflowID
	f.queryRunID = runID
	f.queryType = queryType

	if f.queryErr != nil {
		return nil, f.queryErr
	}

	return fakeEncodedValue{value: f.queryResponse}, nil
}

func (f *fakeTemporalClient) CancelWorkflow(_ context.Context, workflowID string, runID string) error {
	f.cancelWorkflowID = workflowID
	f.cancelRunID = runID
	return nil
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
		queryResponse: activities.WorkflowState{
			WorkflowID:   "issue/1",
			RunID:        "run-001",
			Status:       "running",
			WorkflowMode: activities.WorkflowModePhased,
			CurrentPhase: "plan",
			Phases: []activities.PhaseState{
				{Name: "perceive", Status: "succeeded"},
				{Name: "plan", Status: "running"},
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

	if payload["workflow_mode"] != "phased" || payload["current_phase"] != "plan" {
		t.Fatalf("expected normalized workflow state, got %#v", payload)
	}

	phases, ok := payload["phases"].([]interface{})
	if !ok || len(phases) != 2 {
		t.Fatalf("expected normalized phases in payload, got %#v", payload["phases"])
	}

	if fakeClient.queryWorkflowID != "issue/1" || fakeClient.queryRunID != "run-001" || fakeClient.queryType != "symphony_state" {
		t.Fatalf("unexpected workflow query: workflow=%q run=%q type=%q", fakeClient.queryWorkflowID, fakeClient.queryRunID, fakeClient.queryType)
	}
}

func TestStatusCommandFallsBackToWorkflowModeWhenQueryUnavailable(t *testing.T) {
	fakeClient := &fakeTemporalClient{
		describeResponse: &workflowservice.DescribeWorkflowExecutionResponse{
			WorkflowExecutionInfo: &workflowpb.WorkflowExecutionInfo{
				Execution: &commonpb.WorkflowExecution{RunId: "run-vanilla"},
				Status:    enumspb.WORKFLOW_EXECUTION_STATUS_RUNNING,
			},
		},
		queryErr: errors.New("query unavailable"),
	}

	var capturedOptions client.Options
	stdout := installTestHooks(t, fakeClient, &capturedOptions)

	inputPath := writeJSONInput(t, workflowInput{
		WorkflowID:   "issue/1",
		WorkflowMode: "vanilla",
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

	if payload["workflow_mode"] != "vanilla" || payload["current_phase"] != "run" {
		t.Fatalf("expected vanilla fallback payload, got %#v", payload)
	}

	phases, ok := payload["phases"].([]interface{})
	if !ok || len(phases) != 1 {
		t.Fatalf("expected fallback phases in payload, got %#v", payload["phases"])
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
