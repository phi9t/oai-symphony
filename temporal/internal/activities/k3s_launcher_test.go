package activities

import (
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func TestSjobRunRendersExpectedMountPathsAndResourceName(t *testing.T) {
	if _, err := exec.LookPath("envsubst"); err != nil {
		t.Skip("envsubst is required for sjob manifest tests")
	}

	repoRoot := repoRoot(t)
	tempRoot := t.TempDir()
	projectRoot := filepath.Join(tempRoot, "projects", "REV-19")
	sharedCacheRoot := filepath.Join(tempRoot, "cache")
	capturePath := filepath.Join(tempRoot, "manifest.yaml")
	wrapperPath := filepath.Join(tempRoot, "kubectl-wrapper.sh")

	for _, path := range []string{
		projectRoot,
		sharedCacheRoot,
	} {
		if err := os.MkdirAll(path, 0o755); err != nil {
			t.Fatalf("unable to create %s: %v", path, err)
		}
	}

	if err := os.WriteFile(wrapperPath, []byte("#!/bin/sh\ncat > \"${SYMPHONY_CAPTURED_MANIFEST}\"\n"), 0o755); err != nil {
		t.Fatalf("unable to write kubectl wrapper: %v", err)
	}

	jobToken := JobName("issue/REV-19", "run-00123456")
	expectedResourceName := JobResourceName("REV-19", "issue/REV-19", "run-00123456")

	output, err := runShellCommand(repoRoot, map[string]string{
		"SYMPHONY_CAPTURED_MANIFEST": capturePath,
		"SYMPHONY_KUBECTL_WRAPPER":   wrapperPath,
	}, filepath.Join(repoRoot, "k3s", "bin", "sjob"),
		"run",
		"--project-id", "REV-19",
		"--job", jobToken,
		"--project-root", projectRoot,
		"--shared-cache-root", sharedCacheRoot,
		"--",
		"echo ok",
	)
	if err != nil {
		t.Fatalf("sjob run returned error: %v\n%s", err, output)
	}

	if !strings.Contains(output, "submitted "+expectedResourceName) {
		t.Fatalf("expected output to mention %q, got %s", expectedResourceName, output)
	}

	manifest, err := os.ReadFile(capturePath)
	if err != nil {
		t.Fatalf("unable to read captured manifest: %v", err)
	}

	for _, expected := range []string{
		"name: " + expectedResourceName,
		`symphony/project-id: "rev-19"`,
		`path: ` + projectRoot + `/home`,
		`path: ` + projectRoot + `/config`,
		`path: ` + projectRoot + `/workspace`,
		`path: ` + projectRoot + `/outputs`,
		`path: ` + sharedCacheRoot,
	} {
		if !strings.Contains(string(manifest), expected) {
			t.Fatalf("expected manifest to contain %q, got:\n%s", expected, manifest)
		}
	}
}

func TestSjobRunRejectsRelativeProjectRoot(t *testing.T) {
	repoRoot := repoRoot(t)
	tempRoot := t.TempDir()
	sharedCacheRoot := filepath.Join(tempRoot, "cache")

	if err := os.MkdirAll(sharedCacheRoot, 0o755); err != nil {
		t.Fatalf("unable to create shared cache root: %v", err)
	}

	output, err := runShellCommand(repoRoot, nil, filepath.Join(repoRoot, "k3s", "bin", "sjob"),
		"run",
		"--project-id", "REV-19",
		"--job", "job-1",
		"--project-root", "./relative-project",
		"--shared-cache-root", sharedCacheRoot,
		"--",
		"echo ok",
	)
	if err == nil {
		t.Fatalf("expected sjob run to reject relative project-root")
	}
	if !strings.Contains(output, "--project-root must be an absolute path") {
		t.Fatalf("expected relative-path validation error, got %s", output)
	}
}

func TestSjobRunRejectsUnwritableOutputsPath(t *testing.T) {
	if _, err := exec.LookPath("envsubst"); err != nil {
		t.Skip("envsubst is required for sjob manifest tests")
	}

	repoRoot := repoRoot(t)
	tempRoot := t.TempDir()
	projectRoot := filepath.Join(tempRoot, "projects", "REV-19")
	sharedCacheRoot := filepath.Join(tempRoot, "cache")
	wrapperPath := filepath.Join(tempRoot, "kubectl-wrapper.sh")

	for _, path := range []string{
		filepath.Join(projectRoot, "home"),
		filepath.Join(projectRoot, "config"),
		filepath.Join(projectRoot, "workspace"),
		filepath.Join(projectRoot, "outputs"),
		sharedCacheRoot,
	} {
		if err := os.MkdirAll(path, 0o755); err != nil {
			t.Fatalf("unable to create %s: %v", path, err)
		}
	}

	if err := os.Chmod(filepath.Join(projectRoot, "outputs"), 0o500); err != nil {
		t.Fatalf("unable to chmod outputs path: %v", err)
	}
	t.Cleanup(func() {
		_ = os.Chmod(filepath.Join(projectRoot, "outputs"), 0o755)
	})

	if err := os.WriteFile(wrapperPath, []byte("#!/bin/sh\ncat > /dev/null\n"), 0o755); err != nil {
		t.Fatalf("unable to write kubectl wrapper: %v", err)
	}

	output, err := runShellCommand(repoRoot, map[string]string{
		"SYMPHONY_KUBECTL_WRAPPER": wrapperPath,
	}, filepath.Join(repoRoot, "k3s", "bin", "sjob"),
		"run",
		"--project-id", "REV-19",
		"--job", "job-1",
		"--project-root", projectRoot,
		"--shared-cache-root", sharedCacheRoot,
		"--",
		"echo ok",
	)
	if err == nil {
		t.Fatalf("expected sjob run to reject unwritable outputs path")
	}
	if !strings.Contains(output, "path not writable") {
		t.Fatalf("expected writable-path validation error, got %s", output)
	}
}

func repoRoot(t *testing.T) string {
	t.Helper()

	_, currentFile, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatalf("unable to resolve test file path")
	}

	return filepath.Clean(filepath.Join(filepath.Dir(currentFile), "..", "..", ".."))
}

func runShellCommand(repoRoot string, extraEnv map[string]string, scriptPath string, args ...string) (string, error) {
	command := exec.Command(scriptPath, args...)
	command.Dir = repoRoot
	command.Env = os.Environ()
	for key, value := range extraEnv {
		command.Env = append(command.Env, key+"="+value)
	}
	return stringOutput(command.CombinedOutput())
}

func stringOutput(output []byte, err error) (string, error) {
	return string(output), err
}
