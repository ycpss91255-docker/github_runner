#!/usr/bin/env bash
# Register a new self-hosted runner (org or repo level). Idempotent.
# Usage:
#   ./script/add-runner.sh org <org>
#   ./script/add-runner.sh repo <owner> <repo>
set -euo pipefail

# shellcheck source=SCRIPTDIR/../lib/common.sh
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

main() {
  resolve_target "$@"

  if [[ -f "${TARGET_DIR}/.runner" ]]; then
    echo "runner at ${TARGET_DIR} already configured."
    echo "use ./script/remove-runner.sh first if you want to re-register."
    exit 0
  fi

  local tarball_path
  tarball_path=$(find_cached_tarball)
  if [[ -z ${tarball_path} ]]; then
    echo "tarball missing. run ./script/init.sh first." >&2
    exit 1
  fi

  # Resolve registration labels from setup.conf (default gpu when absent).
  load_config

  local token
  token=$(gh api -X POST "${TARGET_API_TOKEN_PATH}" --jq .token)

  mkdir -p "${TARGET_DIR}"
  tar -xzf "${tarball_path}" -C "${TARGET_DIR}"

  pushd "${TARGET_DIR}" >/dev/null
  ./config.sh --unattended \
    --url    "${TARGET_URL}" \
    --token  "${token}" \
    --labels "${LABELS}" \
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
