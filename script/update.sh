#!/usr/bin/env bash
# Re-seed the runner binary across all registered runners. Preserves config.
# Usage:
#   ./script/update.sh                      # resolves and pulls latest released
#   RUNNER_VERSION=2.334.0 ./script/update.sh  # pin a specific version
#
# Idempotency / scope (B2): GitHub's actions/runner self-updates at connect
# time, so this mainly re-seeds a freshly-registered or reset runner.
# Extraction uses `tar --skip-old-files` (GNU tar; not busybox-portable, hence
# excluded from the alpine smoke suite), so a second run over an already-
# populated tree is a NO-OP rather than a forced overwrite.
set -euo pipefail

# shellcheck source=SCRIPTDIR/../lib/common.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/common.sh"

usage() {
  cat <<EOF
Usage:
  $(basename "$0")                          # resolve + pull the latest release
  RUNNER_VERSION=<x.y.z> $(basename "$0")   # pin a specific version

Upgrade the runner binary across all registered runners; preserves config.
EOF
}

main() {
  case "${1:-}" in -h|--help) usage; exit 0 ;; esac
  local version tarball tarball_path
  version=$(resolve_runner_version)
  tarball="actions-runner-linux-x64-${version}.tar.gz"
  tarball_path="${RUNNER_HOME}/.bin/${tarball}"

  if [[ ! -f ${tarball_path} ]]; then
    echo "downloading ${tarball}..."
    mkdir -p "${RUNNER_HOME}/.bin"
    curl -fL -o "${tarball_path}" \
      "https://github.com/actions/runner/releases/download/v${version}/${tarball}"
  fi

  # H1: verify before extraction, whether THIS run downloaded the tarball or
  # hit the cache -- a cache hit must not skip the integrity check. Done once
  # per run here (not inside the download branch above). update.sh has no gh
  # prereq and resolve_runner_version can fall back offline, so verification is
  # best-effort (a missing digest warns + proceeds); a mismatch still aborts +
  # rm's the file. SEC-5.
  verify_runner_tarball "${tarball_path}" "${version}" "${tarball}" best-effort \
    || { rm -f "${tarball_path}"; exit 1; }

  local runner_dir
  while IFS=$'\t' read -r _ _ _ runner_dir _; do
    echo "==> updating ${runner_dir} -> ${version}"
    pushd "${runner_dir}" >/dev/null
    sudo ./svc.sh stop || true
    tar -xzf "${tarball_path}" --skip-old-files
    sudo ./svc.sh start
    popd >/dev/null
  done < <(list_runners)
  echo "update complete. next job each runner picks up will report ${version}."
}

if [[ "${BASH_SOURCE[0]:-}" == "${0}" ]]; then
  main "$@"
fi
