package contracts

import (
	"os"
	"path/filepath"
	"testing"
)

func TestRunResultFixturesMatchContract(t *testing.T) {
	for _, fixture := range []string{
		"run-result-success.json",
		"run-result-rework.json",
	} {
		data := readFixture(t, fixture)
		if _, err := DecodeRunResult(data); err != nil {
			t.Fatalf("fixture %s should decode successfully: %v", fixture, err)
		}
	}
}

func TestMalformedRunResultFixtureFailsValidation(t *testing.T) {
	data := readFixture(t, "run-result-malformed.json")
	if _, err := DecodeRunResult(data); err == nil {
		t.Fatalf("expected malformed run-result fixture to fail validation")
	}
}

func readFixture(t *testing.T, name string) []byte {
	t.Helper()

	path := filepath.Join("testdata", name)
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("unable to read fixture %s: %v", path, err)
	}
	return data
}
