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

// The widened shell-out contract (#117): the per-type precise device list and
// hardening profile cross the boundary as EXPLICIT environment, not argv (so
// they are not in the process table), where the bash provisioner reads them
// (RUNNER_DEVICES -> --device, RUNNER_HARDENING_PROFILE -> posture). A stub
// script dumps the relevant env to a file for the assertion.
func TestContainerProvisionerPassesDevicesAndHardeningAsEnv(t *testing.T) {
	capFile := filepath.Join(t.TempDir(), "env")
	script := writeScript(t, "#!/usr/bin/env bash\n{ echo \"DEV=$RUNNER_DEVICES\"; echo \"HP=$RUNNER_HARDENING_PROFILE\"; } > '"+capFile+"'\n")

	p := &ContainerProvisioner{Script: script}
	err := p.Provision(context.Background(), ProvisionRequest{
		JobID:            "job-dev",
		EncodedJITConfig: "ENC",
		Image:            "img",
		Devices:          []string{"/dev/nvidia0", "/dev/nvidiactl"},
		HardeningProfile: "device",
	})
	if err != nil {
		t.Fatalf("Provision returned error: %v", err)
	}
	got, rerr := os.ReadFile(capFile)
	if rerr != nil {
		t.Fatalf("read capture: %v", rerr)
	}
	out := string(got)
	// Devices are whitespace-separated so the bash word-split maps each to one
	// --device; the order is preserved.
	if !strings.Contains(out, "DEV=/dev/nvidia0") || !strings.Contains(out, "/dev/nvidiactl") {
		t.Errorf("RUNNER_DEVICES not passed through: %q", out)
	}
	if !strings.Contains(out, "HP=device") {
		t.Errorf("RUNNER_HARDENING_PROFILE not passed through: %q", out)
	}
}

// With no devices configured (a plain CPU type), RUNNER_DEVICES must be empty so
// the provisioner passes NO --device -- least privilege by default.
func TestContainerProvisionerEmptyDevicesByDefault(t *testing.T) {
	capFile := filepath.Join(t.TempDir(), "env")
	script := writeScript(t, "#!/usr/bin/env bash\necho \"DEV=[$RUNNER_DEVICES]\" > '"+capFile+"'\n")
	p := &ContainerProvisioner{Script: script}
	if err := p.Provision(context.Background(), ProvisionRequest{JobID: "j", Image: "img", EncodedJITConfig: "ENC"}); err != nil {
		t.Fatalf("Provision: %v", err)
	}
	got, _ := os.ReadFile(capFile)
	if strings.TrimSpace(string(got)) != "DEV=[]" {
		t.Errorf("expected empty RUNNER_DEVICES, got %q", string(got))
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
