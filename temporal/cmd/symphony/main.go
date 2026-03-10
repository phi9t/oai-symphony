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

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, err)
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
		return fmt.Errorf("unknown subcommand %q", subcommand)
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
		return err
	}
	if *inputPath == "" {
		return errors.New("--input is required")
	}

	var input activities.RunInput
	if err := readJSON(*inputPath, &input); err != nil {
		return err
	}

	c, err := dialTemporal(input.Temporal)
	if err != nil {
		return err
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
			return printJSON(*outputKind, map[string]any{
				"workflowId":    input.WorkflowID,
				"runId":         alreadyStarted.RunId,
				"status":        "running",
				"projectId":     input.ProjectID,
				"workspacePath": input.Paths.WorkspacePath,
				"artifactDir":   filepath.Join(input.Paths.OutputsPath, alreadyStarted.RunId),
				"jobName":       activities.JobName(input.WorkflowID, alreadyStarted.RunId),
			})
		}
		return fmt.Errorf("unable to start workflow: %w", err)
	}

	return printJSON(*outputKind, map[string]any{
		"workflowId":    we.GetID(),
		"runId":         we.GetRunID(),
		"status":        "running",
		"projectId":     input.ProjectID,
		"workspacePath": input.Paths.WorkspacePath,
		"artifactDir":   filepath.Join(input.Paths.OutputsPath, we.GetRunID()),
		"jobName":       activities.JobName(we.GetID(), we.GetRunID()),
	})
}

func statusCommand(args []string) error {
	flags := flag.NewFlagSet("status", flag.ContinueOnError)
	inputPath := flags.String("input", "", "Path to JSON input")
	outputKind := flags.String("output", "json", "Output format")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if *inputPath == "" {
		return errors.New("--input is required")
	}

	var input workflowInput
	if err := readJSON(*inputPath, &input); err != nil {
		return err
	}

	if strings.TrimSpace(input.WorkflowID) == "" {
		return errors.New("workflowId is required")
	}

	c, err := dialTemporal(input.Temporal)
	if err != nil {
		return fmt.Errorf("unable to create Temporal client: %w", err)
	}
	defer c.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	description, err := c.DescribeWorkflowExecution(ctx, input.WorkflowID, input.RunID)
	if err != nil {
		return fmt.Errorf("unable to describe workflow: %w", err)
	}

	info := description.WorkflowExecutionInfo
	runID := input.RunID
	if runID == "" && info.Execution != nil {
		runID = info.Execution.RunId
	}

	return printJSON(*outputKind, map[string]any{
		"workflowId": input.WorkflowID,
		"runId":      runID,
		"status":     workflowStatus(info.Status),
	})
}

func cancelCommand(args []string) error {
	flags := flag.NewFlagSet("cancel", flag.ContinueOnError)
	inputPath := flags.String("input", "", "Path to JSON input")
	outputKind := flags.String("output", "json", "Output format")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if *inputPath == "" {
		return errors.New("--input is required")
	}

	var input workflowInput
	if err := readJSON(*inputPath, &input); err != nil {
		return err
	}

	if strings.TrimSpace(input.WorkflowID) == "" {
		return errors.New("workflowId is required")
	}

	c, err := dialTemporal(input.Temporal)
	if err != nil {
		return fmt.Errorf("unable to create Temporal client: %w", err)
	}
	defer c.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	if err := c.CancelWorkflow(ctx, input.WorkflowID, input.RunID); err != nil {
		return fmt.Errorf("unable to cancel workflow: %w", err)
	}

	return printJSON(*outputKind, map[string]any{
		"workflowId": input.WorkflowID,
		"runId":      input.RunID,
		"status":     "cancelled",
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

func printJSON(outputKind string, payload map[string]any) error {
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
