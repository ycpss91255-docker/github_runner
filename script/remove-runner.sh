#!/usr/bin/env bash
# Deregister + uninstall service + remove directory. Idempotent.
# Usage:
#   ./script/remove-runner.sh org <org>
#   ./script/remove-runner.sh repo <owner> <repo>
set -euo pipefail

# shellcheck source=SCRIPTDIR/../lib/common.sh
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

main() {
  resolve_target "$@"

  if [[ ! -f "${TARGET_DIR}/.runner" ]]; then
    echo "no runner at ${TARGET_DIR}, nothing to remove."
    exit 0
  fi

  pushd "${TARGET_DIR}" >/dev/null
  sudo ./svc.sh stop || true
  sudo ./svc.sh uninstall || true

  local token
  token=$(github_runner_token "${TARGET_API_REMOVE_PATH}")
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
