#!/usr/bin/env bash
# One-shot host bootstrap: verify prereqs and cache the runner tarball.
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(dirname "$(readlink -f "$0")")/lib/common.sh"

check_prereqs() {
  local errors=0
  command -v docker     >/dev/null || { echo "FAIL: docker not installed"; ((errors++)); }
  command -v nvidia-smi >/dev/null || { echo "FAIL: nvidia-smi not found"; ((errors++)); }
  command -v gh         >/dev/null || { echo "FAIL: gh CLI not installed"; ((errors++)); }
  command -v curl       >/dev/null || { echo "FAIL: curl not installed"; ((errors++)); }
  command -v jq         >/dev/null || { echo "FAIL: jq not installed"; ((errors++)); }
  groups | grep -qw docker || { echo "FAIL: ${USER} not in docker group"; ((errors++)); }
  gh auth status >/dev/null 2>&1 || { echo "FAIL: gh not authenticated (run: gh auth login --scopes admin:org)"; ((errors++)); }
  docker run --rm --gpus all nvidia/cuda:12.2.0-base-ubuntu22.04 nvidia-smi >/dev/null 2>&1 \
    || { echo "FAIL: docker --gpus all not working"; ((errors++)); }
  ((errors == 0)) || { echo "prereq check failed (${errors})"; exit 1; }
  echo "prereqs OK"
}

cache_tarball() {
  local path="${RUNNER_HOME}/.bin/${RUNNER_TARBALL}"
  if [[ -f ${path} ]]; then
    echo "tarball cached: ${path}"
    return
  fi
  mkdir -p "${RUNNER_HOME}/.bin"
  echo "downloading ${RUNNER_TARBALL}..."
  curl -fL -o "${path}" \
    "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/${RUNNER_TARBALL}"
}

check_prereqs
cache_tarball
echo "init complete. Next: ./add-runner.sh org <org-name>"
