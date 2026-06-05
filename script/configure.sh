#!/usr/bin/env bash
# Generate / update the runner registration config (setup.conf) that
# add-runner.sh and init.sh read at registration time. Idempotent.
# Usage:
#   ./script/configure.sh --labels <csv>   # set labels for NEW runners
#   ./script/configure.sh                   # print the current effective config
#
# Note: setup.conf only affects runners registered AFTER it is written.
# To relabel an already-registered runner live, use ./script/set-labels.sh.
set -euo pipefail

# shellcheck source=SCRIPTDIR/../lib/common.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/common.sh"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--labels <csv>]

Options:
  --labels <csv>   Comma-separated labels for newly registered runners
                   (each token [A-Za-z0-9_-]). Written to ${SETUP_CONF}.
  -h, --help       Show this help.

With no arguments, print the current effective config (resolved LABELS).
EOF
}

# Upsert LABELS=<value> in SETUP_CONF, creating the file (with a header)
# when absent and replacing an existing LABELS line in place otherwise.
write_labels() {
  local value=$1
  mkdir -p "${RUNNER_HOME}"
  if [[ -f "${SETUP_CONF}" ]] && grep -q '^LABELS=' "${SETUP_CONF}"; then
    sed -i "s|^LABELS=.*|LABELS=${value}|" "${SETUP_CONF}"
  else
    [[ -f "${SETUP_CONF}" ]] || printf '# github_runner registration config\n' >"${SETUP_CONF}"
    printf 'LABELS=%s\n' "${value}" >>"${SETUP_CONF}"
  fi
}

main() {
  if [[ $# -eq 0 ]]; then
    load_config
    echo "LABELS=${LABELS}"
    return 0
  fi

  local labels=""
  while [[ $# -gt 0 ]]; do
    case $1 in
      --labels)
        [[ $# -ge 2 ]] || { echo "missing value for --labels" >&2; usage >&2; exit 1; }
        labels=$2; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) echo "unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
  done

  if ! validate_labels "${labels}"; then
    echo "invalid labels: '${labels}' (use comma-separated [A-Za-z0-9_-] tokens)" >&2
    exit 1
  fi

  write_labels "${labels}"
  echo "configured: LABELS=${labels} -> ${SETUP_CONF}"
}

if [[ "${BASH_SOURCE[0]:-}" == "${0}" ]]; then
  main "$@"
fi
