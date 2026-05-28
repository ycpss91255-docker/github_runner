#!/usr/bin/env bats
# Smoke tests for lib/common.sh resolve_target dispatcher.

setup() {
  LIB="${BATS_TEST_DIRNAME}/../../lib/common.sh"
}

@test "resolve_target org sets org-scoped variables" {
  # shellcheck disable=SC1090
  source "${LIB}"
  resolve_target org myorg
  [ "${TARGET_URL}" = "https://github.com/myorg" ]
  [ "${TARGET_DIR}" = "${HOME}/github_runner/myorg/_org" ]
  [ "${TARGET_API_TOKEN_PATH}" = "/orgs/myorg/actions/runners/registration-token" ]
  [ "${TARGET_API_REMOVE_PATH}" = "/orgs/myorg/actions/runners/remove-token" ]
  [[ "${TARGET_NAME}" == *"-myorg-org" ]]
}

@test "resolve_target repo sets repo-scoped variables" {
  # shellcheck disable=SC1090
  source "${LIB}"
  resolve_target repo owner myrepo
  [ "${TARGET_URL}" = "https://github.com/owner/myrepo" ]
  [ "${TARGET_DIR}" = "${HOME}/github_runner/owner/myrepo" ]
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
