#!/usr/bin/env bash
# provision-job.sh -- the listener's per-job container entrypoint (ADR-0001
# Phase 4). The Go scale-set listener (cmd/scaleset-listener) shells out to
# THIS script for every ASSIGNED job; it is the thin bridge from the Go loop to
# the Phase 3 container provisioner seam (lib/runner-container.sh's
# runner_container_run), so that seam stays the single source of truth for the
# fresh, single-use, rootless-container isolation.
#
#   provision-job.sh <job-id> <encoded-jit-config> <image>
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

usage() { echo "usage: provision-job.sh <job-id> <encoded-jit-config> <image>" >&2; }

[[ $# -eq 3 ]] || { usage; exit 2; }
job_id=$1
encoded=$2
image=$3
[[ -n "${encoded}" ]] || { echo "FAIL: empty JIT config for job ${job_id}" >&2; exit 2; }

# A throwaway, per-job runner dir mounted into the container. It holds no
# persistent state -- the JIT config makes the runner single-use -- and is
# removed on exit so nothing from this job can poison the next. RUNNER_HOME (or
# /tmp) parents it; the dir name carries the job id for traceability.
work_root="${RUNNER_WORK_ROOT:-${TMPDIR:-/tmp}}"
runner_dir="$(mktemp -d "${work_root%/}/jit-${job_id}.XXXXXX")"
trap 'rm -rf "${runner_dir}"' EXIT

# Hand the single-use JIT config + image + job id to the Phase 3 seam; it runs
# `<cli> run --rm ...` so the container is single-use and torn down on exit,
# executing run.sh --jitconfig <encoded> inside it. The job id gives the
# container a deterministic name + managed-by/job-id labels (#104) so the reaper
# can correlate it. The bounded variant arms a watchdog that stops+removes the
# container if it outlives RUNNER_JOB_MAX_LIFETIME (#107). Propagate its exit
# status.
runner_container_run_bounded "${runner_dir}" "${encoded}" "${image}" "${job_id}"
