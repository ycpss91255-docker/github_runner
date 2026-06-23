package listener

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// writeScript drops an executable shell stub at a temp path and returns it.
func writeScript(t *testing.T, body string) string {
	t.Helper()
	dir := t.TempDir()
	path := filepath.Join(dir, "provision-job.sh")
	if err := os.WriteFile(path, []byte(body), 0o755); err != nil {
		t.Fatalf("write stub: %v", err)
	}
	return path
}

// The production provisioner must shell out to the entrypoint script with the
// job id, the single-use JIT config, and the image -- in that order -- so the
// Phase 3 container seam receives exactly what it needs to run one ephemeral
// job. A stub script captures its argv to a file for the assertion.
func TestContainerProvisionerShellsOutWithJITConfig(t *testing.T) {
	capFile := filepath.Join(t.TempDir(), "argv")
	script := writeScript(t, "#!/usr/bin/env bash\nprintf '%s\\n' \"$@\" > '"+capFile+"'\n")

	p := &ContainerProvisioner{Script: script}
	err := p.Provision(context.Background(), ProvisionRequest{
		JobID:            "job-xyz",
		EncodedJITConfig: "ENCODEDxJITx==",
		Image:            "ghcr.io/acme/runner:latest",
	})
	if err != nil {
		t.Fatalf("Provision returned error: %v", err)
	}

	got, rerr := os.ReadFile(capFile)
	if rerr != nil {
		t.Fatalf("read capture: %v", rerr)
	}
	lines := strings.Split(strings.TrimRight(string(got), "\n"), "\n")
	want := []string{"job-xyz", "ENCODEDxJITx==", "ghcr.io/acme/runner:latest"}
	if len(lines) != len(want) {
		t.Fatalf("argv: got %v want %v", lines, want)
	}
	for i := range want {
		if lines[i] != want[i] {
			t.Errorf("argv[%d]: got %q want %q", i, lines[i], want[i])
		}
	}
}

// A non-zero exit from the container script (the job failed) must surface as a
// non-nil error so the listener can tear the session down.
func TestContainerProvisionerPropagatesFailure(t *testing.T) {
	script := writeScript(t, "#!/usr/bin/env bash\nexit 7\n")
	p := &ContainerProvisioner{Script: script}
	err := p.Provision(context.Background(), ProvisionRequest{JobID: "boom", Image: "img"})
	if err == nil {
		t.Fatal("expected an error when the container script exits non-zero")
	}
}
