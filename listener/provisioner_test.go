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
// job id, the PATH to the single-use JIT config file, and the image -- in that
// order (ADR-0003 / #133). The encoded JIT config crosses the Go->bash boundary
// as a FILE, never on argv, so the single-use runner credential is not exposed
// in the host process table (ps / /proc) for the job's duration. A stub script
// captures its argv to a file for the assertion.
func TestContainerProvisionerShellsOutWithJITConfigFile(t *testing.T) {
	capFile := filepath.Join(t.TempDir(), "argv")
	bodyFile := filepath.Join(t.TempDir(), "body")
	// The stub records argv AND, while the file still exists (mid-run), the JIT
	// file's content -- the listener removes the file at teardown, so the body
	// must be read here, inside the shell-out, not afterwards.
	script := writeScript(t, "#!/usr/bin/env bash\n"+
		"printf '%s\\n' \"$@\" > '"+capFile+"'\n"+
		"cat -- \"$2\" > '"+bodyFile+"'\n")

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
	if len(lines) != 3 {
		t.Fatalf("argv: got %v want 3 fields (job-id, jit-file, image)", lines)
	}
	if lines[0] != "job-xyz" {
		t.Errorf("argv[0]: got %q want job id %q", lines[0], "job-xyz")
	}
	if lines[2] != "ghcr.io/acme/runner:latest" {
		t.Errorf("argv[2]: got %q want image", lines[2])
	}
	// The MAJOR security finding: the encoded JIT config must NOT appear on argv.
	// argv[1] is a FILE PATH, not the encoded config, and the file holds it.
	jitPath := lines[1]
	if jitPath == "ENCODEDxJITx==" {
		t.Fatalf("argv[1] is the encoded JIT config itself -- must be a file path, not on argv")
	}
	for i, a := range lines {
		if strings.Contains(a, "ENCODEDxJITx==") {
			t.Fatalf("argv[%d]=%q exposes the encoded JIT config on the process table", i, a)
		}
	}
	body, ferr := os.ReadFile(bodyFile)
	if ferr != nil {
		t.Fatalf("read captured JIT body: %v", ferr)
	}
	if strings.TrimRight(string(body), "\n") != "ENCODEDxJITx==" {
		t.Errorf("JIT file content: got %q want %q", string(body), "ENCODEDxJITx==")
	}
	// The file at argv[1] must be gone once Provision returns -- no single-use
	// credential left on disk after teardown.
	if _, err := os.Stat(jitPath); !os.IsNotExist(err) {
		t.Errorf("JIT file %q must be removed at teardown, stat err=%v", jitPath, err)
	}
}

// The per-job JIT file must be mode 0600 (owner-only) while the job runs, and
// must be removed once the provisioner returns -- no single-use credential left
// on disk after teardown (ADR-0003 / #133). A stub captures the path and its
// octal perms so the test can assert both, then confirms the file is gone after.
func TestContainerProvisionerJITFileIs0600AndRemovedAtTeardown(t *testing.T) {
	capFile := filepath.Join(t.TempDir(), "cap")
	// argv[1] is the JIT file path; record it and its perms for the assertion.
	script := writeScript(t, "#!/usr/bin/env bash\n"+
		"{ echo \"PATH=$2\"; stat -c '%a' \"$2\" | sed 's/^/PERM=/'; } > '"+capFile+"'\n")

	p := &ContainerProvisioner{Script: script}
	if err := p.Provision(context.Background(), ProvisionRequest{
		JobID:            "job-perm",
		EncodedJITConfig: "SECRETxENC",
		Image:            "img",
	}); err != nil {
		t.Fatalf("Provision: %v", err)
	}
	out, rerr := os.ReadFile(capFile)
	if rerr != nil {
		t.Fatalf("read capture: %v", rerr)
	}
	s := string(out)
	if !strings.Contains(s, "PERM=600") {
		t.Errorf("JIT file must be mode 0600, capture was: %q", s)
	}
	// Recover the path the script saw and confirm teardown removed the file.
	var jitPath string
	for _, ln := range strings.Split(s, "\n") {
		if strings.HasPrefix(ln, "PATH=") {
			jitPath = strings.TrimPrefix(ln, "PATH=")
		}
	}
	if jitPath == "" {
		t.Fatalf("could not recover JIT path from capture: %q", s)
	}
	if _, err := os.Stat(jitPath); !os.IsNotExist(err) {
		t.Errorf("JIT file %q must be removed at teardown, stat err=%v", jitPath, err)
	}
}

// The widened shell-out contract (#117): the per-type precise device list
// crosses the boundary as EXPLICIT environment, not argv (so it is not in the
// process table), where the bash provisioner reads it (RUNNER_DEVICES ->
// --device). A stub script dumps the relevant env to a file for the assertion.
func TestContainerProvisionerPassesDevicesAsEnv(t *testing.T) {
	capFile := filepath.Join(t.TempDir(), "env")
	script := writeScript(t, "#!/usr/bin/env bash\necho \"DEV=$RUNNER_DEVICES\" > '"+capFile+"'\n")

	p := &ContainerProvisioner{Script: script}
	err := p.Provision(context.Background(), ProvisionRequest{
		JobID:            "job-dev",
		EncodedJITConfig: "ENC",
		Image:            "img",
		Devices:          []string{"/dev/nvidia0", "/dev/nvidiactl"},
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
}

// The runner type's `runtime:` knob names a container runtime shim (e.g. nvidia
// for the GPU stack). It crosses the boundary as EXPLICIT environment like the
// rest of the widened shell-out contract, where the bash provisioner turns it
// into a `--runtime <value>` argument on the container run.
func TestContainerProvisionerPassesRuntimeAsEnv(t *testing.T) {
	capFile := filepath.Join(t.TempDir(), "env")
	script := writeScript(t, "#!/usr/bin/env bash\necho \"RT=[$RUNNER_RUNTIME]\" > '"+capFile+"'\n")

	p := &ContainerProvisioner{Script: script}
	err := p.Provision(context.Background(), ProvisionRequest{
		JobID:            "job-rt",
		EncodedJITConfig: "ENC",
		Image:            "img",
		Runtime:          "nvidia",
	})
	if err != nil {
		t.Fatalf("Provision returned error: %v", err)
	}
	got, rerr := os.ReadFile(capFile)
	if rerr != nil {
		t.Fatalf("read capture: %v", rerr)
	}
	if strings.TrimSpace(string(got)) != "RT=[nvidia]" {
		t.Errorf("RUNNER_RUNTIME not passed through: %q", string(got))
	}
}

// A type that declares no runtime exports an EMPTY RUNNER_RUNTIME, so the bash
// provisioner adds no --runtime and the engine default stays in force.
func TestContainerProvisionerEmptyRuntimeByDefault(t *testing.T) {
	capFile := filepath.Join(t.TempDir(), "env")
	script := writeScript(t, "#!/usr/bin/env bash\necho \"RT=[$RUNNER_RUNTIME]\" > '"+capFile+"'\n")
	p := &ContainerProvisioner{Script: script}
	if err := p.Provision(context.Background(), ProvisionRequest{JobID: "j", Image: "img", EncodedJITConfig: "ENC"}); err != nil {
		t.Fatalf("Provision: %v", err)
	}
	got, _ := os.ReadFile(capFile)
	if strings.TrimSpace(string(got)) != "RT=[]" {
		t.Errorf("expected empty RUNNER_RUNTIME, got %q", string(got))
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

// The single-use JIT config file must be written under RUNNER_HOME (#130), so
// the per-job temp dir the provisioner creates sits within the same SEC-3 rm
// chokepoint as the rest of the runner state instead of scattering under /tmp.
// A stub records the JIT file PATH; the test asserts it is parented by
// RUNNER_HOME/work.
func TestContainerProvisionerJITFileUnderRunnerHome(t *testing.T) {
	home := t.TempDir()
	t.Setenv("RUNNER_HOME", home)

	capFile := filepath.Join(t.TempDir(), "cap")
	script := writeScript(t, "#!/usr/bin/env bash\necho \"$2\" > '"+capFile+"'\n")

	p := &ContainerProvisioner{Script: script}
	if err := p.Provision(context.Background(), ProvisionRequest{
		JobID:            "job-home",
		EncodedJITConfig: "ENC",
		Image:            "img",
	}); err != nil {
		t.Fatalf("Provision: %v", err)
	}
	got, rerr := os.ReadFile(capFile)
	if rerr != nil {
		t.Fatalf("read capture: %v", rerr)
	}
	jitPath := strings.TrimSpace(string(got))
	wantPrefix := filepath.Join(home, "work") + string(os.PathSeparator)
	if !strings.HasPrefix(jitPath, wantPrefix) {
		t.Errorf("JIT file %q must be under RUNNER_HOME/work (%q)", jitPath, wantPrefix)
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
