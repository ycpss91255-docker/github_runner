#!/usr/bin/env bats
# Smoke tests for lib/common.sh resolve_target dispatcher.

setup() {
  LIB="${BATS_TEST_DIRNAME}/../../lib/common.sh"
  # Pin RUNNER_HOME so TARGET_DIR is predictable regardless of where the
  # repo is checked out (default is <repo_root>/runners/).
  export RUNNER_HOME="/tmp/gh-runner-test-home"
}

# SEC-3: RUNNER_HOME is the rm -rf root for every destructive consumer, so a
# dangerous override must be refused at the single chokepoint (source time).

@test "sourcing common.sh refuses RUNNER_HOME=/" {
  run bash -c "RUNNER_HOME=/ source '${LIB}'"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *refusing* ]]
}

@test "sourcing common.sh refuses a relative RUNNER_HOME" {
  run bash -c "RUNNER_HOME=runners source '${LIB}'"
  [ "${status}" -ne 0 ]
}

@test "sourcing common.sh refuses a RUNNER_HOME containing .." {
  run bash -c "RUNNER_HOME=/tmp/x/../y source '${LIB}'"
  [ "${status}" -ne 0 ]
}

@test "sourcing common.sh accepts a non-existent absolute RUNNER_HOME (first install)" {
  run bash -c "RUNNER_HOME=/tmp/does-not-exist-yet/runners source '${LIB}'"
  [ "${status}" -eq 0 ]
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

# SEC-4: org/owner/repo flow into TARGET_DIR (an rm -rf root) and gh API
# paths, so resolve_target must reject anything that isn't a clean GitHub
# identifier (no slashes, no path traversal).

@test "resolve_target rejects an org with path traversal" {
  run bash -c "source '${LIB}'; resolve_target org '../../etc'"
  [ "${status}" -ne 0 ]
}

@test "resolve_target rejects a repo name of .." {
  run bash -c "source '${LIB}'; resolve_target repo owner .."
  [ "${status}" -ne 0 ]
}

@test "resolve_target rejects an org containing a slash" {
  run bash -c "source '${LIB}'; resolve_target org 'a/b'"
  [ "${status}" -ne 0 ]
}

@test "resolve_target accepts a normal hyphenated org" {
  run bash -c "source '${LIB}'; resolve_target org my-org; echo \"\${TARGET_DIR}\""
  [ "${status}" -eq 0 ]
  [[ "${output}" == */my-org/_org ]]
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

# H3: assert_under_runner_home anchors a destructive rm target under
# RUNNER_HOME lexically. Both arms: a dir inside passes; a dir outside is
# refused with a message + nonzero.

@test "assert_under_runner_home passes for a dir inside RUNNER_HOME" {
  run bash -c "source '${LIB}'; assert_under_runner_home \"\${RUNNER_HOME}/myorg/_org\""
  [ "${status}" -eq 0 ]
}

@test "assert_under_runner_home refuses a dir outside RUNNER_HOME" {
  run bash -c "source '${LIB}'; assert_under_runner_home /etc"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"refusing rm outside RUNNER_HOME: /etc"* ]]
}

@test "resolve_runner_version honours RUNNER_VERSION env override verbatim" {
  # shellcheck disable=SC1090
  source "${LIB}"
  RUNNER_VERSION=9.9.9 run resolve_runner_version
  [ "${status}" -eq 0 ]
  [ "${output}" = "9.9.9" ]
}

@test "resolve_runner_version returns exactly RUNNER_VERSION_FALLBACK when gh is missing" {
  # D9: empty PATH dir guarantees gh is absent on every host (not just CI),
  # and we assert against the lib's own constant rather than a loose regex.
  NOGH="$(mktemp -d)"
  run env -i HOME="${HOME}" PATH="${NOGH}:/bin:/usr/bin" RUNNER_VERSION= bash -c \
    "command -v gh >/dev/null 2>&1 && { echo 'gh unexpectedly present'; exit 2; }; \
     source '${LIB}'; [ \"\$(resolve_runner_version)\" = \"\${RUNNER_VERSION_FALLBACK}\" ] && echo MATCH"
  rm -rf "${NOGH}"
  [ "${status}" -eq 0 ]
  [ "${output}" = "MATCH" ]
}

@test "resolve_runner_version uses the latest gh release tag and strips a leading v" {
  # gh present (a `gh` shadow makes 'command -v gh' succeed) + the _gh seam
  # returns a tag -> the dynamic branch: _gh api ... | sed 's/^v//'. _gh is
  # shadowed (not gh) because _gh forwards through `command gh`, which bypasses
  # a `gh` function shadow.
  run bash -c "
    source '${LIB}'
    gh() { :; }
    _gh() { printf 'v2.341.0\n'; }
    RUNNER_VERSION= resolve_runner_version
  "
  [ "${status}" -eq 0 ]
  [ "${output}" = "2.341.0" ]
}

@test "resolve_runner_version falls back when gh returns an empty tag" {
  # shellcheck disable=SC1090
  source "${LIB}"               # bring RUNNER_VERSION_FALLBACK into scope
  gh() { :; }                   # gh present (command -v gh succeeds)
  _gh() { printf ''; }          # but the api emits nothing (rate-limited/unauth)
  RUNNER_VERSION= run resolve_runner_version
  [ "${status}" -eq 0 ]
  [ "${output}" = "${RUNNER_VERSION_FALLBACK}" ]
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

@test "list_runners reads agentName from a BOM + pretty-printed .runner" {
  # C-3: prod's actions/runner writes a UTF-8 BOM + multi-line JSON; the sed
  # extractor must still find agentName (only compact JSON was covered before).
  TMP=$(mktemp -d)
  mkdir -p "${TMP}/myorg/_org"
  printf '\xef\xbb\xbf{\n  "agentId": 7,\n  "agentName": "myhost-myorg-org"\n}\n' \
    > "${TMP}/myorg/_org/.runner"
  RUNNER_HOME="${TMP}" run bash -c "source '${LIB}'; list_runners"
  rm -rf "${TMP}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *$'\t'myhost-myorg-org$'\t'* ]]
}

@test "list_runners emits '?' as the name when .runner has no agentName" {
  # corrupt/partial marker -> sed yields empty -> name falls back to '?'.
  TMP=$(mktemp -d)
  mkdir -p "${TMP}/myorg/_org"
  printf '{\n  "agentId": 7\n}\n' > "${TMP}/myorg/_org/.runner"
  RUNNER_HOME="${TMP}" run bash -c "source '${LIB}'; list_runners"
  rm -rf "${TMP}"
  [ "${status}" -eq 0 ]
  IFS=$'\t' read -r scope org name dir scope_id <<<"${output}"
  [ "${scope}" = "org" ]
  [ "${org}" = "myorg" ]
  [ "${name}" = "?" ]
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

# SEC-4 validators, exercised directly (resolve_target only covers them
# indirectly). valid_owner is GitHub's owner/org rule: alphanumerics with
# single internal hyphens. valid_repo additionally allows '.' and '_' but is
# never '.' or '..'.

@test "valid_owner rejects a doubled internal hyphen" {
  run bash -c "source '${LIB}'; valid_owner 'a--b'"
  [ "${status}" -ne 0 ]
}

@test "valid_owner rejects a leading hyphen" {
  run bash -c "source '${LIB}'; valid_owner '-a'"
  [ "${status}" -ne 0 ]
}

@test "valid_owner rejects a trailing hyphen" {
  run bash -c "source '${LIB}'; valid_owner 'a-'"
  [ "${status}" -ne 0 ]
}

@test "valid_owner accepts a normal hyphenated name" {
  run bash -c "source '${LIB}'; valid_owner 'a-b'"
  [ "${status}" -eq 0 ]
}

@test "valid_repo accepts a dotted name" {
  run bash -c "source '${LIB}'; valid_repo 'a.b'"
  [ "${status}" -eq 0 ]
}

@test "valid_repo accepts an underscored name" {
  run bash -c "source '${LIB}'; valid_repo 'a_b'"
  [ "${status}" -eq 0 ]
}

@test "valid_repo rejects '.'" {
  run bash -c "source '${LIB}'; valid_repo '.'"
  [ "${status}" -ne 0 ]
}

@test "valid_repo rejects '..'" {
  run bash -c "source '${LIB}'; valid_repo '..'"
  [ "${status}" -ne 0 ]
}

# load_config: extract LABELS from the optional setup.conf under RUNNER_HOME
# (without sourcing it -- SEC-6), then leave $LABELS holding the resolved set
# (default "gpu" when unset / no config).

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

@test "load_config does not execute code embedded in setup.conf" {
  # SEC-6: setup.conf is writable by the runner user; a CI job could drop a
  # payload. load_config must extract LABELS, not source the file.
  TMP=$(mktemp -d); MARK="${TMP}/pwned"
  printf 'LABELS=gpu\ntouch %s\n' "${MARK}" > "${TMP}/setup.conf"
  run env -i HOME="${HOME}" PATH="${PATH}" RUNNER_HOME="${TMP}" bash -c \
    "source '${LIB}'; load_config; echo \"\${LABELS}\""
  [ ! -e "${MARK}" ]
  [ "${output}" = "gpu" ]
  rm -rf "${TMP}"
}

@test "load_config rejects an invalid LABELS line" {
  TMP=$(mktemp -d)
  printf 'LABELS=bad label!\n' > "${TMP}/setup.conf"
  run env -i HOME="${HOME}" PATH="${PATH}" RUNNER_HOME="${TMP}" bash -c \
    "source '${LIB}'; load_config"
  rm -rf "${TMP}"
  [ "${status}" -ne 0 ]
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

@test "runner_agent_id prints nothing and exits 0 when .runner lacks an agentId" {
  TMP=$(mktemp -d)
  printf '{\n  "agentName": "r"\n}\n' > "${TMP}/.runner"
  run bash -c "source '${LIB}'; runner_agent_id '${TMP}'"
  rm -rf "${TMP}"
  [ "${status}" -eq 0 ]
  [ -z "${output}" ]
}

# require_gh_auth: hard pre-gate used by the mutating scripts. The _gh seam is
# shadowed so the auth probe's success/failure is what gets exercised, not real
# auth.

@test "require_gh_auth exits non-zero with guidance when gh auth fails" {
  run bash -c "source '${LIB}'; _gh() { return 1; }; require_gh_auth"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"not authenticated"* ]]
}

@test "require_gh_auth returns 0 when gh auth succeeds" {
  run bash -c "source '${LIB}'; _gh() { return 0; }; require_gh_auth && echo OK"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"OK"* ]]
}
