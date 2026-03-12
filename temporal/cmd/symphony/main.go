package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	enumspb "go.temporal.io/api/enums/v1"
	"go.temporal.io/api/serviceerror"
	workflowservice "go.temporal.io/api/workflowservice/v1"
	"go.temporal.io/sdk/client"
	"go.temporal.io/sdk/converter"

	"symphony-temporal/internal/activities"
	"symphony-temporal/internal/contracts"
	"symphony-temporal/internal/workflows"
)

type workflowInput struct {
	WorkflowID   string                    `json:"workflowId"`
	RunID        string                    `json:"runId"`
	WorkflowMode string                    `json:"workflowMode"`
	Temporal     activities.TemporalConfig `json:"temporal"`
}

type readinessInput struct {
	Temporal activities.TemporalConfig `json:"temporal"`
	K3s      activities.K3sConfig      `json:"k3s"`
}

type runtimeBlocker struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

type temporalReadiness struct {
	Address         string `json:"address"`
	Namespace       string `json:"namespace"`
	TaskQueue       string `json:"taskQueue"`
	Reachable       bool   `json:"reachable"`
	NamespaceReady  bool   `json:"namespaceReady"`
	WorkerReady     bool   `json:"workerReady"`
	WorkflowPollers int    `json:"workflowPollers"`
	ActivityPollers int    `json:"activityPollers"`
}

type k3sReadiness struct {
	Namespace      string `json:"namespace"`
	NamespaceReady bool   `json:"namespaceReady"`
	LauncherPath   string `json:"launcherPath,omitempty"`
	KubectlCommand string `json:"kubectlCommand,omitempty"`
}

type readinessPayload struct {
	Ready         bool              `json:"ready"`
	ExecutionKind string            `json:"executionKind"`
	Blockers      []runtimeBlocker  `json:"blockers"`
	Temporal      temporalReadiness `json:"temporal"`
	K3s           k3sReadiness      `json:"k3s"`
}

type temporalClient interface {
	ExecuteWorkflow(ctx context.Context, options client.StartWorkflowOptions, workflow any, args ...any) (client.WorkflowRun, error)
	DescribeWorkflowExecution(ctx context.Context, workflowID string, runID string) (*workflowservice.DescribeWorkflowExecutionResponse, error)
	QueryWorkflow(ctx context.Context, workflowID string, runID string, queryType string, args ...interface{}) (converter.EncodedValue, error)
	CancelWorkflow(ctx context.Context, workflowID string, runID string) error
	GetSystemInfo(ctx context.Context) (*workflowservice.GetSystemInfoResponse, error)
	DescribeNamespace(ctx context.Context, namespace string) (*workflowservice.DescribeNamespaceResponse, error)
	DescribeTaskQueue(ctx context.Context, taskQueue string, taskQueueType enumspb.TaskQueueType) (*workflowservice.DescribeTaskQueueResponse, error)
	Close()
}

type sdkTemporalClient struct {
	client.Client
}

var dialTemporalClient = func(options client.Options) (temporalClient, error) {
	c, err := client.Dial(options)
	if err != nil {
		return nil, err
	}
	return &sdkTemporalClient{Client: c}, nil
}

var outputWriter io.Writer = os.Stdout
var errorWriter io.Writer = os.Stderr

func (c *sdkTemporalClient) GetSystemInfo(ctx context.Context) (*workflowservice.GetSystemInfoResponse, error) {
	return c.WorkflowService().GetSystemInfo(ctx, &workflowservice.GetSystemInfoRequest{})
}

func (c *sdkTemporalClient) DescribeNamespace(ctx context.Context, namespace string) (*workflowservice.DescribeNamespaceResponse, error) {
	return c.WorkflowService().DescribeNamespace(ctx, &workflowservice.DescribeNamespaceRequest{Namespace: namespace})
}

func (c *sdkTemporalClient) DescribeTaskQueue(ctx context.Context, taskQueue string, taskQueueType enumspb.TaskQueueType) (*workflowservice.DescribeTaskQueueResponse, error) {
	return c.Client.DescribeTaskQueue(ctx, taskQueue, taskQueueType)
}

func main() {
	if err := run(os.Args[1:]); err != nil {
		if writeErr := writeCLIError(err); writeErr != nil {
			fmt.Fprintln(os.Stderr, writeErr)
		}
		os.Exit(1)
	}
}

func run(args []string) error {
	subcommand, rest := parseSubcommand(args)
	switch subcommand {
	case "run":
		return runCommand(rest)
	case "status":
		return statusCommand(rest)
	case "cancel":
		return cancelCommand(rest)
	case "describe":
		return describeCommand(rest)
	case "readiness":
		return readinessCommand(rest)
	default:
		return invalidRequestError("unknown subcommand %q", subcommand)
	}
}

func parseSubcommand(args []string) (string, []string) {
	if len(args) == 0 {
		return "run", args
	}

	switch args[0] {
	case "run", "status", "cancel", "describe", "readiness":
		return args[0], args[1:]
	default:
		if strings.HasPrefix(args[0], "-") {
			return "run", args
		}
		return args[0], args[1:]
	}
}

func runCommand(args []string) error {
	flags := flag.NewFlagSet("run", flag.ContinueOnError)
	inputPath := flags.String("input", "", "Path to JSON input")
	outputKind := flags.String("output", "json", "Output format")
	if err := flags.Parse(args); err != nil {
		return invalidRequestError("%v", err)
	}
	if *inputPath == "" {
		return invalidRequestError("--input is required")
	}

	var input activities.RunInput
	if err := readJSON(*inputPath, &input); err != nil {
		return invalidRequestError("%v", err)
	}

	c, err := dialTemporal(input.Temporal)
	if err != nil {
		return classifyTemporalError("connect to Temporal", err)
	}
	defer c.Close()

	options := client.StartWorkflowOptions{
		ID:        input.WorkflowID,
		TaskQueue: input.Temporal.TaskQueue,
	}

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	we, err := c.ExecuteWorkflow(ctx, options, workflows.IssueRunWorkflow, input)
	if err != nil {
		var alreadyStarted *serviceerror.WorkflowExecutionAlreadyStarted
		if errors.As(err, &alreadyStarted) {
			state := activities.BuildWorkflowState(input, alreadyStarted.RunId, "running")
			return printWorkflowResponse(*outputKind, "run", workflowResponseFromState(state, readinessForStatus("running")))
		}
		return classifyTemporalError("start workflow", err)
	}

	state := activities.BuildWorkflowState(input, we.GetRunID(), "running")
	state.WorkflowID = we.GetID()
	state = activities.NormalizeWorkflowState(state, input, "running")
	return printWorkflowResponse(*outputKind, "run", workflowResponseFromState(state, readinessForStatus("running")))
}

func statusCommand(args []string) error {
	return workflowStatusCommand("status", args)
}

func describeCommand(args []string) error {
	return workflowStatusCommand("describe", args)
}

func workflowStatusCommand(subcommand string, args []string) error {
	flags := flag.NewFlagSet(subcommand, flag.ContinueOnError)
	inputPath := flags.String("input", "", "Path to JSON input")
	outputKind := flags.String("output", "json", "Output format")
	if err := flags.Parse(args); err != nil {
		return invalidRequestError("%v", err)
	}
	if *inputPath == "" {
		return invalidRequestError("--input is required")
	}

	var input workflowInput
	if err := readJSON(*inputPath, &input); err != nil {
		return invalidRequestError("%v", err)
	}

	if strings.TrimSpace(input.WorkflowID) == "" {
		return invalidRequestError("workflowId is required")
	}

	c, err := dialTemporal(input.Temporal)
	if err != nil {
		return classifyTemporalError("connect to Temporal", err)
	}
	defer c.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	description, err := c.DescribeWorkflowExecution(ctx, input.WorkflowID, input.RunID)
	if err != nil {
		return classifyTemporalError("describe workflow", err)
	}

	info := description.WorkflowExecutionInfo
	runID := input.RunID
	if runID == "" && info.Execution != nil {
		runID = info.Execution.RunId
	}

	status := workflowStatus(info.Status)
	state := fallbackWorkflowState(input, runID, status)

	if queriedState, err := queryWorkflowState(ctx, c, input, runID, status); err == nil {
		state = queriedState
	}

	return printWorkflowResponse(*outputKind, subcommand, workflowResponseFromState(state, readinessForStatus(status)))
}

func cancelCommand(args []string) error {
	flags := flag.NewFlagSet("cancel", flag.ContinueOnError)
	inputPath := flags.String("input", "", "Path to JSON input")
	outputKind := flags.String("output", "json", "Output format")
	if err := flags.Parse(args); err != nil {
		return invalidRequestError("%v", err)
	}
	if *inputPath == "" {
		return invalidRequestError("--input is required")
	}

	var input workflowInput
	if err := readJSON(*inputPath, &input); err != nil {
		return invalidRequestError("%v", err)
	}

	if strings.TrimSpace(input.WorkflowID) == "" {
		return invalidRequestError("workflowId is required")
	}

	c, err := dialTemporal(input.Temporal)
	if err != nil {
		return classifyTemporalError("connect to Temporal", err)
	}
	defer c.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	if err := c.CancelWorkflow(ctx, input.WorkflowID, input.RunID); err != nil {
		return classifyTemporalError("cancel workflow", err)
	}

	state := fallbackWorkflowState(input, input.RunID, "cancelled")
	return printWorkflowResponse(*outputKind, "cancel", workflowResponseFromState(state, readinessForStatus("cancelled")))
}

func readinessCommand(args []string) error {
	flags := flag.NewFlagSet("readiness", flag.ContinueOnError)
	inputPath := flags.String("input", "", "Path to JSON input")
	outputKind := flags.String("output", "json", "Output format")
	if err := flags.Parse(args); err != nil {
		return invalidRequestError("%v", err)
	}
	if *inputPath == "" {
		return invalidRequestError("--input is required")
	}

	var input readinessInput
	if err := readJSON(*inputPath, &input); err != nil {
		return invalidRequestError("%v", err)
	}

	payload := readinessPayload{
		ExecutionKind: "temporal_k3s",
		Blockers:      []runtimeBlocker{},
		Temporal: temporalReadiness{
			Address:   temporalAddress(input.Temporal),
			Namespace: temporalNamespace(input.Temporal),
			TaskQueue: temporalTaskQueue(input.Temporal),
		},
		K3s: k3sReadiness{
			Namespace: k3sNamespace(input.K3s),
		},
	}

	checkTemporalReadiness(&payload)
	checkK3sReadiness(&payload)
	payload.Ready = len(payload.Blockers) == 0

	return printJSON(*outputKind, payload)
}

func readJSON(path string, target any) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return fmt.Errorf("unable to read %s: %w", path, err)
	}
	if err := json.Unmarshal(data, target); err != nil {
		return fmt.Errorf("unable to decode %s: %w", path, err)
	}
	return nil
}

func printJSON(outputKind string, payload any) error {
	switch strings.ToLower(strings.TrimSpace(outputKind)) {
	case "", "json":
		data, err := json.Marshal(payload)
		if err != nil {
			return err
		}
		_, err = fmt.Fprintln(outputWriter, string(data))
		return err
	default:
		return invalidRequestError("unsupported output format %q", outputKind)
	}
}

func dialTemporal(input activities.TemporalConfig) (temporalClient, error) {
	return dialTemporalClient(temporalClientOptions(input))
}

func temporalClientOptions(input activities.TemporalConfig) client.Options {
	return client.Options{
		HostPort:  temporalAddress(input),
		Namespace: temporalNamespace(input),
	}
}

func temporalAddress(input activities.TemporalConfig) string {
	address := strings.TrimSpace(input.Address)
	if address == "" {
		return envOr("TEMPORAL_ADDRESS", "localhost:7233")
	}
	return address
}

func temporalNamespace(input activities.TemporalConfig) string {
	namespace := strings.TrimSpace(input.Namespace)
	if namespace == "" {
		return envOr("TEMPORAL_NAMESPACE", "default")
	}
	return namespace
}

func temporalTaskQueue(input activities.TemporalConfig) string {
	taskQueue := strings.TrimSpace(input.TaskQueue)
	if taskQueue == "" {
		return envOr("TEMPORAL_TASK_QUEUE", "symphony")
	}
	return taskQueue
}

func k3sNamespace(input activities.K3sConfig) string {
	namespace := strings.TrimSpace(input.Namespace)
	if namespace == "" {
		return envOr("SYMPHONY_K3S_NAMESPACE", "symphony")
	}
	return namespace
}

func checkTemporalReadiness(payload *readinessPayload) {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	c, err := dialTemporal(activities.TemporalConfig{
		Address:   payload.Temporal.Address,
		Namespace: payload.Temporal.Namespace,
		TaskQueue: payload.Temporal.TaskQueue,
	})
	if err != nil {
		appendBlocker(payload, "temporal_unreachable", fmt.Sprintf("unable to connect to Temporal at %s: %v", payload.Temporal.Address, err))
		return
	}
	defer c.Close()

	if _, err := c.GetSystemInfo(ctx); err != nil {
		appendBlocker(payload, "temporal_unreachable", fmt.Sprintf("unable to reach Temporal at %s: %v", payload.Temporal.Address, err))
		return
	}
	payload.Temporal.Reachable = true

	if _, err := c.DescribeNamespace(ctx, payload.Temporal.Namespace); err != nil {
		var namespaceNotFound *serviceerror.NamespaceNotFound
		if errors.As(err, &namespaceNotFound) {
			appendBlocker(payload, "temporal_namespace_missing", fmt.Sprintf("Temporal namespace %q is missing at %s", payload.Temporal.Namespace, payload.Temporal.Address))
		} else {
			appendBlocker(payload, "temporal_namespace_unavailable", fmt.Sprintf("unable to describe Temporal namespace %q at %s: %v", payload.Temporal.Namespace, payload.Temporal.Address, err))
		}
		return
	}
	payload.Temporal.NamespaceReady = true

	workflowDescription, err := c.DescribeTaskQueue(ctx, payload.Temporal.TaskQueue, enumspb.TASK_QUEUE_TYPE_WORKFLOW)
	if err != nil {
		appendBlocker(payload, "temporal_worker_probe_failed", fmt.Sprintf("unable to inspect workflow pollers for task queue %q: %v", payload.Temporal.TaskQueue, err))
		return
	}

	activityDescription, err := c.DescribeTaskQueue(ctx, payload.Temporal.TaskQueue, enumspb.TASK_QUEUE_TYPE_ACTIVITY)
	if err != nil {
		appendBlocker(payload, "temporal_worker_probe_failed", fmt.Sprintf("unable to inspect activity pollers for task queue %q: %v", payload.Temporal.TaskQueue, err))
		return
	}

	payload.Temporal.WorkflowPollers = len(workflowDescription.GetPollers())
	payload.Temporal.ActivityPollers = len(activityDescription.GetPollers())
	payload.Temporal.WorkerReady = payload.Temporal.WorkflowPollers+payload.Temporal.ActivityPollers > 0

	if !payload.Temporal.WorkerReady {
		appendBlocker(payload, "temporal_worker_missing", fmt.Sprintf("no Temporal worker is polling task queue %q in namespace %q", payload.Temporal.TaskQueue, payload.Temporal.Namespace))
	}
}

func checkK3sReadiness(payload *readinessPayload) {
	if launcherPath, err := resolveSjobPath(); err != nil {
		appendBlocker(payload, "k3s_launcher_missing", err.Error())
	} else {
		payload.K3s.LauncherPath = launcherPath
	}

	kubectlCommand, err := resolveKubectlCommand()
	if err != nil {
		appendBlocker(payload, "k3s_prerequisites_broken", err.Error())
		return
	}
	payload.K3s.KubectlCommand = kubectlCommand

	output, err := runExternalCommand(context.Background(), kubectlCommand, []string{"get", "namespace", payload.K3s.Namespace, "-o", "jsonpath={.metadata.name}"})
	if err != nil {
		lower := strings.ToLower(err.Error())
		if strings.Contains(lower, "notfound") || strings.Contains(lower, "not found") {
			appendBlocker(payload, "k3s_namespace_missing", fmt.Sprintf("K3s namespace %q is missing", payload.K3s.Namespace))
		} else {
			appendBlocker(payload, "k3s_prerequisites_broken", fmt.Sprintf("unable to inspect K3s namespace %q: %v", payload.K3s.Namespace, err))
		}
		return
	}

	payload.K3s.NamespaceReady = strings.TrimSpace(output) == payload.K3s.Namespace
	if !payload.K3s.NamespaceReady {
		appendBlocker(payload, "k3s_namespace_missing", fmt.Sprintf("K3s namespace %q is missing", payload.K3s.Namespace))
	}
}

func resolveKubectlCommand() (string, error) {
	if wrapper := strings.TrimSpace(os.Getenv("SYMPHONY_KUBECTL_WRAPPER")); wrapper != "" {
		info, err := os.Stat(wrapper)
		if err != nil {
			return "", fmt.Errorf("kubectl wrapper %q is unavailable: %w", wrapper, err)
		}
		if info.Mode()&0o111 == 0 {
			return "", fmt.Errorf("kubectl wrapper %q is not executable", wrapper)
		}
		return wrapper, nil
	}

	path, err := exec.LookPath("kubectl")
	if err != nil {
		return "", errors.New("kubectl not found; set SYMPHONY_KUBECTL_WRAPPER or install kubectl")
	}
	return path, nil
}

func resolveSjobPath() (string, error) {
	if home := strings.TrimSpace(os.Getenv("SYMPHONY_HOME")); home != "" {
		path := filepath.Join(home, "k3s", "bin", "sjob")
		if _, err := os.Stat(path); err == nil {
			return path, nil
		}
	}

	cwd, err := os.Getwd()
	if err != nil {
		return "", err
	}

	candidates := []string{
		filepath.Join(cwd, "k3s", "bin", "sjob"),
		filepath.Join(cwd, "..", "k3s", "bin", "sjob"),
	}

	for _, candidate := range candidates {
		if _, err := os.Stat(candidate); err == nil {
			return candidate, nil
		}
	}

	return "", errors.New("unable to locate k3s/bin/sjob; set SYMPHONY_HOME")
}

func appendBlocker(payload *readinessPayload, code, message string) {
	payload.Blockers = append(payload.Blockers, runtimeBlocker{Code: code, Message: message})
}

func runExternalCommand(ctx context.Context, binary string, args []string) (string, error) {
	cmd := exec.CommandContext(ctx, binary, args...)
	output, err := cmd.CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("%s %s failed: %w output=%s", binary, strings.Join(args, " "), err, strings.TrimSpace(string(output)))
	}
	return strings.TrimSpace(string(output)), nil
}

func workflowStatus(status enumspb.WorkflowExecutionStatus) string {
	switch status {
	case enumspb.WORKFLOW_EXECUTION_STATUS_RUNNING:
		return "running"
	case enumspb.WORKFLOW_EXECUTION_STATUS_COMPLETED:
		return "succeeded"
	case enumspb.WORKFLOW_EXECUTION_STATUS_FAILED:
		return "failed"
	case enumspb.WORKFLOW_EXECUTION_STATUS_CANCELED, enumspb.WORKFLOW_EXECUTION_STATUS_TERMINATED:
		return "cancelled"
	default:
		return "running"
	}
}

func queryWorkflowState(ctx context.Context, c temporalClient, input workflowInput, runID, status string) (activities.WorkflowState, error) {
	queryValue, err := c.QueryWorkflow(ctx, input.WorkflowID, runID, "symphony_state")
	if err != nil {
		return activities.WorkflowState{}, err
	}

	var state activities.WorkflowState
	if err := queryValue.Get(&state); err != nil {
		return activities.WorkflowState{}, err
	}

	return activities.NormalizeWorkflowState(state, workflowStateInput(input, runID), status), nil
}

func fallbackWorkflowState(input workflowInput, runID, status string) activities.WorkflowState {
	return activities.BuildWorkflowState(workflowStateInput(input, runID), runID, status)
}

func workflowStateInput(input workflowInput, runID string) activities.RunInput {
	return activities.RunInput{
		WorkflowID:   input.WorkflowID,
		RunID:        runID,
		WorkflowMode: input.WorkflowMode,
		Temporal:     input.Temporal,
	}
}

func workflowResponseFromState(state activities.WorkflowState, readiness *contracts.ReadinessDetail) contracts.WorkflowResponse {
	return contracts.WorkflowResponse{
		WorkflowID:    state.WorkflowID,
		RunID:         state.RunID,
		Status:        state.Status,
		ProjectID:     state.ProjectID,
		WorkspacePath: state.WorkspacePath,
		ArtifactDir:   state.ArtifactDir,
		JobName:       state.JobName,
		WorkflowMode:  state.WorkflowMode,
		CurrentPhase:  state.CurrentPhase,
		Phases:        contractPhases(state.Phases),
		Readiness:     readiness,
	}
}

func contractPhases(phases []activities.PhaseState) []contracts.PhaseResponse {
	if len(phases) == 0 {
		return nil
	}

	normalized := make([]contracts.PhaseResponse, 0, len(phases))
	for _, phase := range phases {
		normalized = append(normalized, contracts.PhaseResponse{
			Name:          phase.Name,
			Status:        phase.Status,
			JobName:       phase.JobName,
			ArtifactDir:   phase.ArtifactDir,
			WorkspacePath: phase.WorkspacePath,
		})
	}

	return normalized
}

func envOr(key, fallback string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return fallback
}

func printWorkflowResponse(outputKind, subcommand string, response contracts.WorkflowResponse) error {
	if err := response.Validate(subcommand); err != nil {
		return invalidRequestError("%v", err)
	}
	return printJSON(outputKind, response)
}

func writeCLIError(err error) error {
	envelope := contracts.ErrorEnvelope{Error: failureDetail(err)}
	if writeErr := envelope.Error.Validate(); writeErr != nil {
		return writeErr
	}

	data, marshalErr := json.Marshal(envelope)
	if marshalErr != nil {
		return marshalErr
	}

	_, writeErr := fmt.Fprintln(errorWriter, string(data))
	return writeErr
}

func readinessForStatus(status string) *contracts.ReadinessDetail {
	switch strings.ToLower(strings.TrimSpace(status)) {
	case "succeeded":
		return &contracts.ReadinessDetail{State: contracts.ReadinessReady, Reason: "workflow-succeeded"}
	case "failed":
		return &contracts.ReadinessDetail{State: contracts.ReadinessNotReady, Reason: "workflow-failed"}
	case "cancelled":
		return &contracts.ReadinessDetail{State: contracts.ReadinessNotReady, Reason: "workflow-cancelled"}
	default:
		return &contracts.ReadinessDetail{State: contracts.ReadinessPending, Reason: "workflow-active"}
	}
}

type cliError struct {
	Code      string
	Message   string
	Retryable bool
	Err       error
}

func (e *cliError) Error() string {
	return e.Message
}

func (e *cliError) Unwrap() error {
	return e.Err
}

func invalidRequestError(format string, args ...any) error {
	return &cliError{
		Code:      "invalid_request",
		Message:   fmt.Sprintf(format, args...),
		Retryable: false,
	}
}

func classifyTemporalError(action string, err error) error {
	var unavailable *serviceerror.Unavailable
	if errors.As(err, &unavailable) {
		return &cliError{
			Code:      "temporal_unavailable",
			Message:   fmt.Sprintf("unable to %s: %v", action, err),
			Retryable: true,
			Err:       err,
		}
	}

	var notFound *serviceerror.NotFound
	if errors.As(err, &notFound) {
		return &cliError{
			Code:      "workflow_not_found",
			Message:   fmt.Sprintf("unable to %s: %v", action, err),
			Retryable: false,
			Err:       err,
		}
	}

	var namespaceNotFound *serviceerror.NamespaceNotFound
	if errors.As(err, &namespaceNotFound) {
		return &cliError{
			Code:      "temporal_namespace_not_found",
			Message:   fmt.Sprintf("unable to %s: %v", action, err),
			Retryable: false,
			Err:       err,
		}
	}

	return &cliError{
		Code:      "temporal_request_failed",
		Message:   fmt.Sprintf("unable to %s: %v", action, err),
		Retryable: true,
		Err:       err,
	}
}

func failureDetail(err error) contracts.FailureDetail {
	var cliErr *cliError
	if errors.As(err, &cliErr) {
		return contracts.FailureDetail{
			Code:      cliErr.Code,
			Message:   cliErr.Message,
			Retryable: cliErr.Retryable,
		}
	}

	return contracts.FailureDetail{
		Code:      "internal_error",
		Message:   err.Error(),
		Retryable: true,
	}
}
