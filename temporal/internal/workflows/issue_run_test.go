package workflows

import (
	"context"
	"errors"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/mock"
	"go.temporal.io/sdk/client"
	"go.temporal.io/sdk/temporal"
	"go.temporal.io/sdk/testsuite"

	"symphony-temporal/internal/activities"
)

func TestIssueRunWorkflowCarriesWorkflowIdentifiersIntoActivityAndResult(t *testing.T) {
	var suite testsuite.WorkflowTestSuite
	env := suite.NewTestWorkflowEnvironment()
	env.SetStartWorkflowOptions(client.StartWorkflowOptions{ID: "issue/REV-19"})

	var captured activities.RunInput

	env.OnActivity(activities.RunIssueJob, mock.Anything, mock.Anything).Return(
		func(_ context.Context, input activities.RunInput) (activities.RunResult, error) {
			captured = input
			return activities.RunResult{
				Status:        "succeeded",
				ProjectID:     input.ProjectID,
				WorkspacePath: input.Paths.WorkspacePath,
				ArtifactDir:   filepath.Join(input.Paths.OutputsPath, input.RunID),
				JobName:       activities.JobResourceName(input.ProjectID, input.WorkflowID, input.RunID),
			}, nil
		},
	).Once()

	env.ExecuteWorkflow(IssueRunWorkflow, newWorkflowInput())
	if err := env.GetWorkflowError(); err != nil {
		t.Fatalf("workflow returned error: %v", err)
	}

	if captured.WorkflowID != "issue/REV-19" {
		t.Fatalf("expected workflow ID issue/REV-19, got %q", captured.WorkflowID)
	}
	if captured.RunID == "" {
		t.Fatalf("expected workflow run ID to be populated")
	}

	var result activities.RunResult
	if err := env.GetWorkflowResult(&result); err != nil {
		t.Fatalf("unable to decode workflow result: %v", err)
	}

	if result.WorkflowID != captured.WorkflowID || result.RunID != captured.RunID {
		t.Fatalf("expected workflow result identifiers to match activity input, got %#v and %#v", result, captured)
	}
}

func TestIssueRunWorkflowRetriesDependencyFailuresWithStableIdentifiers(t *testing.T) {
	var suite testsuite.WorkflowTestSuite
	env := suite.NewTestWorkflowEnvironment()
	env.SetStartWorkflowOptions(client.StartWorkflowOptions{ID: "issue/REV-19"})

	var attempts int
	var captured []activities.RunInput

	env.OnActivity(activities.RunIssueJob, mock.Anything, mock.Anything).Return(
		func(_ context.Context, input activities.RunInput) (activities.RunResult, error) {
			attempts++
			captured = append(captured, input)
			if attempts < 3 {
				return activities.RunResult{}, temporal.NewApplicationError("k3s status failed", "k3s_status_failed")
			}

			return activities.RunResult{
				Status:        "succeeded",
				ProjectID:     input.ProjectID,
				WorkspacePath: input.Paths.WorkspacePath,
				ArtifactDir:   filepath.Join(input.Paths.OutputsPath, input.RunID),
				JobName:       activities.JobResourceName(input.ProjectID, input.WorkflowID, input.RunID),
			}, nil
		},
	)

	env.ExecuteWorkflow(IssueRunWorkflow, newWorkflowInput())
	if err := env.GetWorkflowError(); err != nil {
		t.Fatalf("workflow returned error: %v", err)
	}

	if attempts != 3 {
		t.Fatalf("expected three activity attempts, got %d", attempts)
	}
	if len(captured) != 3 {
		t.Fatalf("expected three captured activity inputs, got %d", len(captured))
	}

	first := captured[0]
	for attempt, input := range captured[1:] {
		if input.WorkflowID != first.WorkflowID || input.RunID != first.RunID {
			t.Fatalf("expected stable workflow identifiers across retry attempt %d: %#v vs %#v", attempt+2, first, input)
		}
	}
}

func TestIssueRunWorkflowStopsRetryingForNonRetryableArtifactFailures(t *testing.T) {
	var suite testsuite.WorkflowTestSuite
	env := suite.NewTestWorkflowEnvironment()
	env.SetStartWorkflowOptions(client.StartWorkflowOptions{ID: "issue/REV-19"})

	var attempts int

	env.OnActivity(activities.RunIssueJob, mock.Anything, mock.Anything).Return(
		func(_ context.Context, _ activities.RunInput) (activities.RunResult, error) {
			attempts++
			return activities.RunResult{}, temporal.NewNonRetryableApplicationError("run-result.json missing", "missing_run_result", nil)
		},
	).Once()

	env.ExecuteWorkflow(IssueRunWorkflow, newWorkflowInput())
	err := env.GetWorkflowError()
	if err == nil {
		t.Fatalf("expected workflow to fail on missing_run_result")
	}

	if attempts != 1 {
		t.Fatalf("expected one activity attempt for non-retryable error, got %d", attempts)
	}

	var activityErr *temporal.ActivityError
	if !errors.As(err, &activityErr) {
		t.Fatalf("expected workflow error to unwrap to activity error, got %T: %v", err, err)
	}

	var applicationErr *temporal.ApplicationError
	if !errors.As(err, &applicationErr) {
		t.Fatalf("expected workflow error to unwrap to application error, got %T: %v", err, err)
	}
	if applicationErr.Type() != "missing_run_result" {
		t.Fatalf("expected application error type missing_run_result, got %q", applicationErr.Type())
	}
}

func newWorkflowInput() activities.RunInput {
	return activities.RunInput{
		ProjectID: "REV-19",
		Paths: activities.PathConfig{
			WorkspacePath: "/tmp/project/workspace",
			OutputsPath:   "/tmp/project/outputs",
		},
	}
}
