package workflows

import (
	"time"

	"go.temporal.io/sdk/temporal"
	"go.temporal.io/sdk/workflow"

	"symphony-temporal/internal/activities"
)

func IssueRunWorkflow(ctx workflow.Context, input activities.RunInput) (activities.RunResult, error) {
	info := workflow.GetInfo(ctx)

	input.WorkflowID = info.WorkflowExecution.ID
	input.RunID = info.WorkflowExecution.RunID
	input.WorkflowMode = activities.NormalizeWorkflowMode(input.WorkflowMode)

	state := activities.BuildWorkflowState(input, input.RunID, "running")
	if err := workflow.SetQueryHandler(ctx, "symphony_state", func() (activities.WorkflowState, error) {
		return state, nil
	}); err != nil {
		return activities.RunResult{}, err
	}

	activityOptions := workflow.ActivityOptions{
		StartToCloseTimeout: 24 * time.Hour,
		RetryPolicy: &temporal.RetryPolicy{
			InitialInterval:    10 * time.Second,
			BackoffCoefficient: 2.0,
			MaximumInterval:    2 * time.Minute,
			MaximumAttempts:    3,
		},
	}

	ctx = workflow.WithActivityOptions(ctx, activityOptions)

	var result activities.RunResult
	err := workflow.ExecuteActivity(ctx, activities.RunIssueJob, input).Get(ctx, &result)
	if err != nil {
		switch {
		case temporal.IsCanceledError(err):
			state.Status = "cancelled"
		default:
			state.Status = "failed"
		}
		state = activities.NormalizeWorkflowState(state, input, state.Status)
		return result, err
	}

	result.WorkflowID = input.WorkflowID
	result.RunID = input.RunID
	result.Status = activities.NormalizeWorkflowStatus(result.Status)
	state.Status = result.Status
	state = activities.NormalizeWorkflowState(state, input, state.Status)
	return result, nil
}
