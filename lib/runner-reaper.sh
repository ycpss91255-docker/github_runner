#!/usr/bin/env bash
# Runner Reaper -- the lifecycle janitor for the ephemeral listener (ADR-0001,
# #105/#106/#107). provision-job.sh runs each job in a --rm container under a
# per-job mktemp dir removed on a trap, so the happy path leaves zero residue.
# But a crash (the listener or host dies mid-job, the trap never fires) can
# strand a labelled container and its temp dir. This seam is the safety net: it
# sweeps containers carrying OUR managed-by label (#104) that are no longer
# tracked and removes them, prunes leaked per-job temp dirs scoped to the work
# root, and -- via the watchdog -- bounds a single container's wall-clock
# lifetime so a hung job cannot hold the host forever.
#
# Reaping lives in bash (ADR-0003: the Go side is only the scale-set brain; the
# host-cleanup hands are bash). The Go listener invokes these at startup and on
# an interval, passing the job ids it is currently tracking so they are spared.
# shellcheck shell=bash

# runner_reap_orphans [tracked_job_id ...]
# Remove every container carrying managed-by=$RUNNER_MANAGED_BY whose job-id
# label is NOT in the tracked set. With no tracked ids, every labelled container
# is an orphan (the startup sweep, when nothing is in-flight yet). Scoped to our
# label so foreign containers are never touched. A failed remove of one
# container does not stop the sweep. Returns 0.
runner_reap_orphans() {
  local -a tracked=("$@")
  local cli
  cli=$(runner_container_cli) || {
    echo "reaper: no container CLI found, skipping orphan sweep" >&2
    return 0
  }

  # List our containers as "<name> <job-id>" rows. --filter scopes to our label
  # so we only ever see (and remove) containers this tool provisioned.
  local name job_id
  while read -r name job_id; do
    [[ -n "${name}" ]] || continue
    if _runner_reaper_is_tracked "${job_id}" "${tracked[@]}"; then
      continue
    fi
    echo "reaper: removing orphan container ${name} (job-id=${job_id:-?})" >&2
    "${cli}" rm -f "${name}" >/dev/null 2>&1 || \
      echo "reaper: failed to remove ${name}" >&2
  done < <(
    "${cli}" ps --all \
      --filter "label=managed-by=${RUNNER_MANAGED_BY}" \
      --format '{{.Names}} {{.Label "job-id"}}' 2>/dev/null
  )
  return 0
}

# runner_prune_temp_dirs <work_root> [tracked_job_id ...]
# Remove leaked per-job temp dirs (jit-<job_id>.XXXXXX, created by
# provision-job.sh) under <work_root> that are NOT tracked, so a job killed
# before its EXIT trap fired leaves no residue. A dir is spared iff it belongs
# to a tracked job (its name starts with "jit-<id>."). STRICTLY scoped to
# <work_root>: the root must be absolute and not a dangerous path, and pruning
# only ever globs "<root>/jit-*" -- a tracked id can never widen the target or
# escape the root (the id is only ever compared, never path-joined). Returns 0.
runner_prune_temp_dirs() {
  local work_root=$1; shift
  local -a tracked=("$@")

  # Scope guard: refuse a relative or dangerous root so a misconfig can never
  # turn this into an rm outside an intended work tree (mirrors SEC-3).
  [[ "${work_root}" = /* ]] || {
    echo "prune: work root must be absolute: '${work_root}'" >&2; return 1; }
  work_root="${work_root%/}"
  case "${work_root}" in
    ""|/|/.|/..|"${HOME:-}") echo "prune: refusing work root '${work_root}'" >&2; return 1 ;;
  esac
  case "/${work_root}/" in
    */../*) echo "prune: work root must be normalized (no '..'): '${work_root}'" >&2; return 1 ;;
  esac

  shopt -s nullglob
  local dir base
  for dir in "${work_root}"/jit-*; do
    [[ -d "${dir}" ]] || continue
    base=$(basename "${dir}")
    if _runner_prune_is_tracked "${base}" "${tracked[@]}"; then
      continue
    fi
    # Defence in depth: never rm anything not anchored under the work root.
    case "${dir}/" in
      "${work_root}/"*) ;;
      *) echo "prune: refusing rm outside work root: ${dir}" >&2; continue ;;
    esac
    echo "prune: removing stale temp dir ${base}" >&2
    rm -rf "${dir}"
  done
  return 0
}

# _runner_prune_is_tracked <dir_basename> [tracked...] -- true (0) if the
# jit-<id>.XXXXXX dir belongs to a tracked job id (name starts "jit-<id>.").
_runner_prune_is_tracked() {
  local base=$1; shift
  local t
  for t in "$@"; do
    [[ -n "${t}" ]] || continue
    [[ "${base}" == "jit-${t}."* ]] && return 0
  done
  return 1
}

# _runner_reaper_is_tracked <job_id> [tracked...] -- true (0) if job_id is in
# the tracked set, so a live job's container is spared. An empty job_id is never
# tracked (treated as an orphan).
_runner_reaper_is_tracked() {
  local needle=$1; shift
  [[ -n "${needle}" ]] || return 1
  local t
  for t in "$@"; do
    [[ "${t}" == "${needle}" ]] && return 0
  done
  return 1
}
