#!/usr/bin/env bash
# Runner Release -- the single source of truth for the actions/runner release
# tarball: which version, what it is named, where it is cached, where it is
# downloaded from, and how its integrity is checked. Before this module the
# name (actions-runner-linux-x64-<version>.tar.gz) was rebuilt in 4 places
# (init, update, cleanup, find_cached_tarball) and the download URL in 2
# (init, update), so a naming/endpoint change touched each independently.
#
# Sourced by lib/common.sh after RUNNER_HOME (cache paths) and alongside the
# _gh seam (resolve_runner_version / runner_asset_digest reach GitHub through
# it). Verify policy stays with the caller: init verifies strict only on a
# fresh download; update verifies best-effort on every run (H1) -- those are
# different policies, not duplication, so the module provides primitives, not a
# one-size ensure-cached.
# shellcheck shell=bash

# Static fallback used when dynamic resolution fails (offline, gh missing /
# unauthenticated, GitHub rate-limited). Bump opportunistically when fresh
# installs in those degraded states should not start months behind. GitHub
# self-hosted runners always self-update on connect, so this is only the
# bootstrap version, not the runtime one. Refs #10.
readonly RUNNER_VERSION_FALLBACK="2.334.0"

# Resolve the actions/runner version to download:
#   1. If $RUNNER_VERSION is set, honour it verbatim (caller knows best).
#   2. Otherwise ask GitHub for the latest released tag.
#   3. If gh is missing / unauthenticated / network-unreachable / the
#      response is empty for any other reason, fall back to
#      $RUNNER_VERSION_FALLBACK.
#
# Output: bare version string (no leading 'v'), e.g. "2.334.0".
resolve_runner_version() {
  if [[ -n "${RUNNER_VERSION:-}" ]]; then
    echo "${RUNNER_VERSION}"
    return
  fi
  if ! command -v gh >/dev/null 2>&1; then
    echo "${RUNNER_VERSION_FALLBACK}"
    return
  fi
  local resolved
  resolved=$(_gh api /repos/actions/runner/releases/latest --jq .tag_name 2>/dev/null \
             | sed 's/^v//' || true)
  if [[ -z ${resolved} ]]; then
    echo "${RUNNER_VERSION_FALLBACK}"
    return
  fi
  echo "${resolved}"
}

# The release tarball name / cache path / download URL for a version -- the one
# place each convention lives.
runner_release_tarball_name() { printf '%s\n' "actions-runner-linux-x64-$1.tar.gz"; }
runner_release_cache_path()   { printf '%s\n' "${RUNNER_HOME}/.bin/$(runner_release_tarball_name "$1")"; }
runner_release_download_url() {
  printf '%s\n' "https://github.com/actions/runner/releases/download/v$1/$(runner_release_tarball_name "$1")"
}

# Download a version's tarball into the cache (creating .bin/ if needed). Curl
# fails the script (-f) on a non-2xx response; the caller verifies + rm's.
runner_release_download() {
  local version=$1 tarball path url
  tarball=$(runner_release_tarball_name "${version}")
  path=$(runner_release_cache_path "${version}")
  url=$(runner_release_download_url "${version}")
  mkdir -p "${RUNNER_HOME}/.bin"
  echo "downloading ${tarball}..."
  curl -fL -o "${path}" "${url}"
}

# Every cached tarball under ${RUNNER_HOME}/.bin/, ascending by version (the
# single owner of the cache glob). Empty output when none are cached.
runner_release_cached_list() {
  shopt -s nullglob
  local candidates=("${RUNNER_HOME}/.bin/"actions-runner-linux-x64-*.tar.gz)
  shopt -u nullglob
  (( ${#candidates[@]} )) || return 0
  printf '%s\n' "${candidates[@]}" | sort -V
}

# The highest-version cached tarball, or empty if none. Multiple may coexist
# (e.g. after an update.sh bump that kept the prior one); add-runner.sh uses
# the highest so newly-registered runners do not start behind.
find_cached_tarball() { runner_release_cached_list | tail -1; }

# --- Tarball integrity (SEC-5) ------------------------------------------
# Supply-chain check at the DOWNLOAD point only: confirm a freshly-downloaded
# actions/runner tarball matches the SHA-256 GitHub publishes for that release
# asset. Orthogonal to the runner-user's docker-group privilege (which is
# accepted, see README security model) -- this defends the download against a
# tampered mirror / MITM, nothing else.

# Compare a file's SHA-256 to an expected hex digest. 0 = match, 1 = not.
# sha256sum is present on both alpine (busybox) and Ubuntu (coreutils).
verify_sha256() {
  local file=$1 expected=$2 actual
  actual=$(sha256sum "${file}" 2>/dev/null | cut -d' ' -f1) || return 1
  [[ -n ${expected} && ${actual} == "${expected}" ]]
}

# Print the expected SHA-256 (bare hex) for a release asset, or nothing when
# it cannot be obtained (gh missing / unauthenticated / offline, or the asset
# predates GitHub's per-asset digest field). Reaches GitHub via _gh so it is
# shadowable in tests.
runner_asset_digest() {
  local version=$1 tarball=$2 d
  d=$(_gh api "repos/actions/runner/releases/tags/v${version}" \
        --jq ".assets[] | select(.name==\"${tarball}\") | .digest // empty" \
        2>/dev/null) || return 0
  printf '%s' "${d#sha256:}"
}

# Verify a downloaded tarball against its published digest.
#   verify_runner_tarball <file> <version> <tarball_name> <strict|best-effort>
# Returns 0 to proceed, 1 for the caller to abort (and rm the file). A SHA
# mismatch always returns 1. When the expected digest cannot be obtained:
# strict (init, where gh is a prereq) returns 1; best-effort (update's
# degraded path) warns and returns 0.
verify_runner_tarball() {
  local file=$1 version=$2 tarball=$3 mode=$4 expected
  expected=$(runner_asset_digest "${version}" "${tarball}")
  if [[ -z ${expected} ]]; then
    if [[ ${mode} == strict ]]; then
      echo "FAIL: could not obtain the expected sha256 for ${tarball} from GitHub" >&2
      return 1
    fi
    echo "WARN: no sha256 digest available for ${tarball}; skipping integrity check" >&2
    return 0
  fi
  if verify_sha256 "${file}" "${expected}"; then
    echo "verified ${tarball} (sha256 ok)"
    return 0
  fi
  echo "FAIL: sha256 mismatch for ${tarball} (expected ${expected})" >&2
  return 1
}
