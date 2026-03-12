package activities

import (
	"path/filepath"
	"strings"
)

const (
	WorkflowModePhased  = "phased"
	WorkflowModeVanilla = "vanilla"

	DefaultWorkflowMode = WorkflowModePhased

	PhaseExecute = "execute"
	PhaseRun     = "run"
)

type PhaseState struct {
	Name          string `json:"name"`
	Status        string `json:"status"`
	JobName       string `json:"jobName,omitempty"`
	ArtifactDir   string `json:"artifactDir,omitempty"`
	WorkspacePath string `json:"workspacePath,omitempty"`
}

type WorkflowState struct {
	WorkflowID    string       `json:"workflowId,omitempty"`
	RunID         string       `json:"runId,omitempty"`
	Status        string       `json:"status,omitempty"`
	ProjectID     string       `json:"projectId,omitempty"`
	WorkspacePath string       `json:"workspacePath,omitempty"`
	ArtifactDir   string       `json:"artifactDir,omitempty"`
	JobName       string       `json:"jobName,omitempty"`
	WorkflowMode  string       `json:"workflow_mode"`
	CurrentPhase  string       `json:"current_phase"`
	Phases        []PhaseState `json:"phases"`
}

func NormalizeWorkflowMode(value string) string {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case WorkflowModeVanilla:
		return WorkflowModeVanilla
	case WorkflowModePhased:
		return WorkflowModePhased
	default:
		return DefaultWorkflowMode
	}
}

func DefaultPhaseForWorkflowMode(workflowMode string) string {
	switch NormalizeWorkflowMode(workflowMode) {
	case WorkflowModeVanilla:
		return PhaseRun
	default:
		// REV-23 keeps the legacy single-job path while reserving execute as the
		// normalized phased placeholder until the full multi-phase workflow lands.
		return PhaseExecute
	}
}

func NormalizeWorkflowStatus(value string) string {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "", "running":
		return "running"
	case "completed", "success", "succeeded":
		return "succeeded"
	case "failed":
		return "failed"
	case "terminated", "canceled", "cancelled":
		return "cancelled"
	case "queued", "pending":
		return "queued"
	default:
		return strings.ToLower(strings.TrimSpace(value))
	}
}

func BuildWorkflowState(input RunInput, runID, status string) WorkflowState {
	artifactDir := ""
	if strings.TrimSpace(input.Paths.OutputsPath) != "" && strings.TrimSpace(runID) != "" {
		artifactDir = filepath.Join(input.Paths.OutputsPath, runID)
	}

	return NormalizeWorkflowState(WorkflowState{
		WorkflowID:    input.WorkflowID,
		RunID:         runID,
		Status:        status,
		ProjectID:     input.ProjectID,
		WorkspacePath: input.Paths.WorkspacePath,
		ArtifactDir:   artifactDir,
		JobName:       defaultJobName(input.ProjectID, input.WorkflowID, runID),
		WorkflowMode:  input.WorkflowMode,
	}, input, status)
}

func NormalizeWorkflowState(state WorkflowState, input RunInput, fallbackStatus string) WorkflowState {
	normalizedStatus := NormalizeWorkflowStatus(firstNonBlank(state.Status, fallbackStatus))
	normalizedMode := NormalizeWorkflowMode(firstNonBlank(state.WorkflowMode, input.WorkflowMode))
	currentPhase := strings.TrimSpace(state.CurrentPhase)

	if currentPhase == "" && len(state.Phases) > 0 {
		currentPhase = strings.TrimSpace(state.Phases[len(state.Phases)-1].Name)
	}
	if currentPhase == "" {
		currentPhase = DefaultPhaseForWorkflowMode(normalizedMode)
	}

	if strings.TrimSpace(state.WorkflowID) == "" {
		state.WorkflowID = input.WorkflowID
	}
	if strings.TrimSpace(state.RunID) == "" {
		state.RunID = input.RunID
	}
	if strings.TrimSpace(state.ProjectID) == "" {
		state.ProjectID = input.ProjectID
	}
	if strings.TrimSpace(state.WorkspacePath) == "" {
		state.WorkspacePath = input.Paths.WorkspacePath
	}
	if strings.TrimSpace(state.ArtifactDir) == "" && strings.TrimSpace(input.Paths.OutputsPath) != "" && strings.TrimSpace(state.RunID) != "" {
		state.ArtifactDir = filepath.Join(input.Paths.OutputsPath, state.RunID)
	}
	if strings.TrimSpace(state.JobName) == "" && strings.TrimSpace(state.WorkflowID) != "" && strings.TrimSpace(state.RunID) != "" {
		state.JobName = defaultJobName(state.ProjectID, state.WorkflowID, state.RunID)
	}

	state.Status = normalizedStatus
	state.WorkflowMode = normalizedMode
	state.CurrentPhase = currentPhase
	state.Phases = normalizePhases(state.Phases, state)

	return state
}

func normalizePhases(phases []PhaseState, state WorkflowState) []PhaseState {
	if len(phases) == 0 {
		return []PhaseState{{
			Name:          state.CurrentPhase,
			Status:        state.Status,
			JobName:       state.JobName,
			ArtifactDir:   state.ArtifactDir,
			WorkspacePath: state.WorkspacePath,
		}}
	}

	normalized := make([]PhaseState, 0, len(phases))
	for _, phase := range phases {
		name := strings.TrimSpace(phase.Name)
		if name == "" {
			name = state.CurrentPhase
		}

		phaseStatus := NormalizeWorkflowStatus(phase.Status)
		if phaseStatus == "" {
			if name == state.CurrentPhase {
				phaseStatus = state.Status
			} else {
				phaseStatus = "queued"
			}
		}

		if strings.TrimSpace(phase.JobName) == "" {
			phase.JobName = state.JobName
		}
		if strings.TrimSpace(phase.ArtifactDir) == "" {
			phase.ArtifactDir = state.ArtifactDir
		}
		if strings.TrimSpace(phase.WorkspacePath) == "" {
			phase.WorkspacePath = state.WorkspacePath
		}

		normalized = append(normalized, PhaseState{
			Name:          name,
			Status:        phaseStatus,
			JobName:       phase.JobName,
			ArtifactDir:   phase.ArtifactDir,
			WorkspacePath: phase.WorkspacePath,
		})
	}

	return normalized
}

func firstNonBlank(values ...string) string {
	for _, value := range values {
		if trimmed := strings.TrimSpace(value); trimmed != "" {
			return trimmed
		}
	}

	return ""
}

func defaultJobName(projectID, workflowID, runID string) string {
	if strings.TrimSpace(projectID) != "" {
		return JobResourceName(projectID, workflowID, runID)
	}

	return ""
}
