#!/usr/bin/env bash
# Upgrade runner binary across all registered runners. Preserves config.
# Usage:
#   RUNNER_VERSION=2.320.0 ./update.sh
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(dirname "$(readlink -f "$0")")/lib/common.sh"

main() {
  local new_tarball_path="${RUNNER_HOME}/.bin/${RUNNER_TARBALL}"
  if [[ ! -f ${new_tarball_path} ]]; then
    echo "downloading ${RUNNER_TARBALL}..."
    mkdir -p "${RUNNER_HOME}/.bin"
    curl -fL -o "${new_tarball_path}" \
      "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/${RUNNER_TARBALL}"
  fi

  shopt -s nullglob
  local runner_dir
  for runner_dir in "${RUNNER_HOME}"/*/*/; do
    [[ -f "${runner_dir}/.runner" ]] || continue
    echo "==> updating ${runner_dir}"
    pushd "${runner_dir}" >/dev/null
    sudo ./svc.sh stop || true
    tar -xzf "${new_tarball_path}" --skip-old-files
    sudo ./svc.sh start
    popd >/dev/null
  done
  echo "update complete. next job each runner picks up will report new version."
}

main "$@"
