package contracts

import (
	"encoding/json"
	"fmt"
	"strings"
)

const (
	ReadinessPending  = "pending"
	ReadinessReady    = "ready"
	ReadinessNotReady = "not_ready"
)

var allowedRunResultStates = map[string]struct{}{
	"succeeded": {},
	"failed":    {},
}

var allowedTargetStates = map[string]struct{}{
	"Done":         {},
	"Human Review": {},
	"In Progress":  {},
	"Rework":       {},
}

var allowedReadinessStates = map[string]struct{}{
	ReadinessPending:  {},
	ReadinessReady:    {},
	ReadinessNotReady: {},
}

type FailureDetail struct {
	Code      string `json:"code"`
	Message   string `json:"message"`
	Retryable bool   `json:"retryable"`
}

type ErrorEnvelope struct {
	Error FailureDetail `json:"error"`
}

type ReadinessDetail struct {
	State  string `json:"state"`
	Reason string `json:"reason"`
}

type PhaseResponse struct {
	Name          string `json:"name"`
	Status        string `json:"status"`
	JobName       string `json:"jobName,omitempty"`
	ArtifactDir   string `json:"artifactDir,omitempty"`
	WorkspacePath string `json:"workspacePath,omitempty"`
}

type WorkflowResponse struct {
	WorkflowID    string           `json:"workflowId,omitempty"`
	RunID         string           `json:"runId,omitempty"`
	Status        string           `json:"status,omitempty"`
	ProjectID     string           `json:"projectId,omitempty"`
	WorkspacePath string           `json:"workspacePath,omitempty"`
	ArtifactDir   string           `json:"artifactDir,omitempty"`
	JobName       string           `json:"jobName,omitempty"`
	WorkflowMode  string           `json:"workflow_mode,omitempty"`
	CurrentPhase  string           `json:"current_phase,omitempty"`
	Phases        []PhaseResponse  `json:"phases,omitempty"`
	Readiness     *ReadinessDetail `json:"readiness,omitempty"`
	Failure       *FailureDetail   `json:"failure,omitempty"`
}

type RunResultArtifact struct {
	Status            string   `json:"status"`
	TargetState       string   `json:"targetState"`
	Summary           string   `json:"summary"`
	Validation        []string `json:"validation"`
	BlockedReason     any      `json:"blockedReason"`
	NeedsContinuation bool     `json:"needsContinuation"`
}

func (d FailureDetail) Validate() error {
	if strings.TrimSpace(d.Code) == "" {
		return fmt.Errorf("failure.code is required")
	}
	if strings.TrimSpace(d.Message) == "" {
		return fmt.Errorf("failure.message is required")
	}
	return nil
}

func (r ReadinessDetail) Validate() error {
	if _, ok := allowedReadinessStates[strings.TrimSpace(r.State)]; !ok {
		return fmt.Errorf("unsupported readiness.state %q", r.State)
	}
	if strings.TrimSpace(r.Reason) == "" {
		return fmt.Errorf("readiness.reason is required")
	}
	return nil
}

func (p PhaseResponse) Validate() error {
	if strings.TrimSpace(p.Name) == "" {
		return fmt.Errorf("name is required")
	}
	if strings.TrimSpace(p.Status) == "" {
		return fmt.Errorf("status is required")
	}

	return nil
}

func (r WorkflowResponse) Validate(subcommand string) error {
	if strings.TrimSpace(r.WorkflowID) == "" {
		return fmt.Errorf("workflowId is required")
	}

	switch subcommand {
	case "run":
		if err := requireFields(
			map[string]string{
				"runId":         r.RunID,
				"status":        r.Status,
				"projectId":     r.ProjectID,
				"workspacePath": r.WorkspacePath,
				"artifactDir":   r.ArtifactDir,
				"jobName":       r.JobName,
			},
		); err != nil {
			return err
		}
	case "status", "describe":
		if err := requireFields(
			map[string]string{
				"runId":  r.RunID,
				"status": r.Status,
			},
		); err != nil {
			return err
		}
	case "cancel":
		if err := requireFields(
			map[string]string{
				"status": r.Status,
			},
		); err != nil {
			return err
		}
	default:
		return fmt.Errorf("unsupported subcommand %q", subcommand)
	}

	if r.Readiness != nil {
		if err := r.Readiness.Validate(); err != nil {
			return err
		}
	}

	if r.Failure != nil {
		if err := r.Failure.Validate(); err != nil {
			return err
		}
	}

	for index, phase := range r.Phases {
		if err := phase.Validate(); err != nil {
			return fmt.Errorf("phases[%d]: %w", index, err)
		}
	}

	return nil
}

func (r RunResultArtifact) Validate() error {
	if _, ok := allowedRunResultStates[strings.TrimSpace(r.Status)]; !ok {
		return fmt.Errorf("unsupported status %q", r.Status)
	}

	if strings.TrimSpace(r.Summary) == "" {
		return fmt.Errorf("summary is required")
	}

	if r.Validation == nil {
		return fmt.Errorf("validation is required")
	}

	if _, ok := allowedTargetStates[strings.TrimSpace(r.TargetState)]; !ok {
		return fmt.Errorf("unsupported targetState %q", r.TargetState)
	}

	switch blockedReason := r.BlockedReason.(type) {
	case nil:
	case string:
		if strings.TrimSpace(blockedReason) == "" {
			return fmt.Errorf("blockedReason must be null or a non-empty string")
		}
	default:
		return fmt.Errorf("blockedReason must be null or a string")
	}

	return nil
}

func DecodeRunResult(data []byte) (RunResultArtifact, error) {
	var artifact RunResultArtifact
	if err := json.Unmarshal(data, &artifact); err != nil {
		return RunResultArtifact{}, err
	}
	if err := artifact.Validate(); err != nil {
		return RunResultArtifact{}, err
	}
	return artifact, nil
}

func requireFields(fields map[string]string) error {
	for field, value := range fields {
		if strings.TrimSpace(value) == "" {
			return fmt.Errorf("%s is required", field)
		}
	}
	return nil
}
