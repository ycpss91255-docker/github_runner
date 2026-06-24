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

# Per-job max wall-clock lifetime in seconds (#107): the watchdog stops+removes
# a container that outlives this, so a hung job cannot hold host resources
# forever. Default 6h; override for shorter/longer ceilings. 0 disables it.
: "${RUNNER_JOB_MAX_LIFETIME:=21600}"

# Baseline container-hardening knobs (#114, ADR-0001 "defense-in-depth on every
# job container"). Every per-job container drops ALL Linux capabilities, runs
# with no-new-privileges (a job can never gain privileges via setuid), and is
# bounded by a pids-limit (a fork bomb cannot exhaust host PIDs). The default
# seccomp profile is KEPT (we never pass seccomp=unconfined) and MAC stays
# enforced (#115). Add-back is empty by default -- the runner needs no
# capabilities to execute actions -- but RUNNER_CAP_ADD lets a runner type grant
# a minimal, explicit set when a job genuinely needs one (space-separated cap
# names, e.g. "NET_BIND_SERVICE").
: "${RUNNER_PIDS_LIMIT:=4096}"
: "${RUNNER_CAP_ADD:=}"

# Docker-socket opt-in (#116). By DEFAULT a job container NEVER receives the host
# docker socket -- so job code cannot reach the host daemon (root-equivalence) --
# and image builds go through the daemonless build seam (#118) instead. A runner
# type that genuinely needs the daemon opts in EXPLICITLY by setting this to the
# host socket path; the listener only sets it for a type that asked for it. Empty
# = no socket mount (the secure default).
: "${RUNNER_DOCKER_SOCKET:=}"

# Emit the baseline hardening argv (#114) one token per array element, for the
# caller to splice into `<cli> run`. cap-drop=ALL + optional minimal add-back,
# no-new-privileges, and a pids-limit. Deliberately does NOT touch seccomp (the
# engine default profile stays on) or MAC (kept enforced, #115).
#   runner_container_hardening_args  -> prints flags, newline-separated
runner_container_hardening_args() {
  local -a args=(
    --cap-drop=ALL
    --security-opt no-new-privileges
    --pids-limit "${RUNNER_PIDS_LIMIT}"
  )
  local cap
  for cap in ${RUNNER_CAP_ADD}; do
    args+=(--cap-add="${cap}")
  done
  printf '%s\n' "${args[@]}"
}

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
# Rootless-appropriate: --init reaps the runner's child PIDs (no host init); the
# baseline hardening flags (#114) and the :Z-relabelled mount (#115, MAC kept
# enforced) keep it an unprivileged, self-contained unit. When a job id is given,
# the container gets a DETERMINISTIC
# --name and managed-by + job-id --labels (#104) so the reaper (#105) can
# correlate and remove orphans. PROPAGATES the in-container job's exit status (it
# is the whole job lifecycle). The runner dir is mounted so the bundled run.sh
# runs from inside the container against the JIT config.
runner_container_run() {
  local dir=$1 encoded=$2 image=$3 job_id=${4:-} cli line
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
  # Baseline hardening flags (#114): read one-per-line into an array so each
  # token survives as its own argv word.
  local -a hardening_args=()
  while IFS= read -r line; do hardening_args+=("${line}"); done < <(runner_container_hardening_args)
  # Docker-socket opt-in (#116): NEVER mounted by default. Only a runner type
  # that explicitly set RUNNER_DOCKER_SOCKET gets it, relabelled :Z so MAC stays
  # enforced. The empty default leaves the array empty -> no socket reaches a job.
  local -a socket_args=()
  if [[ -n "${RUNNER_DOCKER_SOCKET}" ]]; then
    socket_args=(-v "${RUNNER_DOCKER_SOCKET}:${RUNNER_DOCKER_SOCKET}:Z")
  fi
  # Bind the runner dir with :Z so the engine relabels it for this container
  # (#115) -- MAC (SELinux/AppArmor) stays ENFORCED; we never disable it.
  "${cli}" run --rm --init \
    "${hardening_args[@]}" \
    "${socket_args[@]}" \
    "${id_args[@]}" \
    -v "${dir}:/runner:Z" -w /runner \
    "${image}" \
    ./run.sh --jitconfig "${encoded}"
}

# runner_container_kill <name>
# Force-stop then remove a named container and log it -- the action a watchdog
# (#107) or operator takes against a hung job. `stop` first (graceful, then the
# engine SIGKILLs after its own grace), `rm -f` to be sure nothing lingers even
# if --rm did not fire. Best-effort: a failure of either step is logged, not
# fatal. Returns 0.
runner_container_kill() {
  local name=$1 cli
  cli=$(runner_container_cli) || {
    echo "watchdog: no container CLI to kill ${name}" >&2; return 0; }
  echo "watchdog: max lifetime exceeded, stopping+removing container ${name}" >&2
  "${cli}" stop "${name}" >/dev/null 2>&1 || true
  "${cli}" rm "${name}"   >/dev/null 2>&1 || true
  return 0
}

# runner_container_exists <name> -- true (0) if a container with this name is
# still present (running or not), via `ps -q --filter name=`. Used by the
# watchdog to decide whether the deadline actually caught a live job.
runner_container_exists() {
  local name=$1 cli out
  cli=$(runner_container_cli) || return 1
  out=$("${cli}" ps --all --quiet --filter "name=^${name}$" 2>/dev/null)
  [[ -n "${out}" ]]
}

# runner_container_watchdog <name> <timeout_secs>
# Bound a single container's wall-clock lifetime (#107): wait the timeout, then
# if the container is STILL present, stop+remove+log it (a hung job). If the job
# finished within the deadline (container gone) it is a no-op. timeout <= 0
# disables the watchdog (returns immediately). Meant to run in the background
# beside runner_container_run; the caller cancels it (a TERM) on normal
# completion so it never fires for a job that finished in time.
#
# The wait is a BACKGROUND sleep plus a TERM trap that kills it, so a single
# `kill` on this function's (subshell) pid cancels the timer cleanly -- no
# orphaned sleep left holding resources or an inherited fd. This avoids relying
# on `ps --ppid` / pkill, which BusyBox `ps` does not support.
runner_container_watchdog() {
  local name=$1 timeout=$2 sleep_pid=
  [[ "${timeout}" -gt 0 ]] 2>/dev/null || return 0
  # On cancellation, kill the pending sleep and exit without firing.
  trap '[[ -n "${sleep_pid}" ]] && kill "${sleep_pid}" 2>/dev/null; exit 0' TERM
  sleep "${timeout}" &
  sleep_pid=$!
  wait "${sleep_pid}" 2>/dev/null
  trap - TERM
  if runner_container_exists "${name}"; then
    runner_container_kill "${name}"
  fi
  return 0
}

# runner_container_run_bounded <dir> <encoded> <image> <job_id> [timeout]
# runner_container_run with a background watchdog (#107) keyed off the job's
# deterministic name. The watchdog enforces the per-job max lifetime (default
# RUNNER_JOB_MAX_LIFETIME); on normal completion it is killed so it never fires
# for an in-time job. PROPAGATES the in-container job's exit status. Requires a
# job id (the name the watchdog targets).
runner_container_run_bounded() {
  local dir=$1 encoded=$2 image=$3 job_id=$4 timeout=${5:-${RUNNER_JOB_MAX_LIFETIME}}
  [[ -n "${job_id}" ]] || { echo "FAIL: bounded run needs a job id" >&2; return 2; }

  local name wd_pid=
  name=$(runner_container_name "${job_id}")
  if [[ "${timeout}" -gt 0 ]] 2>/dev/null; then
    # Background the watchdog with its own stdin/stdout closed off the caller's
    # captured pipe, so cancelling it (below) does not leave `run`/the listener
    # blocked waiting on an inherited fd held open by its sleep child.
    runner_container_watchdog "${name}" "${timeout}" </dev/null >/dev/null 2>&1 &
    wd_pid=$!
  fi

  local rc=0
  runner_container_run "${dir}" "${encoded}" "${image}" "${job_id}" || rc=$?

  # Job finished (in time or by error): cancel the watchdog with a TERM, which
  # its trap turns into "kill the pending sleep and exit" -- no orphaned sleep
  # left holding resources or the inherited fd.
  if [[ -n "${wd_pid}" ]]; then
    kill -TERM "${wd_pid}" >/dev/null 2>&1 || true
    wait "${wd_pid}" 2>/dev/null || true
  fi
  return "${rc}"
}
