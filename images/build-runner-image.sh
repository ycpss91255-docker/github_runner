#!/usr/bin/env bash
# Build a self-built runner image whose actions/runner tarball passes the repo's
# SEC-5 supply-chain check BEFORE it is baked in (#120, ADR-0001 "Runner
# images"). This is the SINGLE place an image's runner tarball is obtained: it
# reuses lib/runner-release.sh (download + verify_runner_tarball) -- the exact
# gate init.sh uses -- so a tampered mirror / MITM can never reach the image.
# The Dockerfile itself never downloads; it only unpacks the verified tarball we
# hand it as the build context, keeping the build hermetic/reproducible.
#
# Usage:
#   images/build-runner-image.sh --tag <name:tag> [--dockerfile <path>] \
#       [--base-image <ref@sha256:...>] [--build-arg KEY=VALUE ...]
#
# RUNNER_VERSION (env) pins the runner version; unset = the resolved latest
# (resolve_runner_version). The base image is pinned by digest in the Dockerfile
# (override with --base-image). The tarball SHA-256 is verified STRICT here:
# gh must be authenticated (same prereq as init.sh), and any mismatch / missing
# digest aborts BEFORE docker build runs.
set -euo pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
# shellcheck source=SCRIPTDIR/../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

DEFAULT_DOCKERFILE="${SCRIPT_DIR}/runner-base.Dockerfile"

usage() {
  cat <<EOF
Usage:
  $(basename "$0") --tag <name:tag> [--dockerfile <path>] [--base-image <ref>] \\
      [--build-arg KEY=VALUE ...]

Builds a runner image, baking in an actions/runner tarball that is first
verified via the SEC-5 check (verify_runner_tarball, strict). Pin the version
with RUNNER_VERSION=<x.y.z>; the base image is digest-pinned in the Dockerfile.
EOF
}

main() {
  local tag="" dockerfile="${DEFAULT_DOCKERFILE}" base_image=""
  local -a extra_build_args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)       usage; exit 0 ;;
      --tag)           tag="$2"; shift 2 ;;
      --dockerfile)    dockerfile="$2"; shift 2 ;;
      --base-image)    base_image="$2"; shift 2 ;;
      --build-arg)     extra_build_args+=(--build-arg "$2"); shift 2 ;;
      *) echo "FAIL: unknown argument '$1'" >&2; usage >&2; exit 2 ;;
    esac
  done
  [[ -n ${tag} ]] || { echo "FAIL: --tag <name:tag> is required" >&2; usage >&2; exit 2; }

  local version tarball path
  version=$(resolve_runner_version)
  tarball=$(runner_release_tarball_name "${version}")
  path=$(runner_release_cache_path "${version}")

  # Obtain the tarball through the SAME path as init.sh: download into the cache
  # only when missing, then verify STRICT. A mismatch / missing digest aborts and
  # removes the file so a later run cannot silently trust an unverified copy --
  # docker build is never reached unless the bytes are SEC-5-verified.
  if [[ -f ${path} ]]; then
    echo "tarball cached: ${path}"
  else
    runner_release_download "${version}"
  fi
  verify_runner_tarball "${path}" "${version}" "${tarball}" strict \
    || { rm -f "${path}"; echo "FAIL: SEC-5 verification failed; not building ${tag}" >&2; exit 1; }

  # Stage a minimal, hermetic build context: ONLY the verified tarball. The
  # Dockerfile COPYs actions-runner.tar.gz from here and never downloads.
  local ctx
  ctx=$(mktemp -d)
  # shellcheck disable=SC2064  # expand ctx now for the trap
  trap "rm -rf '${ctx}'" EXIT
  cp "${path}" "${ctx}/actions-runner.tar.gz"

  local -a build_args=(--build-arg "RUNNER_VERSION=${version}")
  [[ -n ${base_image} ]] && build_args+=(--build-arg "BASE_IMAGE=${base_image}")
  build_args+=("${extra_build_args[@]}")

  echo "building ${tag} (runner ${version}, SEC-5 verified) ..."
  docker build \
    -f "${dockerfile}" \
    -t "${tag}" \
    "${build_args[@]}" \
    "${ctx}"
}

main "$@"
