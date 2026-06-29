#!/usr/bin/env bash
# provision-job.sh -- the listener's per-job container entrypoint (ADR-0001
# Phase 4). The Go scale-set listener (cmd/scaleset-listener) shells out to
# THIS script for every ASSIGNED job; it is the thin bridge from the Go loop to
# the Phase 3 container provisioner seam (lib/runner-container.sh's
# runner_container_run), so that seam stays the single source of truth for the
# fresh, single-use, rootless-container isolation.
#
#   provision-job.sh <job-id> <jit-config-file> <image>
#
# The single-use JIT config crosses the Go->bash boundary as a FILE, never on
# argv (ADR-0003 / #133): the encoded runner credential would otherwise be
# visible in the host process table (ps / /proc) for the whole job. This script
# reads the file's content; the Go listener writes it mode 0600 in a per-job
# temp dir and removes it at teardown, so only the path appears on argv.
#
# The widened shell-out contract (ADR-0003; #117/#119) carries the per-type
# fields as EXPLICIT environment (kept off the process table), read by the
# container seam in lib/runner-container.sh:
#   RUNNER_DEVICES            space-separated host device nodes -> precise
#                             --device passthrough (never --privileged, #117)
#   RUNNER_HARDENING_PROFILE  container hardening posture (#114/#115)
#   RUNNER_BUILD_TOOL         daemonless image builder (kaniko/buildkit), #119
#
# Each invocation runs EXACTLY ONE ephemeral job in a throwaway container that
# is torn down on exit (--rm), then returns the in-container job's exit status
# so the listener can surface a failed job and tear its session down. No state
# survives: the runner dir is a per-job mktemp dir removed on exit, and the
# image's bundled run.sh consumes the single-use JIT config minted server-side.
set -euo pipefail

# Locate lib/ relative to this script (the listener dir lives beside the repo
# root's lib/), so the container seam is sourced the same way the shell scripts
# under script/ source common.sh.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=SCRIPTDIR/../lib/runner-container.sh
source "${SCRIPT_DIR}/../lib/runner-container.sh"
# Job-history store (ADR-0002): the capture-before-teardown hook lives here, so
# forensics are captured out-of-band BEFORE the container/temp dir is removed.
# shellcheck source=SCRIPTDIR/../lib/runner-history.sh
source "${SCRIPT_DIR}/../lib/runner-history.sh"

usage() { echo "usage: provision-job.sh <job-id> <jit-config-file> <image>" >&2; }

[[ $# -eq 3 ]] || { usage; exit 2; }
job_id=$1
jit_file=$2
image=$3
# The JIT config arrives as a FILE PATH, never on argv (ADR-0003 / #133). Read
# its content here so the encoded credential stays off the host process table.
[[ -f "${jit_file}" ]] || { echo "FAIL: JIT config file not found for job ${job_id}: ${jit_file}" >&2; exit 2; }
encoded=$(cat -- "${jit_file}")
[[ -n "${encoded}" ]] || { echo "FAIL: empty JIT config for job ${job_id}" >&2; exit 2; }

# A throwaway, per-job runner dir mounted into the container. It holds no
# persistent state -- the JIT config makes the runner single-use -- and is
# removed on exit so nothing from this job can poison the next. The dir name
# carries the job id for traceability.
#
# The per-job work root DEFAULTS under RUNNER_HOME (#130), so the runner dir --
# and therefore the rm -rf teardown target below -- sits within the SEC-3 rm
# chokepoint rooted at RUNNER_HOME, beside the rest of the runner state, rather
# than scattered under /tmp. RUNNER_HOME is resolved the same way common.sh does
# (repo_root/runners) when unset, so the direct-source path (this script does
# not source common.sh) still anchors under the same tree. RUNNER_WORK_ROOT
# overrides it for tests / alternate layouts.
: "${RUNNER_HOME:=$(cd -- "${SCRIPT_DIR}/.." && pwd -P)/runners}"
work_root="${RUNNER_WORK_ROOT:-${RUNNER_HOME%/}/work}"
# Create the work root so mktemp -d can land the per-job dir under it on a fresh
# host (RUNNER_HOME/work may not exist yet).
mkdir -p "${work_root}"
runner_dir="$(mktemp -d "${work_root%/}/jit-${job_id}.XXXXXX")"
trap 'rm -rf "${runner_dir}"' EXIT

# Capture the container's combined stdout/stderr to a per-job log under the
# (throwaway) runner dir, so a copy survives for the history archive (#125). The
# log file lives inside runner_dir so it is removed with it once the capture hook
# has copied it into the durable history store.
job_log="${runner_dir}/job.log"

# Hand the single-use JIT config + image + job id to the Phase 3 seam; it runs
# `<cli> run --rm ...` so the container is single-use and torn down on exit,
# executing run.sh --jitconfig <encoded> inside it. The job id gives the
# container a deterministic name + managed-by/job-id labels (#104) so the reaper
# can correlate it. The bounded variant arms a watchdog that stops+removes the
# container if it outlives RUNNER_JOB_MAX_LIFETIME (#107).
#
# The exit status is captured (not propagated immediately) so the
# capture-before-teardown hook (#123) can run on EVERY job -- success and
# failure -- AFTER the job exits but BEFORE the EXIT trap removes the container's
# runner dir. `|| status=$?` keeps `set -e` from aborting before capture.
#
# Output goes to job_log via a plain redirect (NOT process substitution), so the
# file is guaranteed fully written -- and synchronously complete -- by the time
# the capture hook archives it; a backgrounded `tee` could still be draining. We
# then echo the log to our own stdout so the listener still sees the job output.
status=0
runner_container_run_bounded "${runner_dir}" "${encoded}" "${image}" "${job_id}" \
  > "${job_log}" 2>&1 || status=$?
cat -- "${job_log}" || true

# Defence-in-depth value redaction (#143): a hostile step can print the single-
# use JIT credential as a BARE value with no KEY= prefix (`printenv JITCONFIG` /
# `echo "$JITCONFIG"`), which the key-anchored history scrubber (#140/#141)
# cannot match. Hand the LIVE credential value to the scrubber so it is redacted
# LITERALLY wherever it appears in the captured job.log / _diag, before either
# reaches the durable, never-torn-down history store (or the external push seam).
export RUNNER_HISTORY_SCRUB_VALUES="${encoded}"

# Capture-before-teardown hook (ADR-0002, #123): write the ledger record (#124,
# secrets redacted), archive the container log + runner _diag (#125), and run the
# external-push seam (#128) -- BEST-EFFORT, so a capture failure is logged and
# never blocks the teardown below. The per-type forensic context the listener
# knows (image digest, host, runner type, devices, trigger, scale set/labels)
# arrives as EXPLICIT environment (ADR-0003), forwarded as ledger fields; unset
# ones are simply absent.
runner_history_capture "${job_id}" "${status}" "${job_log}" "${runner_dir}" \
  "image=${image}" \
  "image_digest=${RUNNER_IMAGE_DIGEST:-}" \
  "host=$(hostname 2>/dev/null || echo unknown)" \
  "runner_type=${RUNNER_TYPE:-}" \
  "scale_set=${RUNNER_SCALE_SET:-}" \
  "labels=${RUNNER_LABELS:-}" \
  "devices=${RUNNER_DEVICES:-}" \
  "trigger_repo=${RUNNER_TRIGGER_REPO:-}" \
  "trigger_workflow=${RUNNER_TRIGGER_WORKFLOW:-}" \
  "trigger_commit=${RUNNER_TRIGGER_COMMIT:-}" \
  "trigger_actor=${RUNNER_TRIGGER_ACTOR:-}"

# Propagate the in-container job's exit status so the listener can surface a
# failed job and tear its session down. The EXIT trap now removes the runner dir
# (after capture has copied what it needs into the durable history store).
exit "${status}"
