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

# list_runners: enumerate every configured runner under RUNNER_HOME as one
# TAB-separated row per runner:
#   scope \t org \t scope_id \t name \t runner_dir
# scope is "org" or "repo"; scope_id is empty for org-scoped and the repo
# name for repo-scoped. See lib/common.sh for the full contract.

@test "list_runners returns nothing when RUNNER_HOME does not exist" {
  TMP=$(mktemp -d)
  rmdir "${TMP}"  # Guarantee the dir is absent.
  RUNNER_HOME="${TMP}" run bash -c "source '${LIB}'; list_runners"
  [ "${status}" -eq 0 ]
  [ -z "${output}" ]
}

@test "list_runners returns nothing when RUNNER_HOME exists but is empty" {
  TMP=$(mktemp -d)
  RUNNER_HOME="${TMP}" run bash -c "source '${LIB}'; list_runners"
  rm -rf "${TMP}"
  [ "${status}" -eq 0 ]
  [ -z "${output}" ]
}

@test "list_runners emits one org-scoped row for a configured org runner" {
  TMP=$(mktemp -d)
  mkdir -p "${TMP}/myorg/_org"
  printf '{"agentName":"runner-A"}\n' > "${TMP}/myorg/_org/.runner"

  RUNNER_HOME="${TMP}" run bash -c "source '${LIB}'; list_runners"
  rm -rf "${TMP}"
  [ "${status}" -eq 0 ]
  # org rows have 4 fields; scope_id (5th) is absent.
  IFS=$'\t' read -r scope org name dir scope_id <<<"${output}"
  [ "${scope}" = "org" ]
  [ "${org}" = "myorg" ]
  [ "${name}" = "runner-A" ]
  [[ "${dir}" == */myorg/_org ]]
  [ -z "${scope_id}" ]
}

@test "list_runners silently skips runner_dirs without a .runner marker" {
  TMP=$(mktemp -d)
  # Half-configured: bin/ and externals/ exist, but config.sh never wrote
  # .runner. Every existing caller treats this as "not registered".
  mkdir -p "${TMP}/myorg/_org/bin.2.334.0" "${TMP}/myorg/_org/externals.2.334.0"

  RUNNER_HOME="${TMP}" run bash -c "source '${LIB}'; list_runners"
  rm -rf "${TMP}"
  [ "${status}" -eq 0 ]
  [ -z "${output}" ]
}

@test "list_runners emits a repo-scoped row with scope_id = repo name" {
  TMP=$(mktemp -d)
  mkdir -p "${TMP}/owner-a/repo-x"
  printf '{"agentName":"runner-B"}\n' > "${TMP}/owner-a/repo-x/.runner"

  RUNNER_HOME="${TMP}" run bash -c "source '${LIB}'; list_runners"
  rm -rf "${TMP}"
  [ "${status}" -eq 0 ]
  IFS=$'\t' read -r scope org name dir scope_id <<<"${output}"
  [ "${scope}" = "repo" ]
  [ "${org}" = "owner-a" ]
  [ "${name}" = "runner-B" ]
  [[ "${dir}" == */owner-a/repo-x ]]
  [ "${scope_id}" = "repo-x" ]
}

@test "list_runners skips the top-level .bin tarball cache dir" {
  TMP=$(mktemp -d)
  mkdir -p "${TMP}/.bin"
  touch "${TMP}/.bin/actions-runner-linux-x64-2.334.0.tar.gz"

  RUNNER_HOME="${TMP}" run bash -c "source '${LIB}'; list_runners"
  rm -rf "${TMP}"
  [ "${status}" -eq 0 ]
  [ -z "${output}" ]
}

@test "list_runners walks multiple orgs and emits one row per registered runner" {
  TMP=$(mktemp -d)
  mkdir -p "${TMP}/org-a/_org" "${TMP}/org-b/_org" "${TMP}/.bin"
  printf '{"agentName":"r1"}\n' > "${TMP}/org-a/_org/.runner"
  printf '{"agentName":"r2"}\n' > "${TMP}/org-b/_org/.runner"
  touch "${TMP}/.bin/actions-runner-linux-x64-2.334.0.tar.gz"

  RUNNER_HOME="${TMP}" run bash -c "source '${LIB}'; list_runners"
  rm -rf "${TMP}"
  [ "${status}" -eq 0 ]
  # Two rows, alphabetical (glob order is lexicographic on most fs).
  [ "$(echo "${output}" | wc -l)" -eq 2 ]
  echo "${output}" | grep -q $'^org\torg-a\tr1\t'
  echo "${output}" | grep -q $'^org\torg-b\tr2\t'
}

# validate_labels: a labels CSV is valid iff it is one or more
# comma-separated tokens, each matching [A-Za-z0-9_-]+ (GitHub's allowed
# label charset). Rejects empty, whitespace, leading/trailing/double comma.

@test "validate_labels accepts a single token" {
  run bash -c "source '${LIB}'; validate_labels gpu"
  [ "${status}" -eq 0 ]
}

@test "validate_labels accepts a comma-separated list" {
  run bash -c "source '${LIB}'; validate_labels gpu,cuda12,fast"
  [ "${status}" -eq 0 ]
}

@test "validate_labels rejects an empty string" {
  run bash -c "source '${LIB}'; validate_labels ''"
  [ "${status}" -ne 0 ]
}

@test "validate_labels rejects a token with whitespace" {
  run bash -c "source '${LIB}'; validate_labels 'bad label'"
  [ "${status}" -ne 0 ]
}

@test "validate_labels rejects a double comma (empty token)" {
  run bash -c "source '${LIB}'; validate_labels a,,b"
  [ "${status}" -ne 0 ]
}

@test "validate_labels rejects a trailing comma" {
  run bash -c "source '${LIB}'; validate_labels gpu,"
  [ "${status}" -ne 0 ]
}

# load_config: source the optional setup.conf under RUNNER_HOME, then leave
# $LABELS holding the resolved set (default "gpu" when unset / no config).

@test "load_config defaults LABELS to gpu when no setup.conf exists" {
  TMP=$(mktemp -d)
  run env -i HOME="${HOME}" PATH="${PATH}" RUNNER_HOME="${TMP}" bash -c \
    "source '${LIB}'; load_config; echo \"\${LABELS}\""
  rm -rf "${TMP}"
  [ "${status}" -eq 0 ]
  [ "${output}" = "gpu" ]
}

@test "load_config reads LABELS from setup.conf when present" {
  TMP=$(mktemp -d)
  printf 'LABELS=gpu,cuda12\n' > "${TMP}/setup.conf"
  run env -i HOME="${HOME}" PATH="${PATH}" RUNNER_HOME="${TMP}" bash -c \
    "source '${LIB}'; load_config; echo \"\${LABELS}\""
  rm -rf "${TMP}"
  [ "${status}" -eq 0 ]
  [ "${output}" = "gpu,cuda12" ]
}

# runner_agent_id: extract the numeric agentId from <dir>/.runner. Must
# survive the UTF-8 BOM + pretty-printed JSON that actions/runner writes
# (same constraint that makes list_runners use a sed extractor, not jq).

@test "runner_agent_id extracts agentId from a BOM-prefixed .runner" {
  TMP=$(mktemp -d)
  printf '\xef\xbb\xbf{\n  "agentId": 142,\n  "agentName": "r"\n}\n' \
    > "${TMP}/.runner"
  run bash -c "source '${LIB}'; runner_agent_id '${TMP}'"
  rm -rf "${TMP}"
  [ "${status}" -eq 0 ]
  [ "${output}" = "142" ]
}
