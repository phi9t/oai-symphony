package activities

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

type TemporalConfig struct {
	Address   string `json:"address"`
	Namespace string `json:"namespace"`
	TaskQueue string `json:"taskQueue"`
}

type RepositoryConfig struct {
	OriginURL     string `json:"originUrl"`
	DefaultBranch string `json:"defaultBranch"`
}

type CodexConfig struct {
	Command string `json:"command"`
}

type K3sConfig struct {
	Namespace               string `json:"namespace"`
	Image                   string `json:"image"`
	ProjectRoot             string `json:"projectRoot"`
	SharedCacheRoot         string `json:"sharedCacheRoot"`
	TTLSecondsAfterFinished int    `json:"ttlSecondsAfterFinished"`
	DefaultCPU              string `json:"defaultCPU"`
	DefaultMemory           string `json:"defaultMemory"`
	DefaultGPUCount         int    `json:"defaultGPUCount"`
	RuntimeClass            string `json:"runtimeClass"`
}

type IssueRef struct {
	ID         string `json:"id"`
	Identifier string `json:"identifier"`
	Title      string `json:"title"`
	State      string `json:"state"`
}

type PathConfig struct {
	ProjectRoot   string `json:"projectRoot"`
	WorkspacePath string `json:"workspacePath"`
	OutputsPath   string `json:"outputsPath"`
	PromptPath    string `json:"promptPath"`
	WorkpadPath   string `json:"workpadPath"`
	ResultPath    string `json:"resultPath"`
	IssuePath     string `json:"issuePath"`
}

type RunInput struct {
	WorkflowID string           `json:"workflowId"`
	RunID      string           `json:"runId"`
	ProjectID  string           `json:"projectId"`
	Temporal   TemporalConfig   `json:"temporal"`
	Repository RepositoryConfig `json:"repository"`
	Codex      CodexConfig      `json:"codex"`
	K3s        K3sConfig        `json:"k3s"`
	Issue      IssueRef         `json:"issue"`
	Paths      PathConfig       `json:"paths"`
}

type RunResult struct {
	WorkflowID    string `json:"workflowId"`
	RunID         string `json:"runId"`
	Status        string `json:"status"`
	ProjectID     string `json:"projectId"`
	WorkspacePath string `json:"workspacePath"`
	ArtifactDir   string `json:"artifactDir"`
	JobName       string `json:"jobName"`
}

type jobStatus struct {
	Status string `json:"status"`
}

func RunIssueJob(ctx context.Context, input RunInput) (RunResult, error) {
	if strings.TrimSpace(input.ProjectID) == "" {
		return RunResult{}, errors.New("projectId is required")
	}
	if strings.TrimSpace(input.Paths.WorkspacePath) == "" {
		return RunResult{}, errors.New("paths.workspacePath is required")
	}
	if strings.TrimSpace(input.Paths.PromptPath) == "" {
		return RunResult{}, errors.New("paths.promptPath is required")
	}

	artifactDir := filepath.Join(input.Paths.OutputsPath, input.RunID)
	if err := os.MkdirAll(artifactDir, 0o755); err != nil {
		return RunResult{}, fmt.Errorf("creating artifact dir: %w", err)
	}

	jobName := JobName(input.WorkflowID, input.RunID)
	sjobPath, err := resolveSjobPath()
	if err != nil {
		return RunResult{}, err
	}

	command := buildJobCommand(input)
	if _, err := runCommand(ctx, sjobPath, sjobRunArgs(input, jobName, command)); err != nil {
		return RunResult{}, err
	}

	ticker := time.NewTicker(5 * time.Second)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			_, _ = runCommand(context.Background(), sjobPath, []string{
				"stop",
				"--project-id", input.ProjectID,
				"--job", jobName,
				"--namespace", input.K3s.Namespace,
			})
			return RunResult{}, ctx.Err()

		case <-ticker.C:
			output, err := runCommand(ctx, sjobPath, []string{
				"status",
				"--project-id", input.ProjectID,
				"--job", jobName,
				"--namespace", input.K3s.Namespace,
				"--output", "json",
			})
			if err != nil {
				return RunResult{}, err
			}

			var status jobStatus
			if err := json.Unmarshal([]byte(output), &status); err != nil {
				return RunResult{}, fmt.Errorf("decoding job status: %w", err)
			}

			switch strings.ToLower(strings.TrimSpace(status.Status)) {
			case "succeeded":
				return RunResult{
					Status:        "succeeded",
					ProjectID:     input.ProjectID,
					WorkspacePath: input.Paths.WorkspacePath,
					ArtifactDir:   artifactDir,
					JobName:       jobName,
				}, nil
			case "failed":
				return RunResult{
					Status:        "failed",
					ProjectID:     input.ProjectID,
					WorkspacePath: input.Paths.WorkspacePath,
					ArtifactDir:   artifactDir,
					JobName:       jobName,
				}, errors.New("k3s job failed")
			case "missing":
				return RunResult{}, errors.New("k3s job disappeared")
			}
		}
	}
}

func JobName(workflowID, runID string) string {
	return safeName(workflowID) + "-" + safeName(shortRunID(runID))
}

func shortRunID(runID string) string {
	if len(runID) <= 8 {
		return runID
	}
	return runID[:8]
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

func buildJobCommand(input RunInput) string {
	envAssignments := []string{
		"PROMPT_PATH=" + shellEscape(input.Paths.PromptPath),
		"WORKPAD_PATH=" + shellEscape(input.Paths.WorkpadPath),
		"RESULT_PATH=" + shellEscape(input.Paths.ResultPath),
		"ISSUE_PATH=" + shellEscape(input.Paths.IssuePath),
		"REPOSITORY_ORIGIN_URL=" + shellEscape(input.Repository.OriginURL),
		"REPOSITORY_DEFAULT_BRANCH=" + shellEscape(fallback(input.Repository.DefaultBranch, "main")),
		"WORKSPACE_PATH=" + shellEscape(input.Paths.WorkspacePath),
		"CODEX_COMMAND=" + shellEscape(fallback(input.Codex.Command, "codex exec --full-auto --json")),
	}

	return strings.Join(append(envAssignments, "/opt/symphony/k3s/bin/run-agent-job"), " ")
}

func sjobRunArgs(input RunInput, jobName, command string) []string {
	args := []string{
		"run",
		"--project-id", input.ProjectID,
		"--job", jobName,
		"--namespace", input.K3s.Namespace,
		"--image", input.K3s.Image,
		"--cpu", fallback(input.K3s.DefaultCPU, "2"),
		"--memory", fallback(input.K3s.DefaultMemory, "8Gi"),
		"--gpu-count", strconv.Itoa(gpuCount(input.K3s.DefaultGPUCount)),
		"--ttl-seconds-after-finished", strconv.Itoa(ttlSecondsAfterFinished(input.K3s.TTLSecondsAfterFinished)),
		"--project-root", input.K3s.ProjectRoot,
		"--shared-cache-root", input.K3s.SharedCacheRoot,
	}

	if runtimeClass := strings.TrimSpace(input.K3s.RuntimeClass); runtimeClass != "" {
		args = append(args, "--runtime-class", runtimeClass)
	}

	return append(args, "--", command)
}

func runCommand(ctx context.Context, binary string, args []string) (string, error) {
	cmd := exec.CommandContext(ctx, binary, args...)
	output, err := cmd.CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("%s %s failed: %w output=%s", binary, strings.Join(args, " "), err, strings.TrimSpace(string(output)))
	}
	return strings.TrimSpace(string(output)), nil
}

func fallback(value, fallbackValue string) string {
	if strings.TrimSpace(value) == "" {
		return fallbackValue
	}
	return value
}

func ttlSecondsAfterFinished(value int) int {
	if value <= 0 {
		return 86400
	}
	return value
}

func gpuCount(value int) int {
	if value < 0 {
		return 0
	}
	return value
}

func safeName(value string) string {
	value = strings.TrimSpace(value)
	if value == "" {
		return "run"
	}
	replacer := strings.NewReplacer("/", "-", "_", "-", ":", "-", ".", "-")
	value = replacer.Replace(value)
	value = strings.Map(func(r rune) rune {
		switch {
		case r >= 'a' && r <= 'z':
			return r
		case r >= 'A' && r <= 'Z':
			return r + ('a' - 'A')
		case r >= '0' && r <= '9':
			return r
		case r == '-':
			return r
		default:
			return '-'
		}
	}, value)
	return strings.Trim(value, "-")
}

func shellEscape(value string) string {
	return "'" + strings.ReplaceAll(value, "'", "'\"'\"'") + "'"
}
