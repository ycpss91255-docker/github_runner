#!/usr/bin/env bash
# history.sh -- query the job-history / audit-trail store (ADR-0002, #126). Reads
# the append-only ledger under RUNNER_HISTORY_DIR (RUNNER_HOME/history) and lets
# an operator look up jobs by id / time range / repo / outcome, human-readable or
# --json:
#
#       ./script/history.sh                       # every job
#       ./script/history.sh --id <job-id>
#       ./script/history.sh --repo <owner/repo>
#       ./script/history.sh --outcome success|failure
#       ./script/history.sh --since <ts> --until <ts>   # ISO-8601 UTC
#       ./script/history.sh --id <job-id> --json
#
# Read-only: it never mutates the store.
set -euo pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
# shellcheck source=SCRIPTDIR/../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--id ID] [--repo OWNER/REPO] [--outcome success|failure]
                       [--since TS] [--until TS] [--json]
       $(basename "$0") -h | --help

Query the job-history store under \${RUNNER_HISTORY_DIR} (read-only).

Options:
  --id ID           Only the job with this id.
  --repo OWNER/REPO Only jobs whose trigger_repo matches.
  --outcome WHICH   success (exit_status=0) or failure (non-zero).
  --since TS        Only jobs with ts >= TS (ISO-8601 UTC, lexical compare).
  --until TS        Only jobs with ts <  TS.
  --json            Emit one JSON object per matched record (scriptable).

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

main() {
  case "${1:-}" in
    -h|--help) usage; exit 0 ;;
    *)         cmd_query "$@" ;;
  esac
}

if [[ "${BASH_SOURCE[0]:-}" == "${0}" ]]; then
  main "$@"
fi
