package listener

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// ContainerProvisioner is the production Provisioner: it shells out to the
// per-job container entrypoint script (provision-job.sh, which sources
// lib/runner-container.sh and calls runner_container_run). Keeping the actual
// container lifecycle in shell -- rather than re-implementing it in Go -- means
// the Phase 3 seam stays the single source of truth for the rootless,
// single-use-container isolation; this struct is only the bridge from the Go
// scale-set loop to that shell seam. Each call runs exactly one ephemeral job
// in a throwaway container and returns its exit status as an error.
type ContainerProvisioner struct {
	// Script is the path to provision-job.sh. Defaults to the sibling script
	// next to the listener binary when empty.
	Script string
}

// Provision runs one ephemeral job by exec'ing the entrypoint script with the
// job id, the PATH to a single-use JIT config FILE, and the container image on
// argv:
//
//	provision-job.sh <job-id> <jit-config-file> <image>
//
// The encoded JIT config crosses the Go->bash boundary as a FILE, never on argv
// (ADR-0003 / #133): the single-use runner credential would otherwise be visible
// in the host process table (ps / /proc) for the whole job. The file is written
// mode 0600 in a per-job temp dir and removed when this method returns, so no
// credential survives teardown.
//
// The widened shell-out contract (ADR-0003; #117/#119) carries the per-type
// fields the bash provisioner needs as EXPLICIT environment -- not argv, so they
// stay out of the process table:
//
//	RUNNER_DEVICES            space-separated device nodes -> precise --device
//	RUNNER_RUNTIME            container runtime shim -> --runtime (empty = none)
//	RUNNER_HARDENING_PROFILE  container hardening posture
//	RUNNER_BUILD_TOOL         daemonless builder (kaniko/buildkit) or empty
//
// The script's stdout/stderr are inherited so the container's job log streams
// straight through, and a non-zero exit becomes a non-nil error so the listener
// surfaces the failed job and tears the session down.
func (c *ContainerProvisioner) Provision(ctx context.Context, req ProvisionRequest) error {
	script := c.Script
	if script == "" {
		script = "provision-job.sh"
	}

	// Write the single-use JIT config to a mode-0600 file in a per-job temp dir
	// and pass only the PATH to the provisioner; the encoded config never lands
	// on argv (ADR-0003 / #133). The whole dir is removed on return so neither
	// the file nor its parent survives the job.
	//
	// The per-job temp dir defaults UNDER RUNNER_HOME (#130) -- the same SEC-3 rm
	// chokepoint the bash provisioner's work root and the history store live in --
	// rather than /tmp, so the single-use credential file never lands outside the
	// runner-state tree. workRoot resolves the parent (RUNNER_HOME/work, created
	// if absent); an empty parent falls back to the OS temp dir.
	parent, err := c.workRoot()
	if err != nil {
		return fmt.Errorf("provision job %s: work root: %w", req.JobID, err)
	}
	jitDir, err := os.MkdirTemp(parent, "jit-"+req.JobID+"-")
	if err != nil {
		return fmt.Errorf("provision job %s: jit dir: %w", req.JobID, err)
	}
	defer os.RemoveAll(jitDir)
	jitFile := filepath.Join(jitDir, "jitconfig")
	if err := os.WriteFile(jitFile, []byte(req.EncodedJITConfig), 0o600); err != nil {
		return fmt.Errorf("provision job %s: write jit file: %w", req.JobID, err)
	}

	cmd := exec.CommandContext(ctx, script, req.JobID, jitFile, req.Image)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	// Widen the contract via env: explicit, stable, and kept off the process
	// table. Devices are space-joined so the bash provisioner word-splits them
	// into one --device per node.
	cmd.Env = append(os.Environ(),
		"RUNNER_DEVICES="+strings.Join(req.Devices, " "),
		"RUNNER_RUNTIME="+req.Runtime,
		"RUNNER_HARDENING_PROFILE="+req.HardeningProfile,
		"RUNNER_BUILD_TOOL="+req.BuildTool,
	)
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("provision job %s: %w", req.JobID, err)
	}
	return nil
}

// workRoot resolves the parent dir for the per-job JIT temp dir (#130). It
// defaults to RUNNER_HOME/work -- the SEC-3 rm chokepoint the bash provisioner's
// work root and the history store also live under -- creating it if absent so
// MkdirTemp can land the per-job dir there. When RUNNER_HOME is unset it returns
// "" so os.MkdirTemp falls back to the OS temp dir (the prior behaviour),
// keeping the provisioner usable without a configured RUNNER_HOME.
func (c *ContainerProvisioner) workRoot() (string, error) {
	home := os.Getenv("RUNNER_HOME")
	if home == "" {
		return "", nil
	}
	root := filepath.Join(home, "work")
	if err := os.MkdirAll(root, 0o700); err != nil {
		return "", err
	}
	return root, nil
}
