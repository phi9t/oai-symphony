package main

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	commonpb "go.temporal.io/api/common/v1"
	enumspb "go.temporal.io/api/enums/v1"
	"go.temporal.io/api/serviceerror"
	workflowpb "go.temporal.io/api/workflow/v1"
	workflowservice "go.temporal.io/api/workflowservice/v1"
	"go.temporal.io/sdk/client"

	"symphony-temporal/internal/activities"
	"symphony-temporal/internal/contracts"
)

type fakeTemporalClient struct {
	workflowRun        client.WorkflowRun
	describeResponse   *workflowservice.DescribeWorkflowExecutionResponse
	executeWorkflowErr error
	describeErr        error
	cancelErr          error
	cancelWorkflowID   string
	cancelRunID        string
	executeWorkflowID  string
	executeTaskQueue   string
	executeWorkflowArg any
}

func (f *fakeTemporalClient) ExecuteWorkflow(_ context.Context, options client.StartWorkflowOptions, _ interface{}, args ...interface{}) (client.WorkflowRun, error) {
	f.executeWorkflowID = options.ID
	f.executeTaskQueue = options.TaskQueue

	if len(args) > 0 {
		f.executeWorkflowArg = args[0]
	}

	return f.workflowRun, f.executeWorkflowErr
}

func (f *fakeTemporalClient) DescribeWorkflowExecution(_ context.Context, _ string, _ string) (*workflowservice.DescribeWorkflowExecutionResponse, error) {
	return f.describeResponse, f.describeErr
}

func (f *fakeTemporalClient) CancelWorkflow(_ context.Context, workflowID string, runID string) error {
	f.cancelWorkflowID = workflowID
	f.cancelRunID = runID
	return f.cancelErr
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
	stdout, _ := installTestHooks(t, fakeClient, &capturedOptions)

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

	var payload contracts.WorkflowResponse
	if err := json.Unmarshal(stdout.Bytes(), &payload); err != nil {
		t.Fatalf("unable to decode stdout JSON: %v", err)
	}

	if payload.WorkflowID != "issue/1" || payload.RunID != "run-001" {
		t.Fatalf("unexpected run payload: %#v", payload)
	}
	if payload.JobName != activities.JobResourceName("REV-7", "issue/1", "run-001") {
		t.Fatalf("expected resource-stable job name, got %#v", payload)
	}
	if payload.Readiness == nil || payload.Readiness.State != contracts.ReadinessPending {
		t.Fatalf("expected readiness payload, got %#v", payload)
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
	stdout, _ := installTestHooks(t, fakeClient, &capturedOptions)

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

	var payload contracts.WorkflowResponse
	if err := json.Unmarshal(stdout.Bytes(), &payload); err != nil {
		t.Fatalf("unable to decode stdout JSON: %v", err)
	}

	if payload.WorkflowID != "issue/1" || payload.RunID != "run-001" || payload.Status != "running" {
		t.Fatalf("unexpected status payload: %#v", payload)
	}
	if payload.Readiness == nil || payload.Readiness.State != contracts.ReadinessPending {
		t.Fatalf("expected readiness payload, got %#v", payload)
	}
}

func TestCancelCommandUsesTemporalConfigFromPayload(t *testing.T) {
	fakeClient := &fakeTemporalClient{}

	var capturedOptions client.Options
	stdout, _ := installTestHooks(t, fakeClient, &capturedOptions)

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

	var payload contracts.WorkflowResponse
	if err := json.Unmarshal(stdout.Bytes(), &payload); err != nil {
		t.Fatalf("unable to decode stdout JSON: %v", err)
	}

	if payload.Status != "cancelled" || payload.Readiness == nil || payload.Readiness.State != contracts.ReadinessNotReady {
		t.Fatalf("unexpected cancel payload: %#v", payload)
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
	stdout, _ := installTestHooks(t, fakeClient, &capturedOptions)

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

	var payload contracts.WorkflowResponse
	if err := json.Unmarshal(stdout.Bytes(), &payload); err != nil {
		t.Fatalf("unable to decode stdout JSON: %v", err)
	}

	if payload.WorkflowID != "issue/1" || payload.RunID != "run-009" || payload.Status != "succeeded" {
		t.Fatalf("unexpected describe payload: %#v", payload)
	}
	if payload.Readiness == nil || payload.Readiness.State != contracts.ReadinessReady {
		t.Fatalf("expected readiness payload, got %#v", payload)
	}
}

func TestHelperFixturesExerciseRunStatusCancelAndDescribeContracts(t *testing.T) {
	fakeClient := &fakeTemporalClient{
		workflowRun: fakeWorkflowRun{id: "issue/alpha", runID: "run-00123456"},
		describeResponse: &workflowservice.DescribeWorkflowExecutionResponse{
			WorkflowExecutionInfo: &workflowpb.WorkflowExecutionInfo{
				Execution: &commonpb.WorkflowExecution{RunId: "run-00123456"},
				Status:    enumspb.WORKFLOW_EXECUTION_STATUS_RUNNING,
			},
		},
	}

	var capturedOptions client.Options
	stdout, _ := installTestHooks(t, fakeClient, &capturedOptions)

	runRequestPath := writeFixtureInput(t, "run-request.json")
	if err := runCommand([]string{"--input", runRequestPath, "--output", "json"}); err != nil {
		t.Fatalf("runCommand returned error: %v", err)
	}
	assertFixtureResponse(t, stdout.Bytes(), "run-response.json")
	stdout.Reset()

	statusRequestPath := writeFixtureInput(t, "status-request.json")
	if err := statusCommand([]string{"--input", statusRequestPath, "--output", "json"}); err != nil {
		t.Fatalf("statusCommand returned error: %v", err)
	}
	assertFixtureResponse(t, stdout.Bytes(), "status-response.json")
	stdout.Reset()

	cancelRequestPath := writeFixtureInput(t, "cancel-request.json")
	if err := cancelCommand([]string{"--input", cancelRequestPath, "--output", "json"}); err != nil {
		t.Fatalf("cancelCommand returned error: %v", err)
	}
	assertFixtureResponse(t, stdout.Bytes(), "cancel-response.json")
	stdout.Reset()

	fakeClient.describeResponse.WorkflowExecutionInfo.Status = enumspb.WORKFLOW_EXECUTION_STATUS_COMPLETED
	describeRequestPath := writeFixtureInput(t, "describe-request.json")
	if err := run([]string{"describe", "--input", describeRequestPath, "--output", "json"}); err != nil {
		t.Fatalf("run describe returned error: %v", err)
	}
	assertFixtureResponse(t, stdout.Bytes(), "describe-response.json")
}

func TestWriteCLIErrorUsesStableFailureEnvelope(t *testing.T) {
	fakeClient := &fakeTemporalClient{
		describeErr: serviceerror.NewUnavailable("temporarily unavailable"),
	}

	var capturedOptions client.Options
	_, stderr := installTestHooks(t, fakeClient, &capturedOptions)

	inputPath := writeJSONInput(t, workflowInput{
		WorkflowID: "issue/1",
		RunID:      "run-001",
		Temporal: activities.TemporalConfig{
			Address:   "temporal.example:7233",
			Namespace: "customer-a",
		},
	})

	err := statusCommand([]string{"--input", inputPath, "--output", "json"})
	if err == nil {
		t.Fatalf("expected statusCommand to fail")
	}

	if writeErr := writeCLIError(err); writeErr != nil {
		t.Fatalf("writeCLIError returned error: %v", writeErr)
	}

	var actual contracts.ErrorEnvelope
	if err := json.Unmarshal(stderr.Bytes(), &actual); err != nil {
		t.Fatalf("unable to decode stderr JSON: %v", err)
	}

	if actual.Error.Code != "temporal_unavailable" {
		t.Fatalf("expected temporal_unavailable code, got %#v", actual)
	}
	if !actual.Error.Retryable {
		t.Fatalf("expected retryable error, got %#v", actual)
	}
	if !strings.Contains(actual.Error.Message, "temporarily unavailable") {
		t.Fatalf("expected helper error message to preserve evidence, got %#v", actual)
	}
}

func TestWriteCLIErrorForInvalidRequestMatchesFixtureContract(t *testing.T) {
	stderr := &bytes.Buffer{}
	previousErrorWriter := errorWriter
	errorWriter = stderr
	t.Cleanup(func() {
		errorWriter = previousErrorWriter
	})

	if writeErr := writeCLIError(invalidRequestError("workflowId is required")); writeErr != nil {
		t.Fatalf("writeCLIError returned error: %v", writeErr)
	}

	expected := readFixtureEnvelope(t, "error-invalid-request.json")
	var actual contracts.ErrorEnvelope
	if err := json.Unmarshal(stderr.Bytes(), &actual); err != nil {
		t.Fatalf("unable to decode stderr JSON: %v", err)
	}

	if !reflect.DeepEqual(actual, expected) {
		t.Fatalf("unexpected error envelope:\n got: %#v\nwant: %#v", actual, expected)
	}
}

func installTestHooks(t *testing.T, fakeClient *fakeTemporalClient, capturedOptions *client.Options) (*bytes.Buffer, *bytes.Buffer) {
	t.Helper()

	stdout := &bytes.Buffer{}
	stderr := &bytes.Buffer{}
	previousDialer := dialTemporalClient
	previousOutputWriter := outputWriter
	previousErrorWriter := errorWriter

	dialTemporalClient = func(options client.Options) (temporalClient, error) {
		*capturedOptions = options
		return fakeClient, nil
	}
	outputWriter = stdout
	errorWriter = stderr

	t.Cleanup(func() {
		dialTemporalClient = previousDialer
		outputWriter = previousOutputWriter
		errorWriter = previousErrorWriter
	})

	return stdout, stderr
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

func writeFixtureInput(t *testing.T, fixtureName string) string {
	t.Helper()

	var payload any
	data, err := os.ReadFile(filepath.Join("testdata", fixtureName))
	if err != nil {
		t.Fatalf("unable to read fixture %s: %v", fixtureName, err)
	}
	if err := json.Unmarshal(data, &payload); err != nil {
		t.Fatalf("unable to decode fixture %s: %v", fixtureName, err)
	}
	return writeJSONInput(t, payload)
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

func assertFixtureResponse(t *testing.T, output []byte, fixtureName string) {
	t.Helper()

	var actual contracts.WorkflowResponse
	if err := json.Unmarshal(output, &actual); err != nil {
		t.Fatalf("unable to decode helper output: %v", err)
	}

	expectedData, err := os.ReadFile(filepath.Join("testdata", fixtureName))
	if err != nil {
		t.Fatalf("unable to read fixture %s: %v", fixtureName, err)
	}

	var expected contracts.WorkflowResponse
	if err := json.Unmarshal(expectedData, &expected); err != nil {
		t.Fatalf("unable to decode fixture %s: %v", fixtureName, err)
	}

	if !reflect.DeepEqual(actual, expected) {
		t.Fatalf("unexpected helper response for fixture %s:\n got: %#v\nwant: %#v", fixtureName, actual, expected)
	}
}

func readFixtureEnvelope(t *testing.T, fixtureName string) contracts.ErrorEnvelope {
	t.Helper()

	data, err := os.ReadFile(filepath.Join("testdata", fixtureName))
	if err != nil {
		t.Fatalf("unable to read fixture %s: %v", fixtureName, err)
	}

	var envelope contracts.ErrorEnvelope
	if err := json.Unmarshal(data, &envelope); err != nil {
		t.Fatalf("unable to decode fixture %s: %v", fixtureName, err)
	}
	return envelope
}
