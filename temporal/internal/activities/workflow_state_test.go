package activities

import "testing"

func TestNormalizeWorkflowStatePromotesCurrentPhaseToTerminalStatus(t *testing.T) {
	input := RunInput{
		WorkflowID:   "issue/1",
		RunID:        "run-001",
		ProjectID:    "REV-26",
		WorkflowMode: WorkflowModePhased,
		Paths: PathConfig{
			WorkspacePath: "/tmp/workspace",
			OutputsPath:   "/tmp/outputs",
		},
	}

	state := NormalizeWorkflowState(
		WorkflowState{
			WorkflowID:   input.WorkflowID,
			RunID:        input.RunID,
			Status:       "succeeded",
			WorkflowMode: input.WorkflowMode,
			CurrentPhase: PhaseExecute,
			Phases: []PhaseState{
				{Name: PhaseExecute, Status: "running"},
			},
		},
		input,
		"succeeded",
	)

	if len(state.Phases) != 1 || state.Phases[0].Status != "succeeded" {
		t.Fatalf("expected terminal phase status to be promoted, got %#v", state.Phases)
	}
}

func TestNormalizeWorkflowStatePreservesCompletedPhasesWhenCurrentPhaseFails(t *testing.T) {
	input := RunInput{
		WorkflowID:   "issue/1",
		RunID:        "run-002",
		ProjectID:    "REV-26",
		WorkflowMode: WorkflowModePhased,
		Paths: PathConfig{
			WorkspacePath: "/tmp/workspace",
			OutputsPath:   "/tmp/outputs",
		},
	}

	state := NormalizeWorkflowState(
		WorkflowState{
			WorkflowID:   input.WorkflowID,
			RunID:        input.RunID,
			Status:       "failed",
			WorkflowMode: input.WorkflowMode,
			CurrentPhase: "review",
			Phases: []PhaseState{
				{Name: "execute", Status: "succeeded"},
				{Name: "review", Status: "running"},
			},
		},
		input,
		"failed",
	)

	if len(state.Phases) != 2 {
		t.Fatalf("expected two phases, got %#v", state.Phases)
	}
	if state.Phases[0].Status != "succeeded" {
		t.Fatalf("expected completed phase to remain succeeded, got %#v", state.Phases)
	}
	if state.Phases[1].Status != "failed" {
		t.Fatalf("expected current phase to become failed, got %#v", state.Phases)
	}
}
