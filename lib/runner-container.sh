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
# by the Go scale-set client (ADR-0001/ADR-0003), not by any bash seam, and is
# delivered into the container OFF the host argv via a mode-0600 --env-file
# (#136), so the single-use credential never lands in the HOST process table --
# the ADR-0003 invariant holds on the bash side, not just the Go side.
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

# Precise device passthrough (#117). The host device nodes a runner type declares
# (RunnerType.Devices in the config, e.g. /dev/nvidia0), passed as the listener's
# shell-out parameter. Each becomes one `--device <node>` -- least-privilege, and
# NEVER --privileged. Whitespace-separated (newline or space) so the listener can
# pass the type's device list verbatim. Empty (a plain CPU type) = no --device.
: "${RUNNER_DEVICES:=}"

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

# Sanitise the attacker-influenced job id for use as a LABEL value (#137). The
# scale-set JobID flows into our job-id label unsanitized; a NEWLINE (or other
# control char) in that label is what let the reaper's old "<name> <label>"
# listing be split into a forged phantom row naming an arbitrary victim. Strip
# every control character (incl. CR/LF/TAB) so the label can never carry a line
# break. Kept less aggressive than the name sanitiser (the label is
# informational, not a shell/engine identifier); the control-char strip is the
# security-load-bearing part, and the reaper additionally reaps by container ID
# so it never parses this value as a removal target.
#   runner_job_id_label <job_id>
runner_job_id_label() {
  local job_id=$1
  printf '%s' "${job_id}" | tr -d '[:cntrl:]'
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
# The encoded credential is passed to the container via a mode-0600 --env-file
# (#136), never on the host `<cli> run` argv, so it stays off the host process
# table; run.sh reads it from $JITCONFIG inside the container's own namespace.
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
      --label "job-id=$(runner_job_id_label "${job_id}")"
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
  # Precise --device passthrough (#117): one --device per declared host node, no
  # --privileged. Word-splitting RUNNER_DEVICES on whitespace is intentional so a
  # newline- or space-separated device list maps to exactly those nodes.
  local -a device_args=() dev
  for dev in ${RUNNER_DEVICES}; do
    device_args+=(--device "${dev}")
  done
  # Deliver the single-use JIT credential to the container OFF the host argv
  # (#136, restores the ADR-0003 invariant). Splicing `--jitconfig "${encoded}"`
  # directly onto the host `<cli> run ...` argv put the credential in the HOST
  # process table (/proc/<pid>/cmdline, world-readable) for the container's whole
  # life -- the exact exposure the Go->bash file handoff exists to prevent. The
  # Go side keeps it off ITS argv (a 0600 file, ADR-0003); bash must not undo
  # that here. Instead write the credential to a mode-0600 --env-file inside the
  # (throwaway, per-job) runner dir as KEY=VALUE; the engine reads the VALUE from
  # the file, so only the env-file PATH -- never the secret -- is on the host
  # argv. The env-file is named in the dir torn down with the job (--rm + the
  # caller's rm -rf), so the credential file does not survive teardown.
  #
  # The container then receives the credential via $JITCONFIG in ITS OWN process
  # namespace and passes it to run.sh; `sh -c` expands it inside the container,
  # not on the host CLI argv. The container's /proc shows only container PIDs
  # (rootless), so this re-exposes nothing to other HOST users.
  # The env-file MUST live OUTSIDE the bind-mounted runner dir (#140). `${dir}`
  # is mounted READ-WRITE at /runner and IS the job's working directory, so a
  # file written under it (`${dir}/.jitconfig.env`) is visible to -- and copyable
  # by -- the hostile job at /runner/.jitconfig.env. The job could then plant the
  # single-use credential into /runner/_diag, which the history hook durably
  # archives, surviving the --rm teardown. Writing the env-file as a SIBLING of
  # the mounted dir keeps the credential out of every job-reachable path while
  # the engine still reads its VALUE from the file (never the host argv, #136).
  # The sibling sits beside `${dir}` under the same throwaway work root, so the
  # caller's `rm -rf "${runner_dir}"` does not remove it -- we delete it here on
  # return (success or failure) via a RETURN trap so the credential file does not
  # outlive this function.
  local env_file="${dir%/}.jitconfig.env"
  # Restrict before writing so the secret never exists world-readable, even
  # briefly. printf (not echo) so a value with leading '-' is written verbatim;
  # the single KEY=VALUE line is the --env-file format the engines expect.
  ( umask 077; : >"${env_file}"; )
  printf 'JITCONFIG=%s\n' "${encoded}" >"${env_file}"
  # Shred the sibling env-file when this function returns, by ANY path, so the
  # single-use credential never lingers on disk past the container's run.
  #
  # The trap action MUST embed the path as code, because `env_file` is a function
  # LOCAL and bash runs a RETURN trap in the CALLER's scope (the bounded wrapper),
  # where the local is already gone -- a deferred `"${env_file}"` would hit
  # `set -u` "unbound variable" and abort the job. So the path is expanded now;
  # the danger is that `dir` (hence env_file) embeds the only-control-char-
  # stripped scale-set JobID verbatim (mktemp -d jit-<job_id>.XXXXXX). A path
  # spliced inside single quotes in a double-quoted trap let a `'` in a hostile
  # JobID close the quoting so a trailing `; <cmd> #` ran on the HOST when the
  # trap fired (#142). printf %q renders the path in a re-parse-safe form
  # (quotes, ;, space, $(...) all escaped), so the trap is exactly one `rm`
  # argument and no attacker data is ever parsed as a command.
  local env_file_q
  printf -v env_file_q '%q' "${env_file}"
  # shellcheck disable=SC2064  # expand NOW (local not in scope on RETURN); %q-safe
  trap "rm -f -- ${env_file_q}" RETURN

  # The in-container command. $JITCONFIG is expanded by the CONTAINER's shell
  # (set there from --env-file), so this string is kept literal on the host --
  # the credential never appears on the host argv. The single quotes are
  # deliberate (#136); SC2016 is expected and would defeat the fix if "fixed".
  # shellcheck disable=SC2016
  local run_in_container='./run.sh --jitconfig "${JITCONFIG}"'

  # Bind the runner dir with :Z so the engine relabels it for this container
  # (#115) -- MAC (SELinux/AppArmor) stays ENFORCED; we never disable it.
  "${cli}" run --rm --init \
    "${hardening_args[@]}" \
    "${socket_args[@]}" \
    "${device_args[@]}" \
    "${id_args[@]}" \
    --env-file "${env_file}" \
    -v "${dir}:/runner:Z" -w /runner \
    "${image}" \
    sh -c "${run_in_container}"
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
