package listener

import (
	"context"
	"fmt"
	"os"
	"os/exec"
)

// ScriptReaper is the production Reaper (#105): it shells out to the orphan-
// sweep entrypoint (reap.sh, which sources lib/runner-reaper.sh) with the
// listener's currently-tracked job ids as arguments, so labelled containers and
// leaked temp dirs not belonging to a live job are removed. Reaping lives in
// bash (ADR-0003); this struct is only the bridge from the Go loop to that seam.
type ScriptReaper struct {
	// Script is the path to reap.sh. Defaults to the sibling script next to the
	// listener binary when empty.
	Script string
}

// Reap runs one orphan sweep, passing the tracked job ids so their containers
// are spared. stdout/stderr are inherited so the reaper's log lines surface; a
// non-zero exit becomes an error the caller logs (a failed sweep never ends the
// listen loop).
func (r *ScriptReaper) Reap(ctx context.Context, tracked []string) error {
	script := r.Script
	if script == "" {
		script = "reap.sh"
	}
	cmd := exec.CommandContext(ctx, script, tracked...)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("orphan reap: %w", err)
	}
	return nil
}
