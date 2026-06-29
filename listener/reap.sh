#!/usr/bin/env bash
# reap.sh -- the listener's orphan-sweep entrypoint (ADR-0001 lifecycle, #105/
# #106). The Go listener shells out to THIS script on startup and on its reap
# interval; it is the thin bridge from the Go loop to the bash reaper seam
# (lib/runner-reaper.sh), keeping reaping on the bash side of the boundary
# (ADR-0003). It removes labelled containers (#104) no longer tracked and prunes
# leaked per-job temp dirs under the work root.
#
#   reap.sh [tracked_job_id ...]
#
# The tracked job ids (the listener's currently in-flight jobs) are spared; with
# none, every labelled container / jit-* temp dir is an orphan (the startup
# sweep). Best-effort: a failure of any single removal is logged, not fatal.
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=SCRIPTDIR/../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"
# shellcheck source=SCRIPTDIR/../lib/runner-reaper.sh
source "${SCRIPT_DIR}/../lib/runner-reaper.sh"

# Sweep orphaned containers carrying our managed-by label, sparing tracked jobs.
runner_reap_orphans "$@"

# Prune leaked per-job temp dirs under the SAME work root provision-job.sh uses,
# sparing tracked jobs. Scoped strictly to the work root (no path escape).
#
# The root is resolved through runner_work_root (lib/runner-container.sh) -- the
# single source of truth provision-job.sh also creates its per-job runner dirs
# under -- so the two halves can never diverge. Resolving it independently here
# (e.g. defaulting to /tmp) made this a silent no-op against the real residue
# under RUNNER_HOME/work whenever RUNNER_WORK_ROOT was unset, the default config
# (#148). RUNNER_HOME is already set (readonly) by common.sh, sourced above.
work_root="$(runner_work_root)"
runner_prune_temp_dirs "${work_root}" "$@"
