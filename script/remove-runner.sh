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

  rm -rf "${TARGET_DIR}"
  echo "removed: ${TARGET_NAME}"
}

main "$@"
