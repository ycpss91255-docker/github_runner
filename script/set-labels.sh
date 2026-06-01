#!/usr/bin/env bash
# Relabel an ALREADY-registered runner live via the GitHub API -- no
# remove + re-register needed. Replaces the runner's CUSTOM labels;
# GitHub keeps the system labels (self-hosted / Linux / X64) automatically.
# Usage:
#   ./script/set-labels.sh org <org> <csv>
#   ./script/set-labels.sh repo <owner> <repo> <csv>
#
# To set the default labels for NEW runners instead, use configure.sh.
set -euo pipefail

# shellcheck source=SCRIPTDIR/../lib/common.sh
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

usage() {
  cat <<EOF
Usage:
  $(basename "$0") org <org> <csv>
  $(basename "$0") repo <owner> <repo> <csv>

<csv> is a comma-separated label list (each token [A-Za-z0-9_-]).
Replaces the runner's custom labels via the GitHub API.
EOF
}

main() {
  local scope="${1:-}" labels="" api_base=""
  case "${scope}" in
    org)
      [[ $# -eq 3 ]] || { echo "org scope needs <org> <csv>" >&2; usage >&2; exit 1; }
      resolve_target org "$2"
      labels="$3"
      api_base="$(runner_api_base org "$2")"
      ;;
    repo)
      [[ $# -eq 4 ]] || { echo "repo scope needs <owner> <repo> <csv>" >&2; usage >&2; exit 1; }
      resolve_target repo "$2" "$3"
      labels="$4"
      api_base="$(runner_api_base repo "$2" "$3")"
      ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown scope: ${scope:-<none>}" >&2; usage >&2; exit 1 ;;
  esac

  if ! validate_labels "${labels}"; then
    echo "invalid labels: '${labels}' (use comma-separated [A-Za-z0-9_-] tokens)" >&2
    exit 1
  fi

  if [[ ! -f "${TARGET_DIR}/.runner" ]]; then
    echo "no runner at ${TARGET_DIR}; register it first with ./script/add-runner.sh" >&2
    exit 1
  fi

  local id
  id=$(runner_agent_id "${TARGET_DIR}")
  if [[ -z "${id}" ]]; then
    echo "could not read agentId from ${TARGET_DIR}/.runner" >&2
    exit 1
  fi

  github_set_labels "${api_base}" "${id}" "${labels}"
  echo "set labels on ${TARGET_NAME} (id ${id}): ${labels}"
}

main "$@"
