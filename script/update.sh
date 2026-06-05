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

Each runner is upgraded independently: one runner's failure is reported and
does not abort the rest. Exit code is non-zero if any runner failed.
EOF
}

# Upgrade a single runner in place: stop -> re-seed binary -> start. Returns
# non-zero if extraction or restart failed. We always attempt the restart even
# when extraction failed, so a runner is never left silently stopped over a
# transient extract hiccup -- it comes back on its existing binary and is still
# reported as failed.
update_one_runner() {
  local dir=$1 tarball=$2 rc=0
  runner_service_stop "${dir}"
  tar -xzf "${tarball}" -C "${dir}" --skip-old-files || rc=1
  runner_service_start "${dir}" || rc=1
  return "${rc}"
}

main() {
  case "${1:-}" in -h|--help) usage; exit 0 ;; esac
  local version tarball_path
  version=$(resolve_runner_version)
  tarball_path=$(runner_release_cache_path "${version}")

  [[ -f ${tarball_path} ]] || runner_release_download "${version}"

  # H1: verify before extraction, whether THIS run downloaded the tarball or
  # hit the cache -- a cache hit must not skip the integrity check. Done once
  # per run here (not inside the download branch above). update.sh has no gh
  # prereq and resolve_runner_version can fall back offline, so verification is
  # best-effort (a missing digest warns + proceeds); a mismatch still aborts +
  # rm's the file. SEC-5.
  verify_runner_tarball "${tarball_path}" "${version}" "$(runner_release_tarball_name "${version}")" best-effort \
    || { rm -f "${tarball_path}"; exit 1; }

  # H1 (#49): upgrade each runner independently. A single runner's stop/extract/
  # start failure must not abort the loop (which would leave earlier runners
  # stopped and later ones untouched). Collect failures and report a summary,
  # mirroring cleanup.sh / uninstall.sh.
  local runner_dir updated=0 failed=0
  local -a fail_lines=()
  while IFS=$'\t' read -r _ _ _ runner_dir _; do
    echo "==> updating ${runner_dir} -> ${version}"
    if update_one_runner "${runner_dir}" "${tarball_path}"; then
      updated=$(( updated + 1 ))
    else
      echo "  FAILED: ${runner_dir}" >&2
      fail_lines+=("${runner_dir}")
      failed=$(( failed + 1 ))
    fi
  done < <(list_runners)

  echo
  if (( failed == 0 )); then
    echo "Summary: ${updated} updated, 0 failed."
    echo "update complete. next job each runner picks up will report ${version}."
    exit 0
  fi
  echo "Summary: ${updated} updated, ${failed} failed."
  printf '  %s\n' "${fail_lines[@]}"
  exit 1
}

if [[ "${BASH_SOURCE[0]:-}" == "${0}" ]]; then
  main "$@"
fi
