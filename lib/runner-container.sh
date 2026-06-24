#!/usr/bin/env bash
# Runner Container -- the per-job container provisioner (ADR-0001 Phase 3,
# advances #82). This is the isolation CORE the ADR calls out: the scale-set
# client decides when / how many runners, but the per-job container -- where the
# residue/secret guarantees actually land -- is ours. Each ephemeral job runs in
# a FRESH, single-use, rootless container that is torn down on exit, so no state
# (a poisoned _work tree, leaked secrets in env/cache/disk) survives the job.
# The container is the unit of isolation -- one ephemeral `run.sh --jitconfig`
# run, walled off from the host and from every other job.
#
# Sourced by lib/common.sh. This is the SINGLE place the one-job
# `run.sh --jitconfig <encoded>` invocation lives, executed INSIDE the throwaway
# container rather than directly on the host. The encoded JIT config is minted
# by the Go scale-set client (ADR-0001/ADR-0003), not by any bash seam.
# shellcheck shell=bash

# The label value that marks every container THIS tool provisions, so the
# orphan reaper (#105) can find and remove our containers (and only ours)
# without touching anything else on the host. Overridable for tests / multiple
# fleets on one host.
: "${RUNNER_MANAGED_BY:=github-runner-listener}"

# Deterministic container name for a job id (#104): the same job id always maps
# to the same name, so a container can be correlated and reaped by name. Sanitise
# the job id to the [a-zA-Z0-9_.-] set Docker/Podman allow in names (anything
# else becomes '-'), prefixed so our containers are recognisable at a glance.
#   runner_container_name <job_id>
runner_container_name() {
  local job_id=$1 safe
  safe=$(printf '%s' "${job_id}" | tr -c 'a-zA-Z0-9_.-' '-')
  printf 'gha-jit-%s' "${safe}"
}

# Pick the rootless container CLI: podman preferred over docker (rootless is
# podman's default mode -- no daemon, no root -- which is the #82 goal; docker
# is the fallback for hosts that only ship it). Prints the CLI name, or returns
# non-zero (printing nothing) when neither is on PATH, so the caller can fail
# with one clear line instead of an obscure command-not-found mid-run.
runner_container_cli() {
  if command -v podman >/dev/null 2>&1; then
    printf 'podman'
  elif command -v docker >/dev/null 2>&1; then
    printf 'docker'
  else
    return 1
  fi
}

# Run exactly one ephemeral job inside a throwaway, rootless container, then let
# it be torn down -- the per-job isolation boundary.
#   runner_container_run <dir> <encoded_jit_config> <image> [job_id]
# Detects the CLI (runner_container_cli), then `<cli> run --rm ...` the image so
# the container is single-use and removed on exit (--rm: no state survives),
# executing the Phase 2 ephemeral run (run.sh --jitconfig <encoded>) inside it.
# Rootless-appropriate: --init reaps the runner's child PIDs (no host init), and
# --security-opt label=disable / no extra privileges keep it an unprivileged,
# self-contained unit. When a job id is given, the container gets a DETERMINISTIC
# --name and managed-by + job-id --labels (#104) so the reaper (#105) can
# correlate and remove orphans. PROPAGATES the in-container job's exit status (it
# is the whole job lifecycle). The runner dir is mounted so the bundled run.sh
# runs from inside the container against the JIT config.
runner_container_run() {
  local dir=$1 encoded=$2 image=$3 job_id=${4:-} cli
  cli=$(runner_container_cli) || {
    echo "FAIL: no rootless container CLI found (need podman or docker)" >&2
    return 1
  }
  # Build the identity args (name + labels) only when a job id is supplied, so
  # the deterministic name and managed-by/job-id labels keyed by the job id let
  # the orphan reaper find exactly our containers.
  local -a id_args=()
  if [[ -n "${job_id}" ]]; then
    id_args=(
      --name "$(runner_container_name "${job_id}")"
      --label "managed-by=${RUNNER_MANAGED_BY}"
      --label "job-id=${job_id}"
    )
  fi
  "${cli}" run --rm --init \
    --security-opt label=disable \
    "${id_args[@]}" \
    -v "${dir}:/runner" -w /runner \
    "${image}" \
    ./run.sh --jitconfig "${encoded}"
}
