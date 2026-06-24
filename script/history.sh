#!/usr/bin/env bash
# history.sh -- query and prune the job-history / audit-trail store (ADR-0002,
# #126/#127). Reads the append-only ledger and per-job archives under
# RUNNER_HISTORY_DIR (RUNNER_HOME/history) and lets an operator:
#
#   - LOOK UP jobs by id / time range / repo / outcome, human-readable or --json
#       ./script/history.sh                       # every job
#       ./script/history.sh --id <job-id>
#       ./script/history.sh --repo <owner/repo>
#       ./script/history.sh --outcome success|failure
#       ./script/history.sh --since <ts> --until <ts>   # ISO-8601 UTC
#       ./script/history.sh --id <job-id> --json
#
#   - PRUNE the store by BOTH a size cap (GB) and an age cap (days), oldest-first
#       ./script/history.sh prune [--max-gb N] [--max-days N] [--yes | --dry-run]
#
# The query is read-only; prune is destructive and (like cleanup.sh) refuses to
# run unattended without --yes. The retention logic itself lives in
# lib/runner-history.sh so the scheduled cleanup (cleanup.sh, #127) reuses it.
set -euo pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
# shellcheck source=SCRIPTDIR/../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--id ID] [--repo OWNER/REPO] [--outcome success|failure]
                       [--since TS] [--until TS] [--json]
       $(basename "$0") prune [--max-gb N] [--max-days N] [--yes | --dry-run]
       $(basename "$0") -h | --help

Query or prune the job-history store under \${RUNNER_HISTORY_DIR}.

Query options (read-only):
  --id ID           Only the job with this id.
  --repo OWNER/REPO Only jobs whose trigger_repo matches.
  --outcome WHICH   success (exit_status=0) or failure (non-zero).
  --since TS        Only jobs with ts >= TS (ISO-8601 UTC, lexical compare).
  --until TS        Only jobs with ts <  TS.
  --json            Emit one JSON object per matched record (scriptable).

Prune (destructive; enforces retention #127):
  --max-gb N        Size cap in GB    (default \${RUNNER_HISTORY_MAX_GB}).
  --max-days N      Age cap in days   (default \${RUNNER_HISTORY_MAX_DAYS}).
  --yes             Proceed (required for non-interactive runs).
  --dry-run | -n    Print what WOULD be evicted; remove nothing.

Exit code: 0 success / no-op; 1 usage error.
EOF
}

# Turn one TAB-separated ledger line ("k=v\tk=v...") into a JSON object. Pure
# bash (no jq dependency for emit), with minimal escaping of \ and " in values.
record_to_json() {
  local line=$1 first=1 kv k v out="{"
  local IFS=$'\t'
  for kv in ${line}; do
    [[ -n "${kv}" ]] || continue
    k=${kv%%=*}; v=${kv#*=}
    v=${v//\\/\\\\}; v=${v//\"/\\\"}
    (( first )) || out+=","
    first=0
    out+="\"${k}\":\"${v}\""
  done
  out+="}"
  printf '%s\n' "${out}"
}

# Extract a field value from a ledger line, or empty.
field() {
  local line=$1 key=$2 kv k
  local IFS=$'\t'
  for kv in ${line}; do
    k=${kv%%=*}
    [[ "${k}" == "${key}" ]] && { printf '%s' "${kv#*=}"; return 0; }
  done
  return 0
}

cmd_query() {
  local f_id="" f_repo="" f_outcome="" f_since="" f_until="" json=0
  while [[ $# -gt 0 ]]; do
    case $1 in
      --id)      f_id=${2:?--id needs a value}; shift 2 ;;
      --repo)    f_repo=${2:?--repo needs a value}; shift 2 ;;
      --outcome) f_outcome=${2:?--outcome needs a value}; shift 2 ;;
      --since)   f_since=${2:?--since needs a value}; shift 2 ;;
      --until)   f_until=${2:?--until needs a value}; shift 2 ;;
      --json)    json=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) echo "unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
  done

  [[ -f "${RUNNER_HISTORY_LEDGER}" ]] || return 0

  local line id repo exit_status ts
  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    id=$(field "${line}" job_id)
    repo=$(field "${line}" trigger_repo)
    exit_status=$(field "${line}" exit_status)
    ts=$(field "${line}" ts)

    [[ -n "${f_id}"   && "${id}"   != "${f_id}"   ]] && continue
    [[ -n "${f_repo}" && "${repo}" != "${f_repo}" ]] && continue
    if [[ -n "${f_outcome}" ]]; then
      case "${f_outcome}" in
        success) [[ "${exit_status}" == "0" ]] || continue ;;
        failure) [[ "${exit_status}" != "0" ]] || continue ;;
        *) echo "invalid --outcome: ${f_outcome} (success|failure)" >&2; exit 1 ;;
      esac
    fi
    # ISO-8601 UTC sorts lexically, so a string compare is a correct time
    # compare for the canonical ...Z form the ledger writes.
    [[ -n "${f_since}" && "${ts}" <  "${f_since}" ]] && continue
    [[ -n "${f_until}" && ! "${ts}" < "${f_until}" ]] && continue

    if (( json )); then
      record_to_json "${line}"
    else
      printf '%s\n' "${line}"
    fi
  done < "${RUNNER_HISTORY_LEDGER}"
}

cmd_prune() {
  local max_gb=${RUNNER_HISTORY_MAX_GB} max_days=${RUNNER_HISTORY_MAX_DAYS}
  local yes=0 dry=0
  while [[ $# -gt 0 ]]; do
    case $1 in
      --max-gb)   max_gb=${2:?--max-gb needs a value}; shift 2 ;;
      --max-days) max_days=${2:?--max-days needs a value}; shift 2 ;;
      --yes|-y)   yes=1; shift ;;
      --dry-run|-n) dry=1; shift ;;
      -h|--help)  usage; exit 0 ;;
      *) echo "unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
  done

  if (( dry )); then
    echo "Dry-run; archives that WOULD be pruned (size cap ${max_gb} GB, age cap ${max_days} d, oldest-first):"
    runner_history_prune_plan "${max_gb}" "${max_days}" | sed 's/^/  /'
    echo "Dry-run; nothing removed."
    return 0
  fi

  if (( ! yes )); then
    if [[ ! -t 0 ]]; then
      echo "FAIL: prune is destructive; non-interactive run requires --yes" >&2
      exit 1
    fi
    local ans
    read -r -p "Prune history beyond ${max_gb} GB / ${max_days} days? [y/N] " ans
    case ${ans} in y|Y|yes|YES) ;; *) echo "Aborted."; return 0 ;; esac
  fi

  runner_history_prune "${max_gb}" "${max_days}"
}

main() {
  case "${1:-}" in
    -h|--help) usage; exit 0 ;;
    prune)     shift; cmd_prune "$@" ;;
    *)         cmd_query "$@" ;;
  esac
}

if [[ "${BASH_SOURCE[0]:-}" == "${0}" ]]; then
  main "$@"
fi
