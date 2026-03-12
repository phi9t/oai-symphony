package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"

	enumspb "go.temporal.io/api/enums/v1"
	"go.temporal.io/api/serviceerror"
	workflowservice "go.temporal.io/api/workflowservice/v1"
	"go.temporal.io/sdk/client"

	"symphony-temporal/internal/activities"
	"symphony-temporal/internal/contracts"
	"symphony-temporal/internal/workflows"
)

type workflowInput struct {
	WorkflowID string                    `json:"workflowId"`
	RunID      string                    `json:"runId"`
	Temporal   activities.TemporalConfig `json:"temporal"`
}

type temporalClient interface {
	ExecuteWorkflow(ctx context.Context, options client.StartWorkflowOptions, workflow interface{}, args ...interface{}) (client.WorkflowRun, error)
	DescribeWorkflowExecution(ctx context.Context, workflowID string, runID string) (*workflowservice.DescribeWorkflowExecutionResponse, error)
	CancelWorkflow(ctx context.Context, workflowID string, runID string) error
	Close()
}

var dialTemporalClient = func(options client.Options) (temporalClient, error) {
	return client.Dial(options)
}

var outputWriter io.Writer = os.Stdout
var errorWriter io.Writer = os.Stderr

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
		return statusCommand(rest)
	default:
		return invalidRequestError("unknown subcommand %q", subcommand)
	}
}

func parseSubcommand(args []string) (string, []string) {
	if len(args) == 0 {
		return "run", args
	}
	switch args[0] {
	case "run", "status", "cancel", "describe":
		return args[0], args[1:]
	default:
		return "run", args
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
			return printWorkflowResponse(*outputKind, "run", contracts.WorkflowResponse{
				WorkflowID:    input.WorkflowID,
				RunID:         alreadyStarted.RunId,
				Status:        "running",
				ProjectID:     input.ProjectID,
				WorkspacePath: input.Paths.WorkspacePath,
				ArtifactDir:   filepath.Join(input.Paths.OutputsPath, alreadyStarted.RunId),
				JobName:       activities.JobResourceName(input.ProjectID, input.WorkflowID, alreadyStarted.RunId),
				Readiness:     readinessForStatus("running"),
			})
		}
		return classifyTemporalError("start workflow", err)
	}

	return printWorkflowResponse(*outputKind, "run", contracts.WorkflowResponse{
		WorkflowID:    we.GetID(),
		RunID:         we.GetRunID(),
		Status:        "running",
		ProjectID:     input.ProjectID,
		WorkspacePath: input.Paths.WorkspacePath,
		ArtifactDir:   filepath.Join(input.Paths.OutputsPath, we.GetRunID()),
		JobName:       activities.JobResourceName(input.ProjectID, we.GetID(), we.GetRunID()),
		Readiness:     readinessForStatus("running"),
	})
}

func statusCommand(args []string) error {
	flags := flag.NewFlagSet("status", flag.ContinueOnError)
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

	return printWorkflowResponse(*outputKind, "status", contracts.WorkflowResponse{
		WorkflowID: input.WorkflowID,
		RunID:      runID,
		Status:     status,
		Readiness:  readinessForStatus(status),
	})
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

	return printWorkflowResponse(*outputKind, "cancel", contracts.WorkflowResponse{
		WorkflowID: input.WorkflowID,
		RunID:      input.RunID,
		Status:     "cancelled",
		Readiness:  readinessForStatus("cancelled"),
	})
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
		return fmt.Errorf("unsupported output format %q", outputKind)
	}
}

func dialTemporal(input activities.TemporalConfig) (temporalClient, error) {
	return dialTemporalClient(temporalClientOptions(input))
}

func temporalClientOptions(input activities.TemporalConfig) client.Options {
	address := input.Address
	if strings.TrimSpace(address) == "" {
		address = envOr("TEMPORAL_ADDRESS", "localhost:7233")
	}
	namespace := input.Namespace
	if strings.TrimSpace(namespace) == "" {
		namespace = envOr("TEMPORAL_NAMESPACE", "default")
	}
	return client.Options{HostPort: address, Namespace: namespace}
}

func workflowStatus(status enumspb.WorkflowExecutionStatus) string {
	switch status {
	case enumspb.WORKFLOW_EXECUTION_STATUS_RUNNING:
		return "running"
	case enumspb.WORKFLOW_EXECUTION_STATUS_COMPLETED:
		return "succeeded"
	case enumspb.WORKFLOW_EXECUTION_STATUS_FAILED:
		return "failed"
	case enumspb.WORKFLOW_EXECUTION_STATUS_CANCELED:
		return "cancelled"
	case enumspb.WORKFLOW_EXECUTION_STATUS_TERMINATED:
		return "cancelled"
	default:
		return "running"
	}
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
