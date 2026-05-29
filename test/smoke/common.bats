#!/usr/bin/env bats
# Smoke tests for lib/common.sh resolve_target dispatcher.

setup() {
  LIB="${BATS_TEST_DIRNAME}/../../lib/common.sh"
  # Pin RUNNER_HOME so TARGET_DIR is predictable regardless of where the
  # repo is checked out (default is <repo_root>/runners/).
  export RUNNER_HOME="/tmp/gh-runner-test-home"
}

@test "resolve_target org sets org-scoped variables" {
  # shellcheck disable=SC1090
  source "${LIB}"
  resolve_target org myorg
  [ "${TARGET_URL}" = "https://github.com/myorg" ]
  [ "${TARGET_DIR}" = "${RUNNER_HOME}/myorg/_org" ]
  [ "${TARGET_API_TOKEN_PATH}" = "/orgs/myorg/actions/runners/registration-token" ]
  [ "${TARGET_API_REMOVE_PATH}" = "/orgs/myorg/actions/runners/remove-token" ]
  [[ "${TARGET_NAME}" == *"-myorg-org" ]]
}

@test "resolve_target repo sets repo-scoped variables" {
  # shellcheck disable=SC1090
  source "${LIB}"
  resolve_target repo owner myrepo
  [ "${TARGET_URL}" = "https://github.com/owner/myrepo" ]
  [ "${TARGET_DIR}" = "${RUNNER_HOME}/owner/myrepo" ]
  [ "${TARGET_API_TOKEN_PATH}" = "/repos/owner/myrepo/actions/runners/registration-token" ]
  [ "${TARGET_API_REMOVE_PATH}" = "/repos/owner/myrepo/actions/runners/remove-token" ]
  [[ "${TARGET_NAME}" == *"-owner-myrepo" ]]
}

@test "resolve_target with no args exits non-zero" {
  run bash -c "source '${LIB}'; resolve_target"
  [ "${status}" -ne 0 ]
}

@test "resolve_target with unknown scope exits non-zero" {
  run bash -c "source '${LIB}'; resolve_target invalid foo"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"usage"* ]]
}

@test "resolve_target org without org arg exits non-zero" {
  run bash -c "source '${LIB}'; resolve_target org"
  [ "${status}" -ne 0 ]
}

@test "resolve_target repo with only one positional arg exits non-zero" {
  run bash -c "source '${LIB}'; resolve_target repo owner"
  [ "${status}" -ne 0 ]
}

@test "resolve_runner_version honours RUNNER_VERSION env override verbatim" {
  # shellcheck disable=SC1090
  source "${LIB}"
  RUNNER_VERSION=9.9.9 run resolve_runner_version
  [ "${status}" -eq 0 ]
  [ "${output}" = "9.9.9" ]
}

@test "resolve_runner_version falls back when gh is missing from PATH" {
  # PATH without gh -> resolve_runner_version short-circuits to fallback.
  # /bin:/usr/bin keeps bash + coreutils reachable on both alpine + ubuntu.
  run env -i HOME="${HOME}" PATH=/bin:/usr/bin RUNNER_VERSION= bash -c \
    "source '${LIB}'; resolve_runner_version"
  [ "${status}" -eq 0 ]
  # We don't pin the exact fallback value here (it bumps over time), only
  # that *something* was emitted and it looks like a semver version.
  [[ "${output}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

@test "find_cached_tarball returns empty when .bin/ does not exist" {
  TMP=$(mktemp -d)
  RUNNER_HOME="${TMP}" run bash -c "source '${LIB}'; find_cached_tarball"
  rm -rf "${TMP}"
  [ "${status}" -eq 0 ]
  [ -z "${output}" ]
}

@test "find_cached_tarball returns highest-version tarball when multiple are cached" {
  TMP=$(mktemp -d)
  mkdir -p "${TMP}/.bin"
  touch "${TMP}/.bin/actions-runner-linux-x64-2.319.1.tar.gz"
  touch "${TMP}/.bin/actions-runner-linux-x64-2.334.0.tar.gz"
  touch "${TMP}/.bin/actions-runner-linux-x64-2.320.0.tar.gz"

  RUNNER_HOME="${TMP}" run bash -c "source '${LIB}'; find_cached_tarball"
  rm -rf "${TMP}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"2.334.0.tar.gz" ]]
}
