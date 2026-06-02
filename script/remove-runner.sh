#!/usr/bin/env bash
# Deregister + uninstall service + remove directory. Idempotent.
# Usage:
#   ./script/remove-runner.sh org <org>
#   ./script/remove-runner.sh repo <owner> <repo>
set -euo pipefail

# shellcheck source=SCRIPTDIR/../lib/common.sh
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

usage() {
  cat <<EOF
Usage:
  $(basename "$0") org <org>
  $(basename "$0") repo <owner> <repo>

Deregister a runner, uninstall its service, and remove its directory. Idempotent.
EOF
}

main() {
  case "${1:-}" in -h|--help) usage; exit 0 ;; esac
  resolve_target "$@"

  if [[ ! -f "${TARGET_DIR}/.runner" ]]; then
    echo "no runner at ${TARGET_DIR}, nothing to remove."
    exit 0
  fi

  # U3: gate on auth and fetch the remove-token BEFORE any service teardown,
  # so an unauthenticated / offline host fails cleanly instead of leaving a
  # stopped-but-still-registered (half-removed) runner.
  require_gh_auth
  local token
  token=$(github_runner_token "${TARGET_API_REMOVE_PATH}")

  pushd "${TARGET_DIR}" >/dev/null
  sudo ./svc.sh stop || true
  sudo ./svc.sh uninstall || true
  ./config.sh remove --token "${token}"
  popd >/dev/null

  # SEC-4 defense-in-depth: TARGET_DIR is already confined by RUNNER_HOME's
  # SEC-3 normalization + resolve_target's identifier validation, but anchor
  # the rm to RUNNER_HOME lexically before deleting, so no future change can
  # turn this into an out-of-tree rm -rf.
  case "${TARGET_DIR}/" in
    "${RUNNER_HOME}/"*) : ;;
    *) echo "refusing rm outside RUNNER_HOME: ${TARGET_DIR}" >&2; exit 1 ;;
  esac
  rm -rf "${TARGET_DIR}"
  echo "removed: ${TARGET_NAME}"
}

main "$@"
