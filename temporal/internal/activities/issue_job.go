package activities

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"go.temporal.io/sdk/temporal"

	"symphony-temporal/internal/contracts"
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
	Status  string `json:"status"`
	JobName string `json:"jobName"`
}

const (
	projectNameComponentMaxLength = 20
	jobNameComponentMaxLength     = 28
	symphonyDirName               = ".symphony"
)

var executeExternalCommand = runCommand
var activityPollInterval = 5 * time.Second
var posixCksumTable = buildPOSIXCksumTable()

func RunIssueJob(ctx context.Context, input RunInput) (RunResult, error) {
	if err := validateRunInput(input); err != nil {
		return RunResult{}, err
	}

	artifactDir := filepath.Join(input.Paths.OutputsPath, input.RunID)
	if err := os.MkdirAll(artifactDir, 0o755); err != nil {
		return RunResult{}, boundaryError("artifact_dir_unwritable", "creating artifact dir", false, err)
	}

	jobToken := JobName(input.WorkflowID, input.RunID)
	jobName := JobResourceName(input.ProjectID, input.WorkflowID, input.RunID)
	result := newRunResult(input, artifactDir, jobName, "")
	sjobPath, err := resolveSjobPath()
	if err != nil {
		return RunResult{}, boundaryError("k3s_launcher_missing", "unable to locate k3s/bin/sjob", false, err)
	}

	command, err := buildJobCommand(input)
	if err != nil {
		return RunResult{}, err
	}
	if _, err := executeExternalCommand(ctx, sjobPath, sjobRunArgs(input, jobToken, command)); err != nil {
		return RunResult{}, boundaryError("k3s_job_submit_failed", "submitting k3s job", true, err)
	}

	ticker := time.NewTicker(activityPollInterval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			_ = cleanupJob(sjobPath, input, jobToken)
			return RunResult{}, ctx.Err()

		case <-ticker.C:
			output, err := executeExternalCommand(ctx, sjobPath, []string{
				"status",
				"--project-id", input.ProjectID,
				"--job", jobToken,
				"--namespace", input.K3s.Namespace,
				"--output", "json",
			})
			if err != nil {
				return RunResult{}, boundaryError("k3s_status_failed", "checking k3s job status", true, err)
			}

			var status jobStatus
			if err := json.Unmarshal([]byte(output), &status); err != nil {
				return RunResult{}, boundaryError("k3s_status_decode_failed", "decoding k3s job status", false, err)
			}

			if status.JobName != "" && status.JobName != jobName {
				return RunResult{}, boundaryError(
					"job_name_mismatch",
					fmt.Sprintf("unexpected k3s job name %q (want %q)", status.JobName, jobName),
					false,
					nil,
				)
			}

			switch strings.ToLower(strings.TrimSpace(status.Status)) {
			case "succeeded":
				result.Status = "succeeded"
				if err := finalizeArtifacts(input, artifactDir, result, "succeeded", cleanupJob(sjobPath, input, jobToken)); err != nil {
					return result, err
				}
				return result, nil
			case "failed":
				result.Status = "failed"
				if err := finalizeArtifacts(input, artifactDir, result, "failed", cleanupJob(sjobPath, input, jobToken)); err != nil {
					return result, err
				}
				return result, boundaryError("k3s_job_failed", "k3s job failed", false, nil)
			case "missing":
				_ = cleanupJob(sjobPath, input, jobToken)
				return RunResult{}, boundaryError("k3s_job_missing", "k3s job disappeared", true, nil)
			case "running", "":
			default:
				return RunResult{}, boundaryError("k3s_status_unknown", fmt.Sprintf("unexpected k3s job status %q", status.Status), false, nil)
			}
		}
	}
}

func JobName(workflowID, runID string) string {
	return boundedSafeName(safeName(workflowID)+"-"+safeName(shortRunID(runID)), jobNameComponentMaxLength)
}

func JobResourceName(projectID, workflowID, runID string) string {
	return "symphony-job-" + projectNameComponent(projectID) + "-" + JobName(workflowID, runID)
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

func buildJobCommand(input RunInput) (string, error) {
	containerPaths, err := containerizedPaths(input)
	if err != nil {
		return "", err
	}

	envAssignments := []string{
		"PROMPT_PATH=" + shellEscape(containerPaths.PromptPath),
		"WORKPAD_PATH=" + shellEscape(containerPaths.WorkpadPath),
		"RESULT_PATH=" + shellEscape(containerPaths.ResultPath),
		"ISSUE_PATH=" + shellEscape(containerPaths.IssuePath),
		"REPOSITORY_ORIGIN_URL=" + shellEscape(input.Repository.OriginURL),
		"REPOSITORY_DEFAULT_BRANCH=" + shellEscape(fallback(input.Repository.DefaultBranch, "main")),
		"WORKSPACE_PATH=" + shellEscape(containerPaths.WorkspacePath),
		"CODEX_COMMAND=" + shellEscape(fallback(input.Codex.Command, "codex exec --full-auto --json")),
	}

	return strings.Join(append(envAssignments, "/opt/symphony/k3s/bin/run-agent-job"), " "), nil
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
		"--project-root", input.Paths.ProjectRoot,
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
	value = strings.ToLower(strings.TrimSpace(value))
	if value == "" {
		return "run"
	}

	var builder strings.Builder
	builder.Grow(len(value))
	lastWasDash := false

	for _, r := range value {
		switch {
		case r >= 'a' && r <= 'z':
			builder.WriteRune(r)
			lastWasDash = false
		case r >= '0' && r <= '9':
			builder.WriteRune(r)
			lastWasDash = false
		default:
			if !lastWasDash {
				builder.WriteByte('-')
				lastWasDash = true
			}
		}
	}

	value = strings.Trim(builder.String(), "-")
	if value == "" {
		return "run"
	}
	return value
}

func shellEscape(value string) string {
	return "'" + strings.ReplaceAll(value, "'", "'\"'\"'") + "'"
}

func newRunResult(input RunInput, artifactDir, jobName, status string) RunResult {
	return RunResult{
		WorkflowID:    input.WorkflowID,
		RunID:         input.RunID,
		Status:        status,
		ProjectID:     input.ProjectID,
		WorkspacePath: input.Paths.WorkspacePath,
		ArtifactDir:   artifactDir,
		JobName:       jobName,
	}
}

func validateRunInput(input RunInput) error {
	required := map[string]string{
		"workflowId":           input.WorkflowID,
		"runId":                input.RunID,
		"projectId":            input.ProjectID,
		"paths.projectRoot":    input.Paths.ProjectRoot,
		"paths.workspacePath":  input.Paths.WorkspacePath,
		"paths.outputsPath":    input.Paths.OutputsPath,
		"paths.promptPath":     input.Paths.PromptPath,
		"paths.workpadPath":    input.Paths.WorkpadPath,
		"paths.resultPath":     input.Paths.ResultPath,
		"paths.issuePath":      input.Paths.IssuePath,
		"k3s.namespace":        input.K3s.Namespace,
		"k3s.image":            input.K3s.Image,
		"k3s.sharedCacheRoot":  input.K3s.SharedCacheRoot,
		"repository.originUrl": input.Repository.OriginURL,
	}

	for field, value := range required {
		if strings.TrimSpace(value) == "" {
			return boundaryError("invalid_request", fmt.Sprintf("%s is required", field), false, nil)
		}
	}

	if err := requirePathWithin("paths.workspacePath", input.Paths.WorkspacePath, input.Paths.ProjectRoot); err != nil {
		return err
	}
	if err := requirePathWithin("paths.outputsPath", input.Paths.OutputsPath, input.Paths.ProjectRoot); err != nil {
		return err
	}
	for _, pathConfig := range []struct {
		label string
		path  string
		root  string
	}{
		{label: "paths.promptPath", path: input.Paths.PromptPath, root: input.Paths.WorkspacePath},
		{label: "paths.workpadPath", path: input.Paths.WorkpadPath, root: input.Paths.WorkspacePath},
		{label: "paths.resultPath", path: input.Paths.ResultPath, root: input.Paths.WorkspacePath},
		{label: "paths.issuePath", path: input.Paths.IssuePath, root: input.Paths.WorkspacePath},
	} {
		if err := requirePathWithin(pathConfig.label, pathConfig.path, pathConfig.root); err != nil {
			return err
		}
	}

	if root := strings.TrimSpace(input.K3s.ProjectRoot); root != "" {
		if err := requirePathWithin("paths.projectRoot", input.Paths.ProjectRoot, root); err != nil {
			return err
		}
	}

	return nil
}

func requirePathWithin(label, candidate, root string) error {
	relative, err := filepath.Rel(filepath.Clean(root), filepath.Clean(candidate))
	if err != nil {
		return boundaryError("invalid_path", fmt.Sprintf("invalid %s: %v", label, err), false, err)
	}
	if relative == ".." || strings.HasPrefix(relative, ".."+string(filepath.Separator)) {
		return boundaryError("invalid_path", fmt.Sprintf("%s must stay under %s", label, root), false, nil)
	}
	return nil
}

type jobContainerPaths struct {
	WorkspacePath string
	PromptPath    string
	WorkpadPath   string
	ResultPath    string
	IssuePath     string
}

func containerizedPaths(input RunInput) (jobContainerPaths, error) {
	workspacePath, err := containerPath(input.Paths.WorkspacePath, input.Paths.WorkspacePath, "/workspace")
	if err != nil {
		return jobContainerPaths{}, err
	}
	promptPath, err := containerPath(input.Paths.PromptPath, input.Paths.WorkspacePath, "/workspace")
	if err != nil {
		return jobContainerPaths{}, err
	}
	workpadPath, err := containerPath(input.Paths.WorkpadPath, input.Paths.WorkspacePath, "/workspace")
	if err != nil {
		return jobContainerPaths{}, err
	}
	resultPath, err := containerPath(input.Paths.ResultPath, input.Paths.WorkspacePath, "/workspace")
	if err != nil {
		return jobContainerPaths{}, err
	}
	issuePath, err := containerPath(input.Paths.IssuePath, input.Paths.WorkspacePath, "/workspace")
	if err != nil {
		return jobContainerPaths{}, err
	}
	return jobContainerPaths{
		WorkspacePath: workspacePath,
		PromptPath:    promptPath,
		WorkpadPath:   workpadPath,
		ResultPath:    resultPath,
		IssuePath:     issuePath,
	}, nil
}

func containerPath(hostPath, hostRoot, containerRoot string) (string, error) {
	if err := requirePathWithin("container path", hostPath, hostRoot); err != nil {
		return "", err
	}
	relative, err := filepath.Rel(filepath.Clean(hostRoot), filepath.Clean(hostPath))
	if err != nil {
		return "", boundaryError("invalid_path", fmt.Sprintf("invalid path %q: %v", hostPath, err), false, err)
	}
	if relative == "." {
		return containerRoot, nil
	}
	return path.Join(containerRoot, filepath.ToSlash(relative)), nil
}

type artifactMetadata struct {
	CollectedArtifacts []string `json:"collectedArtifacts"`
	CleanupError       string   `json:"cleanupError,omitempty"`
	CollectedAt        string   `json:"collectedAt"`
	JobName            string   `json:"jobName"`
	ProjectID          string   `json:"projectId"`
	RunID              string   `json:"runId"`
	Status             string   `json:"status"`
	WorkflowID         string   `json:"workflowId"`
}

func finalizeArtifacts(input RunInput, artifactDir string, result RunResult, terminalStatus string, cleanupErr error) error {
	artifacts, err := collectArtifacts(input, artifactDir)
	metadata := artifactMetadata{
		CollectedArtifacts: artifacts,
		CollectedAt:        time.Now().UTC().Format(time.RFC3339),
		JobName:            result.JobName,
		ProjectID:          result.ProjectID,
		RunID:              result.RunID,
		Status:             terminalStatus,
		WorkflowID:         result.WorkflowID,
	}
	if cleanupErr != nil {
		metadata.CleanupError = cleanupErr.Error()
	}
	if metadataErr := writeArtifactMetadata(filepath.Join(artifactDir, "metadata.json"), metadata); metadataErr != nil && err == nil {
		err = boundaryError("artifact_write_failed", "writing artifact metadata", false, metadataErr)
	}
	return err
}

func collectArtifacts(input RunInput, artifactDir string) ([]string, error) {
	artifactPaths := []struct {
		source   string
		required bool
	}{
		{source: input.Paths.WorkpadPath, required: false},
		{source: input.Paths.ResultPath, required: true},
		{source: input.Paths.IssuePath, required: false},
		{source: filepath.Join(input.Paths.WorkspacePath, symphonyDirName, "codex-output.jsonl"), required: false},
	}

	collected := make([]string, 0, len(artifactPaths))

	for _, artifact := range artifactPaths {
		relativePath, err := filepath.Rel(filepath.Clean(input.Paths.WorkspacePath), filepath.Clean(artifact.source))
		if err != nil {
			return collected, boundaryError("artifact_copy_failed", fmt.Sprintf("computing artifact path for %s", artifact.source), false, err)
		}
		destination := filepath.Join(artifactDir, relativePath)
		copied, err := copyArtifact(artifact.source, destination)
		if err != nil {
			return collected, boundaryError("artifact_copy_failed", fmt.Sprintf("copying artifact %s", artifact.source), false, err)
		}
		if copied {
			collected = append(collected, relativePath)
		} else if artifact.required {
			return collected, boundaryError("missing_run_result", fmt.Sprintf("required artifact %s is missing", artifact.source), false, nil)
		}
	}

	resultData, err := os.ReadFile(filepath.Join(artifactDir, symphonyDirName, "run-result.json"))
	if err != nil {
		return collected, boundaryError("missing_run_result", "unable to read collected run-result.json", false, err)
	}
	if _, err := contracts.DecodeRunResult(resultData); err != nil {
		return collected, boundaryError("malformed_run_result", "run-result.json does not match the runtime contract", false, err)
	}

	return collected, nil
}

func copyArtifact(sourcePath, destinationPath string) (bool, error) {
	sourceFile, err := os.Open(sourcePath)
	if errors.Is(err, os.ErrNotExist) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	defer sourceFile.Close()

	if err := os.MkdirAll(filepath.Dir(destinationPath), 0o755); err != nil {
		return false, err
	}

	destinationFile, err := os.Create(destinationPath)
	if err != nil {
		return false, err
	}
	defer destinationFile.Close()

	if _, err := io.Copy(destinationFile, sourceFile); err != nil {
		return false, err
	}

	return true, nil
}

func writeArtifactMetadata(path string, metadata artifactMetadata) error {
	data, err := json.MarshalIndent(metadata, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(path, data, 0o644)
}

func cleanupJob(sjobPath string, input RunInput, jobToken string) error {
	_, err := executeExternalCommand(context.Background(), sjobPath, []string{
		"stop",
		"--project-id", input.ProjectID,
		"--job", jobToken,
		"--namespace", input.K3s.Namespace,
	})
	if err != nil {
		return boundaryError("k3s_cleanup_failed", "cleaning up k3s job", true, err)
	}
	return nil
}

func projectNameComponent(projectID string) string {
	return boundedSafeName(projectID, projectNameComponentMaxLength)
}

func boundedSafeName(value string, maxLength int) string {
	value = safeName(value)
	if maxLength <= 0 {
		return value
	}
	if len(value) <= maxLength {
		return value
	}

	hash := hashedSuffix(value)
	keep := maxLength - len(hash) - 1
	if keep < 1 {
		if len(hash) <= maxLength {
			return hash
		}
		return hash[:maxLength]
	}

	prefix := strings.Trim(value[:keep], "-")
	if prefix == "" {
		return hash[:maxLength]
	}
	return prefix + "-" + hash
}

func hashedSuffix(value string) string {
	checksum := fmt.Sprintf("%d", posixCksum([]byte(value)))
	if len(checksum) <= 8 {
		return checksum
	}
	return checksum[:8]
}

func buildPOSIXCksumTable() [256]uint32 {
	const polynomial uint32 = 0x04C11DB7

	var table [256]uint32
	for i := 0; i < len(table); i++ {
		crc := uint32(i) << 24
		for bit := 0; bit < 8; bit++ {
			if crc&0x80000000 != 0 {
				crc = (crc << 1) ^ polynomial
			} else {
				crc <<= 1
			}
		}
		table[i] = crc
	}

	return table
}

func posixCksum(data []byte) uint32 {
	var crc uint32

	for _, b := range data {
		crc = (crc << 8) ^ posixCksumTable[byte(crc>>24)^b]
	}

	for length := len(data); length != 0; length >>= 8 {
		crc = (crc << 8) ^ posixCksumTable[byte(crc>>24)^byte(length&0xff)]
	}

	return ^crc
}

func boundaryError(code, message string, retryable bool, cause error) error {
	if retryable {
		if cause != nil {
			return temporal.NewApplicationErrorWithCause(message, code, cause)
		}
		return temporal.NewApplicationError(message, code)
	}

	return temporal.NewNonRetryableApplicationError(message, code, cause)
}
