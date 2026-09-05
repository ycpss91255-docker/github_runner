#!/usr/bin/env bash
# Fetch bats -- the single source of truth for the bats-core release that the
# kcov coverage container runs: which version, where it is cached, where it is
# downloaded from, and how its integrity is checked. Deliberately the same shape
# as lib/runner-release.sh, which owns exactly those four facts for the
# actions/runner tarball.
#
# Why this exists: the `coverage` recipe used to `apt-get install bats` inside
# the container on every run. That made the coverage signal depend on the Debian
# archive being reachable (it is not, on a restricted network) and on whatever
# bats version the archive carried that day. A check that cannot be reproduced
# locally cannot gate a merge, so the version is pinned here, verified against a
# pinned sha256, and cached on the host; the recipe mounts the cache read-only
# into a container run with --network none.
#
# bats-core is pure bash and runs straight from an unpacked release -- there is
# no build and no install step -- which is what makes caching a release tarball
# the cheapest way to pin it. The repo publishes no image of its own (it only
# consumes ghcr.io/ycpss91255-docker/test-tools), so baking kcov + bats into an
# image was not an option available here.
#
# Usage:
#   script/fetch-bats.sh          # prints the cache dir; downloads only if absent
#
# stdout is exactly the cache directory, so callers can do:
#   bats_dir="$(bash script/fetch-bats.sh)"
# Everything else goes to stderr.
#
# Environment:
#   BATS_CACHE_DIR   cache root (default: ${XDG_CACHE_HOME:-$HOME/.cache}/github_runner)

# The pin. Bump these two together, deliberately: change the version, then
# record the sha256 of the new tarball. Currently the same bats-core release the
# test-tools image ships, so `just test` and `just coverage` run the same bats.
readonly BATS_VERSION="1.13.0"
readonly BATS_SHA256="a85e12b8828271a152b338ca8109aa23493b57950987c8e6dff97ba492772ff3"

FETCH_BATS_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"

# verify_sha256 is the repo's existing integrity primitive (SEC-5). Reused, not
# re-implemented: an integrity check that exists in two copies is one bug fix
# away from disagreeing with itself.
# shellcheck source=lib/runner-release.sh
source "${FETCH_BATS_DIR}/../lib/runner-release.sh"

# The cache root / tarball name / download URL / install dir for a version --
# the one place each convention lives.
bats_cache_root()    { printf '%s\n' "${BATS_CACHE_DIR:-${XDG_CACHE_HOME:-${HOME}/.cache}/github_runner}"; }
bats_tarball_name()  { printf '%s\n' "bats-core-$1.tar.gz"; }
bats_install_dir()   { printf '%s\n' "$(bats_cache_root)/bats-core-$1"; }
bats_download_url() {
  printf '%s\n' "https://github.com/bats-core/bats-core/archive/refs/tags/v$1.tar.gz"
}

# Print the cache dir for the pinned release, downloading and verifying it first
# if it is not there yet. A present cache is used as-is and reaches no network.
#
# The download lands in a scratch dir and is moved into place only after the
# sha256 matches, so an interrupted or tampered fetch never leaves a directory
# that a later run would mistake for a good cache.
fetch_bats() {
  local dir tarball url root tmp
  dir=$(bats_install_dir "${BATS_VERSION}")
  if [[ -x "${dir}/bin/bats" ]]; then
    printf '%s\n' "${dir}"
    return 0
  fi

  root=$(bats_cache_root)
  tarball=$(bats_tarball_name "${BATS_VERSION}")
  url=$(bats_download_url "${BATS_VERSION}")
  mkdir -p "${root}"
  tmp=$(mktemp -d "${root}/.fetch-bats.XXXXXX")
  # shellcheck disable=SC2064  # expand tmp now: the trap must outlive the local
  trap "rm -rf '${tmp}'" RETURN

  echo "downloading ${tarball}..." >&2
  curl -fL -o "${tmp}/${tarball}" "${url}" >&2 || {
    echo "FAIL: could not download ${url}" >&2
    return 1
  }
  if ! verify_sha256 "${tmp}/${tarball}" "${BATS_SHA256}"; then
    echo "FAIL: sha256 mismatch for ${tarball} (expected ${BATS_SHA256})" >&2
    return 1
  fi
  echo "verified ${tarball} (sha256 ok)" >&2

  tar -xzf "${tmp}/${tarball}" -C "${tmp}"
  [[ -x "${tmp}/bats-core-${BATS_VERSION}/bin/bats" ]] || {
    echo "FAIL: ${tarball} did not unpack to bats-core-${BATS_VERSION}/bin/bats" >&2
    return 1
  }
  mv "${tmp}/bats-core-${BATS_VERSION}" "${dir}"
  echo "cached bats ${BATS_VERSION} at ${dir}" >&2
  printf '%s\n' "${dir}"
}

# Sourcing this file must be free of side effects: the smoke tests source it to
# read the pin and exercise the path helpers, and inheriting `set -euo pipefail`
# would change the caller's shell, not just this script's.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -euo pipefail
  fetch_bats
fi
