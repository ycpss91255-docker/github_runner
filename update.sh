#!/usr/bin/env bash
# Upgrade runner binary across all registered runners. Preserves config.
# Usage:
#   ./update.sh                      # resolves and pulls latest released
#   RUNNER_VERSION=2.334.0 ./update.sh  # pin a specific version
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(dirname "$(readlink -f "$0")")/lib/common.sh"

main() {
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

  shopt -s nullglob
  local runner_dir
  for runner_dir in "${RUNNER_HOME}"/*/*/; do
    [[ -f "${runner_dir}/.runner" ]] || continue
    echo "==> updating ${runner_dir} -> ${version}"
    pushd "${runner_dir}" >/dev/null
    sudo ./svc.sh stop || true
    tar -xzf "${tarball_path}" --skip-old-files
    sudo ./svc.sh start
    popd >/dev/null
  done
  echo "update complete. next job each runner picks up will report ${version}."
}

main "$@"
