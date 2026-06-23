package listener

import (
	"context"
	"fmt"
	"os"
	"os/exec"
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
// job's runner dir name, single-use JIT config, and container image:
//
//	provision-job.sh <job-id> <encoded-jit-config> <image>
//
// The script's stdout/stderr are inherited so the container's job log streams
// straight through, and a non-zero exit becomes a non-nil error so the listener
// surfaces the failed job and tears the session down.
func (c *ContainerProvisioner) Provision(ctx context.Context, req ProvisionRequest) error {
	script := c.Script
	if script == "" {
		script = "provision-job.sh"
	}
	cmd := exec.CommandContext(ctx, script, req.JobID, req.EncodedJITConfig, req.Image)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("provision job %s: %w", req.JobID, err)
	}
	return nil
}
