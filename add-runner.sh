#!/usr/bin/env bash
# Register a new self-hosted runner (org or repo level). Idempotent.
# Usage:
#   ./add-runner.sh org <org>
#   ./add-runner.sh repo <owner> <repo>
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(dirname "$(readlink -f "$0")")/lib/common.sh"

main() {
  resolve_target "$@"

  if [[ -f "${TARGET_DIR}/.runner" ]]; then
    echo "runner at ${TARGET_DIR} already configured."
    echo "use ./remove-runner.sh first if you want to re-register."
    exit 0
  fi

  if [[ ! -f "${RUNNER_HOME}/.bin/${RUNNER_TARBALL}" ]]; then
    echo "tarball missing. run ./init.sh first." >&2
    exit 1
  fi

  local token
  token=$(gh api -X POST "${TARGET_API_TOKEN_PATH}" --jq .token)

  mkdir -p "${TARGET_DIR}"
  tar -xzf "${RUNNER_HOME}/.bin/${RUNNER_TARBALL}" -C "${TARGET_DIR}"

  pushd "${TARGET_DIR}" >/dev/null
  ./config.sh --unattended \
    --url    "${TARGET_URL}" \
    --token  "${token}" \
    --labels gpu \
    --name   "${TARGET_NAME}" \
    --work   _work
  sudo ./svc.sh install "$(whoami)"
  sudo ./svc.sh start
  popd >/dev/null

  echo "registered: ${TARGET_NAME} at ${TARGET_DIR}"
}

main "$@"
