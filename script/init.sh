#!/usr/bin/env bash
# One-shot host bootstrap: verify prereqs, cache the runner tarball,
# and (optionally) register the first runner.
#
# Usage:
#   ./script/init.sh <org>     -- bootstrap + register first org-level runner
#   ./script/init.sh           -- bootstrap only (no runner registered)
#
# After init, register additional runners with:
#   ./script/add-runner.sh org <another-org>
#   ./script/add-runner.sh repo <owner> <repo>
set -euo pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
# shellcheck source=SCRIPTDIR/../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

usage() {
  cat <<EOF
Usage:
  $(basename "$0") <org>   # bootstrap host + register the first org-level runner
  $(basename "$0")         # bootstrap only (no runner registered)
EOF
}

check_prereqs() {
  # errors=$((errors+1)) (not ((errors++))): under set -e, post-increment
  # ((errors++)) evaluates to the OLD value, so the first failure (0) makes
  # the arithmetic command return status 1 and aborts the script -- only one
  # FAIL line would ever print. All diagnostics go to stderr.
  local errors=0
  command -v docker     >/dev/null || { echo "FAIL: docker not installed" >&2; errors=$((errors+1)); }
  command -v gh         >/dev/null || { echo "FAIL: gh CLI not installed" >&2; errors=$((errors+1)); }
  command -v curl       >/dev/null || { echo "FAIL: curl not installed" >&2; errors=$((errors+1)); }
  command -v jq         >/dev/null || { echo "FAIL: jq not installed" >&2; errors=$((errors+1)); }
  groups | grep -qw docker || { echo "FAIL: $(id -un) not in docker group" >&2; errors=$((errors+1)); }
  gh auth status >/dev/null 2>&1 || { echo "FAIL: gh not authenticated (run: gh auth login --scopes admin:org)" >&2; errors=$((errors+1)); }
  # #34: the GPU is optional. Auto-detect via nvidia-smi: when present, require
  # the docker GPU runtime to work (the original gate); when absent, skip both
  # GPU checks and proceed as a non-GPU host. HAS_GPU is consumed below to warn
  # about the default 'gpu' label.
  if command -v nvidia-smi >/dev/null; then
    HAS_GPU=1
    docker run --rm --gpus all nvidia/cuda:12.2.0-base-ubuntu22.04 nvidia-smi >/dev/null 2>&1 \
      || { echo "FAIL: docker --gpus all not working" >&2; errors=$((errors+1)); }
  else
    HAS_GPU=0
    echo "note: no NVIDIA GPU detected (nvidia-smi absent) -- proceeding as a non-GPU host" >&2
  fi
  ((errors == 0)) || { echo "prereq check failed (${errors})" >&2; exit 1; }
  echo "prereqs OK"
}

cache_tarball() {
  local version tarball path
  version=$(resolve_runner_version)
  tarball="actions-runner-linux-x64-${version}.tar.gz"
  path="${RUNNER_HOME}/.bin/${tarball}"
  if [[ -f ${path} ]]; then
    echo "tarball cached: ${path}"
    return
  fi
  mkdir -p "${RUNNER_HOME}/.bin"
  echo "downloading ${tarball}..."
  curl -fL -o "${path}" \
    "https://github.com/actions/runner/releases/download/v${version}/${tarball}"
  # SEC-5: verify the freshly-downloaded tarball. gh is an init prereq, so
  # verification is strict here (a missing digest aborts); rm the file on any
  # failure so a later run can't silently trust an unverified cached copy.
  verify_runner_tarball "${path}" "${version}" "${tarball}" strict \
    || { rm -f "${path}"; exit 1; }
}

main() {
  # U2: intercept --help before $1 is treated as an org name (otherwise
  # `init.sh --help` would try to register a runner for org "--help").
  case "${1:-}" in -h|--help) usage; exit 0 ;; esac

  HAS_GPU=0   # set by check_prereqs; default keeps set -u happy
  check_prereqs
  cache_tarball

  # #34: on a non-GPU host the default 'gpu' registration label is wrong; the
  # label is the routing key for runs-on, so flag it (we don't guess a label).
  if (( ! HAS_GPU )); then
    echo "note: runners default to the 'gpu' label. For this non-GPU host, set labels first:" >&2
    echo "      ./script/configure.sh --labels <label>   (then re-run add-runner)" >&2
  fi

  if [[ $# -gt 0 ]]; then
    echo "==> bootstrapping first runner for org: $1"
    "${SCRIPT_DIR}/add-runner.sh" org "$1"
  else
    echo "init complete. Next: ./script/add-runner.sh org <org-name>"
  fi
}

if [[ "${BASH_SOURCE[0]:-}" == "${0}" ]]; then
  main "$@"
fi
