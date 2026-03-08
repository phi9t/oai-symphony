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
		return result, err
	}

	result.WorkflowID = input.WorkflowID
	result.RunID = input.RunID
	return result, nil
}
