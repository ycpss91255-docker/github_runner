#!/usr/bin/env bash
# Register a new self-hosted runner (org or repo level). Idempotent.
# Usage:
#   ./scripts/add-runner.sh org <org>
#   ./scripts/add-runner.sh repo <owner> <repo>
set -euo pipefail

# shellcheck source=SCRIPTDIR/../lib/common.sh
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

main() {
  resolve_target "$@"

  if [[ -f "${TARGET_DIR}/.runner" ]]; then
    echo "runner at ${TARGET_DIR} already configured."
    echo "use ./scripts/remove-runner.sh first if you want to re-register."
    exit 0
  fi

  local tarball_path
  tarball_path=$(find_cached_tarball)
  if [[ -z ${tarball_path} ]]; then
    echo "tarball missing. run ./scripts/init.sh first." >&2
    exit 1
  fi

  local token
  token=$(gh api -X POST "${TARGET_API_TOKEN_PATH}" --jq .token)

  mkdir -p "${TARGET_DIR}"
  tar -xzf "${tarball_path}" -C "${TARGET_DIR}"

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

  # Unstick public-repo workflow dispatch (see lib/common.sh comment + #6).
  # Only meaningful for org-scoped runners; repo-scoped runners do not have
  # a runner-group flag.
  if [[ ${1:-} == "org" ]]; then
    enable_public_repos_dispatch "$2"
  fi

  echo "registered: ${TARGET_NAME} at ${TARGET_DIR}"
}

main "$@"
