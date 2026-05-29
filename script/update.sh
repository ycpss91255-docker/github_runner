#!/usr/bin/env bash
# Upgrade runner binary across all registered runners. Preserves config.
# Usage:
#   ./script/update.sh                      # resolves and pulls latest released
#   RUNNER_VERSION=2.334.0 ./script/update.sh  # pin a specific version
set -euo pipefail

# shellcheck source=SCRIPTDIR/../lib/common.sh
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

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

main "$@"
