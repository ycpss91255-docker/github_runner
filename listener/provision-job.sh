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
#   RUNNER_RUNTIME            container runtime / hardware shim (e.g. nvidia)
#                             -> one --runtime <value>; empty = engine default
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
#
# runner_work_root (lib/runner-container.sh, sourced above) is the SINGLE source
# of truth shared with reap.sh, so the reaper prunes EXACTLY this root and the two
# halves can never diverge (#148). RUNNER_HOME is still materialised here for the
# history store (lib/runner-history.sh) which also anchors under it.
: "${RUNNER_HOME:=$(cd -- "${SCRIPT_DIR}/.." && pwd -P)/runners}"
work_root="$(runner_work_root)"
# Create the work root so mktemp -d can land the per-job dir under it on a fresh
# host (RUNNER_HOME/work may not exist yet).
mkdir -p "${work_root}"
runner_dir="$(mktemp -d "${work_root%/}/jit-${job_id}.XXXXXX")"

# No state from this job survives to poison the next: the per-job runner dir is
# removed on exit. There is NO separate captured job log -- the container's
# combined stdout/stderr is FULLY attacker-controlled job-console output whose
# authoritative copy already lives in GitHub's job log, so we never durably
# capture that stream on the host (ADR-0002 / #154). This also dissolves the
# symlink-swap surface (#145): provision-job never re-opens any path the job
# could influence.
trap 'rm -rf "${runner_dir}"' EXIT

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
# The container's combined stdout/stderr is sent to /dev/null, NOT forwarded to
# provision-job's own stdout. That stdout is the listener's durable journald sink
# (the Go provisioner sets cmd.Stdout = os.Stdout and the listener runs as a
# systemd unit), so forwarding the raw, attacker-controlled stream there is what
# let a hostile `echo "$JITCONFIG"` survive in journald (#151). Not forwarding it
# at all is the root-cause fix (#154): the job console lives in GitHub; the
# listener still gets the job's outcome via the exit status below and its own
# structured per-job record (#131). provision-job's OWN diagnostics (FAIL lines)
# remain on its stderr, unaffected by this redirect of the container run.
status=0
runner_container_run_bounded "${runner_dir}" "${encoded}" "${image}" "${job_id}" \
  >/dev/null 2>&1 || status=$?

# Capture-before-teardown hook (ADR-0002, #123/#154): write ONLY the trusted
# ledger record (#124, secrets redacted; mirrored per-job) and run the
# external-push seam (#128) -- BEST-EFFORT, so a capture failure is logged and
# never blocks the teardown below. No attacker-controlled job stdout/_diag is
# durably persisted. The per-type forensic context the listener knows (image
# digest, host, runner type, devices, trigger, scale set/labels) arrives as
# EXPLICIT environment (ADR-0003), forwarded as trusted ledger fields; unset ones
# are simply absent.
runner_history_capture "${job_id}" "${status}" \
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
