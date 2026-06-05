#!/usr/bin/env bats
# Smoke tests for lib/runner-release.sh -- the release-tarball naming / cache /
# download primitives. (resolve_runner_version + the verify_* trio, which also
# live here now, keep their existing coverage in common.bats + tarball_verify.
# bats.) Pure lib, sourced via common.sh with RUNNER_HOME set.

setup() {
  LIB="${BATS_TEST_DIRNAME}/../../lib/common.sh"
  FAKE_RH=$(mktemp -d)
  export RUNNER_HOME="${FAKE_RH}"
  source "${LIB}"
}

teardown() { rm -rf "${FAKE_RH}"; }

@test "runner_release_tarball_name builds the canonical name" {
  [ "$(runner_release_tarball_name 2.334.0)" = "actions-runner-linux-x64-2.334.0.tar.gz" ]
}

@test "runner_release_cache_path lives under RUNNER_HOME/.bin" {
  [ "$(runner_release_cache_path 2.334.0)" = "${RUNNER_HOME}/.bin/actions-runner-linux-x64-2.334.0.tar.gz" ]
}

@test "runner_release_download_url targets the GitHub release asset" {
  [ "$(runner_release_download_url 2.334.0)" = \
    "https://github.com/actions/runner/releases/download/v2.334.0/actions-runner-linux-x64-2.334.0.tar.gz" ]
}

@test "runner_release_download curls the release url into the cache path" {
  local stub; stub=$(mktemp -d)
  cat >"${stub}/curl" <<EOF
#!/usr/bin/env bash
echo "\$*" > "${FAKE_RH}/curl.args"
out=""; prev=""
for a in "\$@"; do [ "\${prev}" = "-o" ] && out="\$a"; prev="\$a"; done
[ -n "\${out}" ] && : > "\${out}"
EOF
  chmod +x "${stub}/curl"
  PATH="${stub}:${PATH}" run runner_release_download 2.334.0
  [ "${status}" -eq 0 ]
  [ -f "${RUNNER_HOME}/.bin/actions-runner-linux-x64-2.334.0.tar.gz" ]
  grep -q 'releases/download/v2.334.0/actions-runner-linux-x64-2.334.0.tar.gz' "${FAKE_RH}/curl.args"
  rm -rf "${stub}"
}

@test "runner_release_cached_list is empty when nothing is cached" {
  [ -z "$(runner_release_cached_list)" ]
}

@test "runner_release_cached_list lists cached tarballs ascending by version" {
  mkdir -p "${RUNNER_HOME}/.bin"
  : > "${RUNNER_HOME}/.bin/actions-runner-linux-x64-2.334.0.tar.gz"
  : > "${RUNNER_HOME}/.bin/actions-runner-linux-x64-2.330.0.tar.gz"
  run runner_release_cached_list
  [ "${lines[0]}" = "${RUNNER_HOME}/.bin/actions-runner-linux-x64-2.330.0.tar.gz" ]
  [ "${lines[1]}" = "${RUNNER_HOME}/.bin/actions-runner-linux-x64-2.334.0.tar.gz" ]
}

@test "find_cached_tarball returns the highest cached version" {
  mkdir -p "${RUNNER_HOME}/.bin"
  : > "${RUNNER_HOME}/.bin/actions-runner-linux-x64-2.330.0.tar.gz"
  : > "${RUNNER_HOME}/.bin/actions-runner-linux-x64-2.334.0.tar.gz"
  [ "$(find_cached_tarball)" = "${RUNNER_HOME}/.bin/actions-runner-linux-x64-2.334.0.tar.gz" ]
}

@test "find_cached_tarball is empty when nothing is cached" {
  [ -z "$(find_cached_tarball)" ]
}
