#!/usr/bin/env bats
# Executable spec for script/fetch-bats.sh -- the pinned, checksum-verified
# bats-core release that `just coverage` runs inside the kcov container.
#
# Why this exists: the coverage recipe used to `apt-get install bats` inside the
# container on every run. That made a merge-relevant check depend on the Debian
# archive being reachable (it is not, on a restricted network) and on whatever
# bats version the archive happened to carry that day. This script is the single
# source of truth for which bats-core release is used, where it is cached, where
# it is downloaded from and how its integrity is checked -- the same shape as
# lib/runner-release.sh for the actions/runner tarball.
#
# No test here reaches the network: curl is stubbed, and the cache-hit path must
# not invoke it at all (that is the offline guarantee, asserted rather than
# assumed).

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  FETCH="${ROOT}/script/fetch-bats.sh"
  export BATS_CACHE_DIR="${BATS_TEST_TMPDIR}/cache"
  STUB="${BATS_TEST_TMPDIR}/stub"
  mkdir -p "${STUB}"
}

# curl stub that records it ran and then fails, so any test using it proves the
# script did NOT need the network (if it did, the run fails loudly).
stub_curl_forbidden() {
  cat >"${STUB}/curl" <<EOF
#!/usr/bin/env bash
echo "curl ran: \$*" > "${BATS_TEST_TMPDIR}/curl.args"
exit 1
EOF
  chmod +x "${STUB}/curl"
}

# curl stub that "downloads" a payload the pinned sha256 will not match.
stub_curl_tampered() {
  cat >"${STUB}/curl" <<EOF
#!/usr/bin/env bash
out=""; prev=""
for a in "\$@"; do [ "\${prev}" = "-o" ] && out="\$a"; prev="\$a"; done
printf 'not the real bats-core tarball\n' > "\${out}"
EOF
  chmod +x "${STUB}/curl"
}

@test "the bats-core version and its sha256 are pinned in exactly one place" {
  run grep -cE '^readonly BATS_VERSION=' "${FETCH}"
  [ "${status}" -eq 0 ]
  [ "${output}" = "1" ]
  run grep -cE '^readonly BATS_SHA256=' "${FETCH}"
  [ "${status}" -eq 0 ]
  [ "${output}" = "1" ]
}

@test "bats_download_url targets the pinned bats-core release tag" {
  source "${FETCH}"
  [ "$(bats_download_url "${BATS_VERSION}")" = \
    "https://github.com/bats-core/bats-core/archive/refs/tags/v${BATS_VERSION}.tar.gz" ]
}

@test "bats_install_dir names the pinned version under the cache root" {
  source "${FETCH}"
  [ "$(bats_install_dir "${BATS_VERSION}")" = \
    "${BATS_CACHE_DIR}/bats-core-${BATS_VERSION}" ]
}

@test "the cache root defaults under XDG_CACHE_HOME when BATS_CACHE_DIR is unset" {
  unset BATS_CACHE_DIR
  export XDG_CACHE_HOME="${BATS_TEST_TMPDIR}/xdg"
  source "${FETCH}"
  [ "$(bats_cache_root)" = "${XDG_CACHE_HOME}/github_runner" ]
}

@test "a cached release is reused: the path is printed and nothing is downloaded" {
  stub_curl_forbidden
  source "${FETCH}"
  local dir="${BATS_CACHE_DIR}/bats-core-${BATS_VERSION}"
  mkdir -p "${dir}/bin"
  printf '#!/bin/sh\n' > "${dir}/bin/bats"
  chmod +x "${dir}/bin/bats"

  PATH="${STUB}:${PATH}" run bash "${FETCH}"
  [ "${status}" -eq 0 ]
  [ "${output}" = "${dir}" ]
  [ ! -f "${BATS_TEST_TMPDIR}/curl.args" ]
}

@test "a tarball that does not match the pinned sha256 aborts and caches nothing" {
  stub_curl_tampered
  source "${FETCH}"
  local dir="${BATS_CACHE_DIR}/bats-core-${BATS_VERSION}"

  PATH="${STUB}:${PATH}" run bash "${FETCH}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *sha256* ]]
  [ ! -d "${dir}" ]
}
